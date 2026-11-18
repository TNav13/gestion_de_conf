variable "project" {
  type    = string
  default = "gestiondeconf"
}

variable "region" {
  type    = string
  default = "europe-west1"
}

# Emplacement du cluster créé par le module cluster
variable "zone" {
  type    = string
  default = "europe-west1-b"
}

variable "cluster_name" {
  type    = string
  default = "gestion-conf-gke"
}
