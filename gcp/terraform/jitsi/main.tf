# Jitsi sur GKE : les deux IP publiques, le certificat du site et l'Application ArgoCD.
# Le cluster et ArgoCD viennent du module gcp/terraform/cluster (state séparé).

locals {
  project      = "gestiondeconf"
  region       = "europe-west1"
  zone         = "europe-west1-b"
  cluster_name = "gestion-conf-gke"
  repo         = "https://github.com/TNav13/gestion_de_conf.git"
  public_url   = "https://${google_compute_global_address.web.address}"
}

provider "google" {
  project = local.project
  region  = local.region
}

data "google_client_config" "current" {}

data "google_container_cluster" "gke" {
  name     = local.cluster_name
  location = local.zone
}

provider "helm" {
  kubernetes = {
    host                   = "https://${data.google_container_cluster.gke.endpoint}"
    token                  = data.google_client_config.current.access_token
    cluster_ca_certificate = base64decode(data.google_container_cluster.gke.master_auth[0].cluster_ca_certificate)
  }
}

# Le site passe par une Ingress GKE, donc un load balancer HTTPS global : IP globale
resource "google_compute_global_address" "web" {
  name = "jitsi-web"
}

# La vidéo passe par un Service LoadBalancer UDP, régional et sans proxy :
# l'IP est fixée à l'avance pour que jvb l'annonce aux navigateurs
resource "google_compute_address" "jvb" {
  name   = "jitsi-jvb"
  region = local.region
}

# Certificat autosigné comme sur AWS : pas de nom de domaine, mais le navigateur
# exige HTTPS pour la caméra
resource "tls_private_key" "web" {
  algorithm = "RSA"
}

resource "tls_self_signed_cert" "web" {
  private_key_pem       = tls_private_key.web.private_key_pem
  validity_period_hours = 24 * 365
  allowed_uses          = ["key_encipherment", "digital_signature", "server_auth"]
  ip_addresses          = [google_compute_global_address.web.address]

  subject {
    common_name = google_compute_global_address.web.address
  }
}

# Certificat « pre-shared » : l'Ingress le désigne par son nom (annotation)
resource "google_compute_ssl_certificate" "web" {
  name_prefix = "jitsi-web-"
  private_key = tls_private_key.web.private_key_pem
  certificate = tls_self_signed_cert.web.cert_pem

  # L'Ingress pointe encore sur l'ancien certificat pendant un remplacement
  lifecycle {
    create_before_destroy = true
  }
}

resource "helm_release" "argocd_apps_jitsi" {
  name       = "argocd-apps-jitsi"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argocd-apps"
  version    = "2.0.8"
  namespace  = "argocd"

  values = [yamlencode({
    applications = {
      jitsi = {
        namespace = "argocd"
        project   = "default"
        sources = [
          {
            repoURL        = local.repo
            targetRevision = "main"
            path           = "helm/jitsi-meet"
            helm = {
              valueFiles = ["../../gcp/helm/values/jitsi-meet-gcp.yaml"]
              # Ce que seul Terraform connaît ; prime sur le fichier ci-dessus
              valuesObject = {
                publicURL = local.public_url
                web = {
                  ingress = {
                    annotations = {
                      "kubernetes.io/ingress.global-static-ip-name" = google_compute_global_address.web.name
                      "ingress.gcp.kubernetes.io/pre-shared-cert"   = google_compute_ssl_certificate.web.name
                    }
                  }
                }
                jvb = {
                  publicIPs = [google_compute_address.jvb.address]
                  service   = { loadBalancerIP = google_compute_address.jvb.address }
                }
                # Le chart ne redémarre pas les pods quand PUBLIC_URL change : cette
                # annotation change avec l'URL et force le redémarrage (comme sur AWS)
                global = { podAnnotations = { "jitsi/public-url" = local.public_url } }
              }
            }
          },
          # La BackendConfig de l'Ingress (timeout long pour BOSH et les websockets)
          {
            repoURL        = local.repo
            targetRevision = "main"
            path           = "gcp/k8s/jitsi"
          },
        ]
        destination = { namespace = "jitsi", server = "https://kubernetes.default.svc" }
        syncPolicy = {
          automated   = { prune = true, selfHeal = true }
          syncOptions = ["CreateNamespace=true"]
        }
      }
    }
  })]
}
