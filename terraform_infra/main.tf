
provider "aws" {
  region = var.region
}

# Filter out local zones, which are not currently supported 
# with managed node groups
data "aws_availability_zones" "available" {
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
  # Liste fermée : une AZ ajoutée par AWS ne modifie pas le réseau toute seule
  filter {
    name   = "zone-name"
    values = ["${var.region}a", "${var.region}b", "${var.region}c"]
  }
}

locals {
  cluster_name = "gestion_conf-eks-${random_string.suffix.result}"
}

resource "random_string" "suffix" {
  length  = 8
  special = false
}

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "5.8.1"

  name = "gestion_conf-vpc"

  cidr = "10.0.0.0/16"
  azs  = slice(data.aws_availability_zones.available.names, 0, 3)

  private_subnets = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
  public_subnets  = ["10.0.4.0/24", "10.0.5.0/24", "10.0.6.0/24"]

  enable_nat_gateway   = true
  single_nat_gateway   = true
  enable_dns_hostnames = true

  public_subnet_tags = {
    "kubernetes.io/role/elb" = 1
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = 1
  }
}

data "aws_caller_identity" "current" {}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "20.8.5"

  cluster_name    = local.cluster_name
  cluster_version = "1.36"

  cluster_endpoint_public_access           = true
  enable_cluster_creator_admin_permissions = true

  cluster_addons = {
    aws-ebs-csi-driver = {
      service_account_role_arn = module.irsa-ebs-csi.iam_role_arn
    }
  }

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  eks_managed_node_group_defaults = {
    ami_type = "AL2023_x86_64_STANDARD"

  }

  eks_managed_node_groups = {
    worker = {
      name = "node-group"

      instance_types = ["c7i-flex.large"]

      min_size     = 3
      max_size     = 5
      desired_size = 3
    }

  }
  access_entries = {
    admin_cluster = {
      principal_arn = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"

      # Map imbriquée : policy_associations
      policy_associations = {
        admin_policy = {
          policy_arn = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
          access_scope = {
            type = "cluster" # Portée globale sur tout le cluster
          }
        }
      }
    }
  }

}



# https://aws.amazon.com/blogs/containers/amazon-ebs-csi-driver-is-now-generally-available-in-amazon-eks-add-ons/ 
data "aws_iam_policy" "ebs_csi_policy" {
  arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

module "irsa-ebs-csi" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-assumable-role-with-oidc"
  version = "5.39.0"

  create_role                   = true
  role_name                     = "AmazonEKSTFEBSCSIRole-${module.eks.cluster_name}"
  provider_url                  = module.eks.oidc_provider
  role_policy_arns              = [data.aws_iam_policy.ebs_csi_policy.arn]
  oidc_fully_qualified_subjects = ["system:serviceaccount:kube-system:ebs-csi-controller-sa"]
}

resource "aws_kms_key" "openbao" {
  description             = "Auto unseal openbao"
  deletion_window_in_days = 7
  enable_key_rotation     = true
}

resource "aws_kms_alias" "openbao" {
  name          = "alias/openbao-unseal"
  target_key_id = aws_kms_key.openbao.key_id
}

resource "aws_iam_policy" "openbao_kms" {
  name = "openbao-kms-unseal"
  policy = jsonencode({
    Version = "2012-10-17" # version du langage IAM, toujours cette date
    Statement = [{
      Effect   = "Allow"
      Action   = ["kms:Encrypt", "kms:Decrypt", "kms:DescribeKey"]
      Resource = aws_kms_key.openbao.arn # l'ARN de la clé, pas celui de l'alias
    }]
  })
}

