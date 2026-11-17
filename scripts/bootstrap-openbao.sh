#!/usr/bin/env bash
# Initialise et configure OpenBao sur le cluster : remplace les commandes
# manuelles (init, kv, auth kubernetes, policy, role, secrets jicofo/jvb).
# Relançable : chaque étape regarde d'abord ce qui existe déjà.
# Prérequis : kubectl connecté au cluster, AWS CLI, jq, openssl.
set -euo pipefail

NS=openbao
POD=openbao-0
# Sortie de `bao operator init` (root token + recovery key), chiffrée dans SSM
SSM_NAME=/gestion-conf/openbao/init

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
  aws ssm put-parameter --name "$SSM_NAME" --type SecureString --overwrite --value "$init" >/dev/null
  echo "initialisé : root token et recovery key rangés dans SSM ($SSM_NAME)"
else
  echo "déjà initialisé"
fi

BAO_TOKEN=$(aws ssm get-parameter --name "$SSM_NAME" --with-decryption \
  --query Parameter.Value --output text | jq -r .root_token)
# Dépôt public, donc logs de CI publics : le token ne doit jamais y apparaître
if [ -n "${GITHUB_ACTIONS:-}" ]; then echo "::add-mask::$BAO_TOKEN"; fi

echo "== Déverrouillage par KMS"
for _ in $(seq 60); do
  [ "$(bao_status)" = 0 ] && break
  sleep 5
done
if [ "$(bao_status)" != 0 ]; then
  echo "OpenBao toujours scellé : vérifier le rôle IRSA openbao-unseal et la clé KMS" >&2
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
