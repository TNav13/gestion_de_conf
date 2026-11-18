variable "project" {
  type    = string
  default = "gestiondeconf"
}

variable "region" {
  type    = string
  default = "europe-west1"
}

# Plan de contrôle dans une seule zone : les frais de gestion d'un cluster zonal
# sont couverts par l'offre gratuite de GKE
variable "zone" {
  type    = string
  default = "europe-west1-b"
}

# Un nœud par zone, comme les 3 AZ côté AWS
variable "node_zones" {
  type    = list(string)
  default = ["europe-west1-b", "europe-west1-c", "europe-west1-d"]
}
