#!/usr/bin/env bash
# Version GKE de scripts/bootstrap-openbao.sh : initialise et configure OpenBao
# (init, kv, auth kubernetes, policy, role, secrets jicofo/jvb).
# Le root token et la recovery key vont dans Secret Manager (secret openbao-init,
# créé par gcp/terraform/openbao) au lieu de SSM.
# Relançable : chaque étape regarde d'abord ce qui existe déjà.
# Prérequis : KUBECONFIG vers le cluster GKE, gcloud, jq, openssl.
# Si le compte du gcloud CLI n'a pas accès au projet, passer le jeton ADC :
#   gcloud auth application-default print-access-token > /tmp/adc && export CLOUDSDK_AUTH_ACCESS_TOKEN_FILE=/tmp/adc
set -euo pipefail

PROJECT=${PROJECT:-gestiondeconf}
NS=openbao
POD=openbao-0
SECRET=openbao-init

# Attend qu'un objet existe : ArgoCD est peut-être encore en train de le créer
wait_exists() {
  for _ in $(seq 90); do
    kubectl -n "$1" get "$2" >/dev/null 2>&1 && return 0
    sleep 10
  done
  echo "timeout : $2 (namespace $1) n'existe toujours pas" >&2
  return 1
}

# bao exécuté dans le pod (BAO_ADDR y est déjà défini par le chart)
bao() { kubectl -n "$NS" exec -i "$POD" -- env BAO_TOKEN="${BAO_TOKEN:-}" bao "$@"; }

# Code de `bao status` : 0 = déverrouillé, 2 = scellé, 1 = injoignable
bao_status() {
  local rc=0
  bao status >/dev/null 2>&1 || rc=$?
  echo "$rc"
}

echo "== Attente du pod $POD"
wait_exists "$NS" "pod/$POD"
# Running et non Ready : le pod ne devient Ready qu'une fois OpenBao déverrouillé
kubectl -n "$NS" wait "pod/$POD" --for=jsonpath='{.status.phase}'=Running --timeout=15m
until [ "$(bao_status)" != 1 ]; do sleep 5; done

echo "== Init"
status=$(bao status -format=json 2>/dev/null || true)
if [ "$(jq -r .initialized <<<"$status")" = false ]; then
  # Avec le seal KMS, init donne une recovery key (pas de clé de déverrouillage)
  init=$(bao operator init -recovery-shares=1 -recovery-threshold=1 -format=json)
  # Par stdin : la sortie de l'init ne passe ni en argument ni dans les logs
  if ! printf '%s' "$init" | gcloud secrets versions add "$SECRET" --project "$PROJECT" --data-file=- >/dev/null; then
    # Sans cette copie, le root token serait perdu : OpenBao ne le redonne jamais
    out="${TMPDIR:-/tmp}/openbao-init.json"
    (umask 077 && printf '%s' "$init" >"$out")
    echo "échec de Secret Manager : sortie de l'init sauvée dans $out, à ranger dans $SECRET puis supprimer" >&2
    exit 1
  fi
  echo "initialisé : root token et recovery key rangés dans Secret Manager ($SECRET)"
else
  echo "déjà initialisé"
fi

BAO_TOKEN=$(gcloud secrets versions access latest --secret "$SECRET" --project "$PROJECT" | jq -r .root_token)

echo "== Déverrouillage par KMS"
for _ in $(seq 60); do
  [ "$(bao_status)" = 0 ] && break
  sleep 5
done
if [ "$(bao_status)" != 0 ]; then
  echo "OpenBao toujours scellé : vérifier le compte openbao-unseal (Workload Identity) et la clé KMS" >&2
  exit 1
fi

echo "== Moteur kv et auth kubernetes"
bao secrets list -format=json | jq -e '."kv/"' >/dev/null || bao secrets enable -path=kv kv-v2
bao auth list -format=json | jq -e '."kubernetes/"' >/dev/null || bao auth enable kubernetes
# Token et CA pour vérifier les ServiceAccounts : lus dans le pod d'OpenBao
bao write auth/kubernetes/config kubernetes_host=https://kubernetes.default.svc

echo "== Policy jicofo_jvb et role jitsi"
bao policy write jicofo_jvb - <<'EOF'
path "kv/data/jicofo" { capabilities = ["read"] }
path "kv/data/jvb"    { capabilities = ["read"] }
EOF
bao write auth/kubernetes/role/jitsi \
  bound_service_account_names=eso-jitsi \
  bound_service_account_namespaces=jitsi \
  token_policies=jicofo_jvb ttl=1h

echo "== Mots de passe jicofo / jvb"
# Créés une seule fois : prosody, jicofo et jvb ne les lisent qu'au démarrage
bao kv get kv/jicofo >/dev/null 2>&1 ||
  bao kv put kv/jicofo JICOFO_AUTH_PASSWORD="$(openssl rand -hex 24)" >/dev/null
bao kv get kv/jvb >/dev/null 2>&1 ||
  bao kv put kv/jvb JVB_AUTH_USER=jvb JVB_AUTH_PASSWORD="$(openssl rand -hex 24)" >/dev/null

echo "== Relance d'ESO pour qu'il lise les secrets tout de suite"
# Après ses échecs du début, ESO peut attendre ~16 min avant de réessayer
wait_exists external-secrets deploy/eso-external-secrets
kubectl -n external-secrets rollout restart deploy/eso-external-secrets
kubectl -n external-secrets rollout status deploy/eso-external-secrets --timeout=5m
wait_exists jitsi externalsecret/jicofo
wait_exists jitsi externalsecret/jvb
kubectl -n jitsi wait externalsecret/jicofo externalsecret/jvb --for=condition=Ready --timeout=5m

echo "OK : secrets jitsi-jicofo-bao et jitsi-jvb-bao créés"
