terraform {
  required_version = ">= 1.5"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 8.12.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.3.0"
    }
  }
}

provider "google" {
  project = var.project
  region  = var.region
}

# Jeton du compte ADC : pas besoin de gcloud ni de plugin pour installer ArgoCD
data "google_client_config" "default" {}

provider "helm" {
  kubernetes = {
    host                   = "https://${google_container_cluster.jitsi.endpoint}"
    token                  = data.google_client_config.default.access_token
    cluster_ca_certificate = base64decode(google_container_cluster.jitsi.master_auth[0].cluster_ca_certificate)
  }
}
