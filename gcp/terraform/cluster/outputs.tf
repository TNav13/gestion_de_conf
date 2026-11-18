output "cluster_name" {
  value = google_container_cluster.jitsi.name
}

output "cluster_zone" {
  value = google_container_cluster.jitsi.location
}

output "cluster_endpoint" {
  value = google_container_cluster.jitsi.endpoint
}

output "project" {
  value = var.project
}

output "region" {
  value = var.region
}
