provider "google" {
  project = var.project
  region  = var.region
}

# Le cluster vient du module cluster : on le relit pour joindre son API
data "google_container_cluster" "jitsi" {
  name     = var.cluster_name
  location = var.zone
}

data "google_client_config" "default" {}

provider "helm" {
  kubernetes = {
    host                   = "https://${data.google_container_cluster.jitsi.endpoint}"
    token                  = data.google_client_config.default.access_token
    cluster_ca_certificate = base64decode(data.google_container_cluster.jitsi.master_auth[0].cluster_ca_certificate)
  }
}

# Un key ring ne se supprime jamais : sans suffixe, son nom serait pris après un destroy
resource "random_id" "keyring" {
  byte_length = 3
}

resource "google_kms_key_ring" "openbao" {
  name     = "openbao-${random_id.keyring.hex}"
  location = var.region
}

resource "google_kms_crypto_key" "openbao" {
  name            = "openbao-unseal"
  key_ring        = google_kms_key_ring.openbao.id
  rotation_period = "7776000s" # 90 jours : le seal garde la version qui a chiffré
}

resource "google_service_account" "openbao" {
  account_id   = "openbao-unseal"
  display_name = "OpenBao : deverrouillage par KMS"
}

# Chiffrer/déchiffrer, plus cloudkms.cryptoKeys.get que le seal gcpckms lit à son démarrage.
# Accordé sur la clé seulement
resource "google_kms_crypto_key_iam_member" "openbao" {
  for_each      = toset(["roles/cloudkms.cryptoKeyEncrypterDecrypter", "roles/cloudkms.viewer"])
  crypto_key_id = google_kms_crypto_key.openbao.id
  role          = each.value
  member        = "serviceAccount:${google_service_account.openbao.email}"
}

# Workload Identity : le ServiceAccount Kubernetes openbao/openbao agit en tant que ce compte,
# sans clé JSON stockée nulle part (l'équivalent d'IRSA)
resource "google_service_account_iam_member" "openbao_workload_identity" {
  service_account_id = google_service_account.openbao.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project}.svc.id.goog[openbao/openbao]"
}

# Root token et recovery key, ajoutés par gcp/scripts/bootstrap-openbao.sh
resource "google_secret_manager_secret" "openbao_init" {
  secret_id = "openbao-init"
  replication {
    auto {}
  }
}

resource "helm_release" "argocd_apps_openbao" {
  name       = "argocd-apps-openbao"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argocd-apps"
  version    = "2.0.8"
  namespace  = "argocd"
  # OpenBao a besoin de la clé et du droit de s'en servir dès son premier démarrage
  depends_on = [google_kms_crypto_key_iam_member.openbao, google_service_account_iam_member.openbao_workload_identity]

  values = [yamlencode({
    applications = {
      openbao = {
        namespace = "argocd"
        project   = "default"
        source = {
          chart = "openbao"
          # 0.29.x = OpenBao 2.6, dernière version où le seal gcpckms est intégré
          repoURL        = "https://openbao.github.io/openbao-helm"
          targetRevision = "0.29.6"
          helm = {
            releaseName = "openbao"
            valuesObject = {
              injector = { enabled = false }
              server = {
                dataStorage    = { storageClass = "standard-rwo", size = "5Gi" }
                serviceAccount = { annotations = { "iam.gke.io/gcp-service-account" = google_service_account.openbao.email } }
                # Config par défaut du chart (ui, listener, storage), plus le bloc seal.
                # Pas de credentials : le SDK Google prend ceux de Workload Identity
                standalone = {
                  config = <<-EOT
                    ui = true

                    listener "tcp" {
                      tls_disable = 1
                      address = "[::]:8200"
                      cluster_address = "[::]:8201"
                    }

                    storage "file" {
                      path = "/openbao/data"
                    }

                    seal "gcpckms" {
                      project    = "${var.project}"
                      region     = "${var.region}"
                      key_ring   = "${google_kms_key_ring.openbao.name}"
                      crypto_key = "${google_kms_crypto_key.openbao.name}"
                    }
                  EOT
                }
              }
            }
          }
        }
        destination = { server = "https://kubernetes.default.svc", namespace = "openbao" }
        syncPolicy = {
          syncOptions = ["CreateNamespace=true"]
          automated   = { prune = true, selfHeal = true }
        }
      }
    }
  })]
}
