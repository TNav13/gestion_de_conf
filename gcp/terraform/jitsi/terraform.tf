terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 8.12"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.3.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.4"
    }
  }

  required_version = "~> 1.3"
}
