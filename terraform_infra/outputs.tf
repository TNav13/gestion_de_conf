# Copyright (c) HashiCorp, Inc.
# SPDX-License-Identifier: MPL-2.0

output "cluster_endpoint" {
  description = "Endpoint for EKS control plane"
  value       = module.eks.cluster_endpoint
}

output "cluster_security_group_id" {
  description = "Security group ids attached to the cluster control plane"
  value       = module.eks.cluster_security_group_id
}

output "region" {
  description = "AWS region"
  value       = var.region
}

output "cluster_name" {
  description = "Kubernetes Cluster Name"
  value       = module.eks.cluster_name
}

output "jitsi_url" {
  description = "Adresse publique de Jitsi (PUBLIC_URL)"
  value       = "https://${aws_lb.jitsi.dns_name}"
}

output "jitsi_public_ips" {
  description = "IP publiques du NLB annoncées par jvb (JVB_ADVERTISE_IPS / jvb.publicIPs)"
  value       = aws_eip.jitsi_lb[*].public_ip
}

output "jitsi_values" {
  description = "Contenu de values-infra.yaml, écrit par la CI"
  value = yamlencode({
    publicURL = "https://${aws_lb.jitsi.dns_name}"
    jvb       = { publicIPs = aws_eip.jitsi_lb[*].public_ip }
    # Le chart ne redémarre pas les pods quand PUBLIC_URL change (pas de checksum
    # sur sa ConfigMap commune) : cette annotation change avec l'URL et force le redémarrage
    global = { podAnnotations = { "jitsi/public-url" = "https://${aws_lb.jitsi.dns_name}" } }
  })
}
