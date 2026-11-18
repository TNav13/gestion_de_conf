# Le code Terraform, bloc par bloc

Le code est dans `terraform_infra/`. La première partie de `main.tf` vient du tutoriel HashiCorp (réseau et cluster), la suite concerne Jitsi (le load balancer), OpenBao (la clé KMS) et ArgoCD. **Terraform ne tourne que dans la CI** ([déploiement](deploiement.md)).

| Bloc | Ce qu'il crée | Pourquoi |
|---|---|---|
| `data "aws_availability_zones"` | rien : la liste des 3 AZ `a`, `b`, `c` | liste fermée, pour qu'une AZ ajoutée par AWS ne change pas le réseau toute seule |
| `module "vpc"` | le réseau, 3 sous-réseaux publics, 3 privés, 1 NAT | les nœuds sont isolés d'internet et sortent par le NAT |
| `module "eks"` | le cluster et 1 groupe de 3 nœuds `c7i-flex.large` (3 à 5) | le groupe est un Auto Scaling Group (ASG) AWS, qui répartit les nœuds sur les 3 AZ |
| `module "eks"` → `access_entries` | l'accès admin au cluster pour le compte root | pour `kubectl` depuis un poste ; la CI, elle, est admin parce qu'elle crée le cluster |
| `module "irsa-ebs-csi"` | un rôle IAM pour le pilote de disques EBS | le pod reçoit des droits AWS sans clé stockée (IRSA) |
| `aws_kms_key`, `aws_kms_alias` | la clé du déverrouillage d'OpenBao, alias fixe `alias/openbao-unseal` | chaque cluster recrée la clé, mais l'alias garde le même nom, écrit dans la config d'OpenBao |
| `aws_iam_policy "openbao_kms"`, `module "irsa-openbao"` | le rôle `openbao-unseal` (nom fixe), donné au ServiceAccount `openbao/openbao` | OpenBao a le droit de chiffrer et déchiffrer avec la clé, et rien d'autre |
| `locals` (`jitsi_targets`, `jitsi_listeners`) | rien : deux tables de ports | parcourues par les `for_each` qui suivent |
| `tls_private_key`, `tls_self_signed_cert`, `aws_acm_certificate` | le certificat autosigné, importé dans ACM | HTTPS obligatoire pour la caméra ; un NLB ne prend que des certificats ACM |
| `aws_security_group` et ses règles | les pare-feu du NLB et des nœuds | internet → NLB → nœuds, rien d'autre |
| `aws_eip` | 3 IP publiques | jvb doit connaître son adresse publique |
| `aws_lb` | le NLB, dans les 3 sous-réseaux publics | transporte TCP et UDP |
| `aws_lb_target_group` | `jitsi-web` (TCP 30080) et `jitsi-jvb` (UDP 30300) | où envoyer le trafic, avec leur health check |
| `aws_lb_listener` | les écoutes 80, 443 (TLS) et 30300 (UDP) | ce que le NLB écoute publiquement |
| `aws_autoscaling_attachment` | 2 liaisons (2 target groups × 1 groupe de nœuds) | tout nouveau nœud est ajouté au NLB automatiquement |
| `provider "helm"`, `helm_release "argocd"` | ArgoCD (chart `argo-cd` 10.18.0) | installé dès que les nœuds sont prêts (`depends_on = [module.eks]`) |
| `helm_release "argocd-apps"` | l'app racine d'ArgoCD (chart `argocd-apps` 2.0.8) | point de départ de tout ce que déploie ArgoCD |
| `output "jitsi_values"` | rien : le contenu de `values-infra.yaml` | la CI l'écrit tel quel (`terraform output -raw jitsi_values`) |

Le NLB est créé par Terraform plutôt que par Kubernetes (Service `LoadBalancer`) pour deux raisons : il est dans le state, donc `terraform destroy` le supprime proprement, et ses IP sont connues avant le déploiement de Jitsi.

Les descriptions des security groups sont en ASCII : AWS refuse les accents dedans.

Les commentaires `# checkov:skip=…` marquent les alertes de Checkov qui ne s'appliquent pas ici, avec la raison : la protection contre la suppression du NLB bloquerait `destroy`, un health check ELB sur l'ASG remplacerait en boucle les nœuds qui ne portent pas jvb, et deux faux positifs (EIP attachées au NLB, redirection HTTPS qui n'existe que sur un ALB).
