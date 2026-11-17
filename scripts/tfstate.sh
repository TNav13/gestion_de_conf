#!/usr/bin/env bash
# State Terraform conservé entre les runs dans un artifact GitHub chiffré
# (repo public : sans chiffrement, n'importe quel compte GitHub pourrait le lire).
#   pull    : récupère le dernier artifact "tfstate" et le déchiffre dans terraform_infra/
#   encrypt : chiffre terraform_infra/terraform.tfstate dans $RUNNER_TEMP/tfstate/
#             (le workflow l'envoie ensuite avec actions/upload-artifact)
# Prérequis : GH_TOKEN (permission actions: read) et TF_STATE_PASSPHRASE.
# shortcut: pas de verrou ni d'historique, suffisant pour un projet détruit après la démo ;
# passer à un backend S3 pour un usage durable.
set -euo pipefail
: "${TF_STATE_PASSPHRASE:?secret TF_STATE_PASSPHRASE manquant}"
STATE=terraform_infra/terraform.tfstate
OUT="$RUNNER_TEMP/tfstate"

case "${1:-}" in
  pull)
    # Le plus récent des artifacts non expirés, tous runs confondus
    id=$(gh api "repos/$GITHUB_REPOSITORY/actions/artifacts?name=tfstate&per_page=100" \
      --jq '[.artifacts[] | select(.expired | not)] | max_by(.created_at) | .id // empty')
    if [ -z "$id" ]; then
      echo "aucun state sauvegardé : départ d'un state vide"
      exit 0
    fi
    gh api "repos/$GITHUB_REPOSITORY/actions/artifacts/$id/zip" > "$RUNNER_TEMP/tfstate.zip"
    unzip -p "$RUNNER_TEMP/tfstate.zip" terraform.tfstate.enc |
      openssl enc -d -aes-256-cbc -pbkdf2 -pass env:TF_STATE_PASSPHRASE > "$STATE"
    echo "state récupéré (artifact $id)"
    ;;
  encrypt)
    mkdir -p "$OUT"
    openssl enc -aes-256-cbc -pbkdf2 -salt -pass env:TF_STATE_PASSPHRASE \
      -in "$STATE" -out "$OUT/terraform.tfstate.enc"
    ;;
  *)
    echo "usage : $0 pull|encrypt" >&2
    exit 2
    ;;
esac
