locals {
  apis = [
    "compute.googleapis.com",
    "container.googleapis.com",
    "cloudkms.googleapis.com",
    "secretmanager.googleapis.com",
    "iam.googleapis.com",
    "iamcredentials.googleapis.com",
    "cloudresourcemanager.googleapis.com",
  ]
}

# disable_on_destroy = false : un destroy ne coupe pas les API dont d'autres modules ont besoin
resource "google_project_service" "apis" {
  for_each           = toset(local.apis)
  service            = each.value
  disable_on_destroy = false
}

resource "google_compute_network" "jitsi" {
  name                    = "gestion-conf-vpc"
  auto_create_subnetworks = false
  depends_on              = [google_project_service.apis]
}

# VPC-native : les pods et les Services ont leurs propres plages d'adresses
resource "google_compute_subnetwork" "jitsi" {
  name          = "gestion-conf-subnet"
  network       = google_compute_network.jitsi.id
  region        = var.region
  ip_cidr_range = "10.10.0.0/20"

  secondary_ip_range {
    range_name    = "pods"
    ip_cidr_range = "10.20.0.0/16"
  }

  secondary_ip_range {
    range_name    = "services"
    ip_cidr_range = "10.30.0.0/20"
  }
}

resource "google_container_cluster" "jitsi" {
  name     = "gestion-conf-gke"
  location = var.zone

  network    = google_compute_network.jitsi.id
  subnetwork = google_compute_subnetwork.jitsi.id

  # Pas de pool par défaut (ni initial_node_count ni node_config) : les nœuds
  # viennent du node pool ci-dessous, configurable finement
  networking_mode = "VPC_NATIVE"
  ip_allocation_policy {
    cluster_secondary_range_name  = "pods"
    services_secondary_range_name = "services"
  }

  # Workload Identity : les pods reçoivent des droits GCP sans clé stockée (OpenBao → KMS)
  workload_identity_config {
    workload_pool = "${var.project}.svc.id.goog"
  }

  release_channel {
    channel = "REGULAR"
  }

  # Sinon terraform destroy est refusé
  deletion_protection = false
}

resource "google_container_node_pool" "jitsi" {
  name           = "jitsi"
  cluster        = google_container_cluster.jitsi.id
  location       = var.zone
  node_locations = var.node_zones
  # Par zone : 3 nœuds au total
  node_count = 1

  node_config {
    machine_type = "e2-standard-2"
    image_type   = "COS_CONTAINERD"
    disk_type    = "pd-balanced"
    disk_size_gb = 50
    oauth_scopes = ["https://www.googleapis.com/auth/cloud-platform"]

    workload_metadata_config {
      mode = "GKE_METADATA"
    }
  }

  management {
    auto_repair  = true
    auto_upgrade = true
  }
}

resource "helm_release" "argocd" {
  name             = "argocd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  version          = "10.18.0"
  namespace        = "argocd"
  create_namespace = true
  depends_on       = [google_container_node_pool.jitsi]
}

# App racine : déploie tout ce qui est dans gcp/argocd/apps sur GitHub.
# Les modules openbao et jitsi ajoutent leurs propres Applications (valeurs calculées par Terraform)
resource "helm_release" "argocd-apps" {
  name             = "argocd-apps"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argocd-apps"
  version          = "2.0.8"
  namespace        = "argocd"
  create_namespace = true
  depends_on       = [helm_release.argocd]
  values = [yamlencode({
    applications = {
      root = {
        namespace   = "argocd"
        project     = "default"
        source      = { repoURL = "https://github.com/TNav13/gestion_de_conf.git", targetRevision = "main", path = "gcp/argocd/apps" }
        destination = { namespace = "argocd", server = "https://kubernetes.default.svc" }
        syncPolicy  = { automated = { prune = true, selfHeal = true } }
      }
    }
  })]
}