module "irsa-openbao" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-assumable-role-with-oidc"
  version = "5.39.0"

  create_role                   = true
  role_name                     = "openbao-unseal"
  provider_url                  = module.eks.oidc_provider
  role_policy_arns              = [aws_iam_policy.openbao_kms.arn]
  oidc_fully_qualified_subjects = ["system:serviceaccount:openbao:openbao"]
}
# Load balancer unique de Jitsi, géré par Terraform et non par Kubernetes :
# il est connu du state et supprimé proprement au destroy.
# NLB (couche 4) car un ALB ne transporte pas l'UDP ; le routage HTTP (couche 7)
# vers prosody et jvb est déjà fait par le nginx du conteneur jitsi/web.
locals {
  # NodePorts des Services Jitsi : ce que le NLB vise sur les nœuds,
  # et comment il vérifie qu'un nœud peut vraiment servir cette cible
  jitsi_targets = {
    # Le web ne parle que HTTP : le TLS est terminé par le NLB
    web = {
      protocol  = "TCP"
      node_port = 30080
      health    = { protocol = "TCP", port = 30080, path = null, matcher = null }
    }
    # Même port que l'écoute UDP : c'est celui que jvb annonce aux navigateurs.
    # Le Service jvb est en externalTrafficPolicy Local : seul le nœud qui porte
    # le pod jvb répond sur ses NodePorts, dont 30808 (/about/health de jvb).
    # Le NLB n'envoie donc l'UDP qu'à ce nœud
    jvb = {
      protocol  = "UDP"
      node_port = 30300
      health    = { protocol = "HTTP", port = 30808, path = "/about/health", matcher = "200" }
    }
  }

  # Écoutes publiques du NLB et la cible vers laquelle chacune renvoie
  jitsi_listeners = {
    http  = { protocol = "TCP", port = 80, target = "web" }
    https = { protocol = "TLS", port = 443, target = "web" }
    jvb   = { protocol = "UDP", port = 30300, target = "jvb" }
  }
}

# Certificat autosigné pour l'écoute HTTPS : les navigateurs exigent HTTPS pour
# la caméra. Sans domaine, pas de certificat reconnu : il faut accepter
# l'avertissement une fois, et il reste le même tant qu'il n'est pas recréé
resource "tls_private_key" "jitsi" {
  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "tls_self_signed_cert" "jitsi" {
  private_key_pem       = tls_private_key.jitsi.private_key_pem
  validity_period_hours = 24 * 365

  allowed_uses = [
    "key_encipherment",
    "digital_signature",
    "server_auth",
  ]

  dns_names = [aws_lb.jitsi.dns_name]

  subject {
    common_name = aws_lb.jitsi.dns_name
  }
}

# Le NLB ne prend un certificat que depuis ACM, qui accepte les autosignés
resource "aws_acm_certificate" "jitsi" {
  private_key      = tls_private_key.jitsi.private_key_pem
  certificate_body = tls_self_signed_cert.jitsi.cert_pem

  # Un certificat utilisé par une écoute ne peut pas être supprimé :
  # le nouveau doit exister avant que l'ancien parte
  lifecycle {
    create_before_destroy = true
  }
}

# Descriptions en ASCII : AWS refuse les accents dans celles des security groups
resource "aws_security_group" "jitsi_lb" {
  name        = "jitsi-nlb"
  description = "NLB Jitsi : web 80/443 et jvb UDP 30300"
  vpc_id      = module.vpc.vpc_id
}

resource "aws_vpc_security_group_ingress_rule" "jitsi_lb" {
  for_each = local.jitsi_listeners

  security_group_id = aws_security_group.jitsi_lb.id
  description       = "Public vers NLB : ${each.key}"
  cidr_ipv4         = "0.0.0.0/0"
  # TLS est un protocole d'écoute, il circule en TCP
  ip_protocol = each.value.protocol == "UDP" ? "udp" : "tcp"
  from_port   = each.value.port
  to_port     = each.value.port
}

resource "aws_vpc_security_group_egress_rule" "jitsi_lb" {
  security_group_id = aws_security_group.jitsi_lb.id
  description       = "NLB vers les noeuds du VPC"
  cidr_ipv4         = module.vpc.vpc_cidr_block
  ip_protocol       = "-1"
}

# Les nœuds n'acceptent les NodePorts que depuis le NLB
resource "aws_vpc_security_group_ingress_rule" "nodes_from_jitsi_lb" {
  for_each = local.jitsi_targets

  security_group_id            = module.eks.node_security_group_id
  description                  = "NLB vers NodePort ${each.key}"
  referenced_security_group_id = aws_security_group.jitsi_lb.id
  ip_protocol                  = lower(each.value.protocol)
  from_port                    = each.value.node_port
  to_port                      = each.value.node_port
}

# Le health check de jvb vise un port qui n'est pas une cible de trafic :
# sans cette règle il n'atteint aucun nœud et jvb est vu hors service partout
resource "aws_vpc_security_group_ingress_rule" "nodes_jvb_health_from_jitsi_lb" {
  security_group_id            = module.eks.node_security_group_id
  description                  = "Health check jvb depuis le NLB"
  referenced_security_group_id = aws_security_group.jitsi_lb.id
  ip_protocol                  = "tcp"
  from_port                    = local.jitsi_targets.jvb.health.port
  to_port                      = local.jitsi_targets.jvb.health.port
}

# Une IP élastique par sous-réseau public : les IP du NLB sont ainsi connues de
# Terraform, qui peut les transmettre à jvb (JVB_ADVERTISE_IPS)
resource "aws_eip" "jitsi_lb" {
  # checkov:skip=CKV2_AWS_19:Faux positif, ces EIP sont attachées au NLB (subnet_mapping) et non à des instances EC2
  count  = length(module.vpc.public_subnets)
  domain = "vpc"
}

resource "aws_lb" "jitsi" {
  # checkov:skip=CKV_AWS_150:La protection contre la suppression bloquerait terraform destroy (destroy.yml)
  # checkov:skip=CKV2_AWS_20:NLB couche 4, la redirection HTTP vers HTTPS n'existe que sur un ALB
  name                             = "jitsi-nlb"
  load_balancer_type               = "network"
  security_groups                  = [aws_security_group.jitsi_lb.id]
  enable_cross_zone_load_balancing = true

  dynamic "subnet_mapping" {
    for_each = module.vpc.public_subnets

    content {
      subnet_id     = subnet_mapping.value
      allocation_id = aws_eip.jitsi_lb[subnet_mapping.key].id
    }
  }
}

resource "aws_lb_target_group" "jitsi" {
  for_each = local.jitsi_targets

  name     = "jitsi-${each.key}"
  port     = each.value.node_port
  protocol = each.value.protocol
  vpc_id   = module.vpc.vpc_id

  health_check {
    protocol = each.value.health.protocol
    port     = each.value.health.port
    path     = each.value.health.path
    # Codes HTTP considérés comme sains : obligatoire pour un health check HTTP
    matcher = each.value.health.matcher
  }
}

resource "aws_lb_listener" "jitsi" {
  for_each = local.jitsi_listeners

  load_balancer_arn = aws_lb.jitsi.arn
  port              = each.value.port
  protocol          = each.value.protocol

  # Certificat et politique TLS : uniquement pour l'écoute TLS
  certificate_arn = each.value.protocol == "TLS" ? aws_acm_certificate.jitsi.arn : null
  ssl_policy      = each.value.protocol == "TLS" ? "ELBSecurityPolicy-TLS13-1-2-2021-06" : null

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.jitsi[each.value.target].arn
  }
}

