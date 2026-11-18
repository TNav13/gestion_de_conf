output "public_url" {
  description = "L'adresse du site (certificat autosigné à accepter)"
  value       = local.public_url
}

output "jvb_ip" {
  description = "L'IP que jvb annonce pour la vidéo (UDP 10000)"
  value       = google_compute_address.jvb.address
}
