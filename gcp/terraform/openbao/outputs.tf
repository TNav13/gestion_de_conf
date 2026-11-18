output "kms_key" {
  value = google_kms_crypto_key.openbao.id
}

output "openbao_service_account" {
  value = google_service_account.openbao.email
}