# Enregistre les nœuds de chaque node group dans chaque target group
resource "aws_autoscaling_attachment" "jitsi" {
  # checkov:skip=CKV2_AWS_15:Avec externalTrafficPolicy Local, seul le noeud de jvb est sain pour l'UDP : un health check ELB sur l'ASG remplacerait les autres noeuds en boucle
  for_each = {
    for pair in setproduct(keys(local.jitsi_targets), keys(module.eks.eks_managed_node_groups)) :
    "${pair[0]}-${pair[1]}" => { target = pair[0], node_group = pair[1] }
  }

  autoscaling_group_name = module.eks.eks_managed_node_groups[each.value.node_group].node_group_autoscaling_group_names[0]
  lb_target_group_arn    = aws_lb_target_group.jitsi[each.value.target].arn
}

provider "helm" {
  kubernetes = {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
    exec = {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name, "--region", var.region]
    }
  }
}

resource "helm_release" "argocd" {
  name             = "argocd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  version          = "10.18.0"
  namespace        = "argocd"
  create_namespace = true
  depends_on       = [module.eks]
}

resource "helm_release" "argocd-apps" {
  name             = "argocd-apps"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argocd-apps"
  version          = "2.0.8"
  namespace        = "argocd"
  create_namespace = true
  # OpenBao (déployé par ArgoCD) a besoin de son rôle IRSA et de la clé KMS dès son démarrage
  depends_on = [helm_release.argocd, module.irsa-openbao, aws_kms_alias.openbao]
  values = [yamlencode({
    applications = {
      root = {
        namespace   = "argocd",
        project     = "default"
        source      = { repoURL = "https://github.com/TNav13/gestion_de_conf.git", targetRevision = "main", path = "argocd/apps" },
        destination = { namespace = "argocd", server = "https://kubernetes.default.svc" },
        syncPolicy  = { automated = { prune = true, selfHeal = true } }
      }
    }
    })
  ]
}