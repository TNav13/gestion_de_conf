# Jitsi Meet sur AWS EKS

La visioconférence Jitsi Meet sur AWS, déployée sans commande manuelle :
- **GitHub Actions** lance Terraform, qui crée le réseau, le cluster Kubernetes (EKS), le load balancer et **ArgoCD** ;
- **ArgoCD** installe depuis ce dépôt Jitsi, **OpenBao** (les mots de passe internes, déverrouillé par AWS KMS), **External Secrets** et **Chaos Mesh** ;
- un **stress test** (Malleus) fait entrer chaque jour de vrais navigateurs dans une réunion, et **Chaos Mesh** y injecte des pannes pour voir comment Jitsi s'en remet.

## Architecture

```
                         Navigateur
          HTTPS 443 (site + signalisation)    UDP 30300 (vidéo)
                    │                               │
┌───────────────────▼──── NLB : 3 IP fixes, une par AZ ──────▼──────────┐
└───────────────────┬───────────────────────────────────────┬───────────┘
                    │ TCP 30080                             │ UDP 30300
┌───────────────────▼─── EKS : 3 nœuds, sous-réseaux privés ▼───────────┐
│   web ──/http-bind──► prosody ◄─── jicofo ───────────────► jvb        │
│  (le site)            (XMPP)     (organise)            (relais vidéo) │
└───────────────────────────────────────────────────────────────────────┘
```

- **web** sert le site et relaie la signalisation vers **prosody**, le standard où tout le monde se connecte.
- **jicofo** place chaque conférence sur **jvb**, qui reçoit un flux par participant et le redistribue aux autres.
- La vidéo va directement du navigateur à jvb, en UDP, à l'IP publique que jvb annonce. Ces IP et l'URL du NLB changent à chaque cluster : la CI les écrit dans `helm/jitsi-meet/values-infra.yaml`.

Détail du fonctionnement, des ports et des réglages : [docs/architecture.md](docs/architecture.md).

## Arborescence

```
.
├── .github/workflows/
│   ├── deploy.yml                checkov, terraform apply, values-infra, bootstrap OpenBao
│   ├── destroy.yml               terraform destroy + volumes EBS orphelins
│   ├── stress.yml                stress test Malleus
│   └── chaos.yml                 injecte une expérience Chaos Mesh au choix
├── scripts/
│   ├── tfstate.sh                state Terraform ↔ artifact GitHub chiffré
│   └── bootstrap-openbao.sh      init et configuration d'OpenBao
├── terraform_infra/              Terraform : réseau, EKS, NLB, KMS, ArgoCD
├── argocd/apps/                  les Applications ArgoCD (app of apps)
│   ├── jitsi-meet.yaml, eso.yaml, secrets.yaml, openbao.yaml, chaos-mesh.yaml
├── helm/
│   ├── values/jitsi-meet-aws.yaml   les réglages Jitsi du projet (à la main)
│   ├── jitsi-meet/               chart officiel jitsi-meet 3.10.0
│   │   └── values-infra.yaml     l'URL et les IP du NLB (écrit par la CI)
│   └── eso/                      ServiceAccount, SecretStore, ExternalSecrets
├── malleus/                      les deux images du stress test (grid, malleus)
├── chaos-mesh/                   les expériences de panne
└── docs/                         la documentation détaillée
```

## Mise en place, une seule fois

| Où | Quoi |
|---|---|
| AWS IAM → Identity providers | fournisseur OpenID Connect `token.actions.githubusercontent.com`, audience `sts.amazonaws.com` (**sans point final**) |
| AWS IAM → Roles | rôle `deploy_eks` (droits `AdministratorAccess`), qui fait confiance à ce fournisseur avec deux conditions : `aud` = `sts.amazonaws.com`, et `sub` = `repo:TNav13@187294659/gestion_de_conf@1425369785:*` |
| GitHub → Settings → Secrets and variables → Actions | **variable** `DEPLOY_EKS` = l'ARN du rôle ; **secret** `TF_STATE_PASSPHRASE` = une phrase de chiffrement (`openssl rand -base64 32`) |

Le dépôt doit rester public : ArgoCD le lit directement sur GitHub.

## Les workflows

| Workflow | Lancement | Ce qu'il fait |
|---|---|---|
| **deploy** | push sur `main` touchant `terraform_infra/`, `scripts/` ou `deploy.yml`, ou Run workflow | Checkov, `terraform apply`, écrit `values-infra.yaml`, configure OpenBao. ~17 min depuis zéro, ~2 min sinon |
| **destroy** | Run workflow, puis taper `destroy` | `terraform destroy`, puis supprime les disques EBS laissés par Kubernetes |
| **stress** | chaque jour à 12h (Paris), ou Run workflow | 5 navigateurs dans la salle `bench0` pendant 5 min ; rouge si Jitsi ne répond pas |
| **chaos** | Run workflow, en choisissant l'expérience | injecte une expérience de `chaos-mesh/` et affiche les stats du jvb ; à lancer ~3 min après un stress |

Les changements dans `helm/` et `argocd/` ne passent pas par la CI : ArgoCD les applique environ 2 minutes après le push.

Détails : [docs/deploiement.md](docs/deploiement.md) (CI, state, ArgoCD) et [docs/tests.md](docs/tests.md) (stress et Chaos Mesh).

## Se connecter

```bash
aws eks list-clusters --region eu-north-1          # le nom a un suffixe aléatoire
aws eks update-kubeconfig --region eu-north-1 --name <nom>

# ArgoCD : https://localhost:8080, utilisateur admin
# ("; echo" évite le % de zsh ; après 5 échecs, le compte est bloqué 5 minutes)
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo
kubectl -n argocd port-forward svc/argocd-server 8080:443

# OpenBao, avec le root token rangé dans SSM
aws ssm get-parameter --region eu-north-1 --name /gestion-conf/openbao/init --with-decryption \
  --query Parameter.Value --output text | jq -r .root_token
kubectl -n openbao exec -it openbao-0 -- bao login

# Dashboard de Chaos Mesh : http://localhost:2333 (sans jeton)
kubectl -n chaos-mesh port-forward svc/chaos-dashboard 2333:2333
```

Jitsi est à l'URL `publicURL` de `helm/jitsi-meet/values-infra.yaml` : accepter l'avertissement du certificat autosigné.

## À retenir

1. **Terraform ne tourne que dans la CI.** Le state est dans un artifact GitHub chiffré, pas sur un poste.
2. **Pour redéployer : Run workflow, jamais « Re-run jobs »**, qui rejoue l'ancien commit.
3. **Un fichier `kind: Application` va dans `argocd/apps/`** ; charts, values et manifestes dans `helm/`. Ce qui est ailleurs (`chaos-mesh/`, `malleus/`) n'est jamais appliqué par ArgoCD.
4. **Les réglages Jitsi sont dans `helm/values/jitsi-meet-aws.yaml`.** `values-infra.yaml` est écrit par la CI : ne pas le modifier à la main.
5. **Un stress vert ne prouve pas que la vidéo passe** : il faut regarder les stats du jvb ([docs/tests.md](docs/tests.md)).

## Limites

- **Pas de haute disponibilité** : un seul jvb, une seule passerelle NAT, et prosody est un point de défaillance unique.
- **Certificat autosigné**, faute de nom de domaine : avertissement dans le navigateur.
- **Pas d'authentification ni d'écran de pré-connexion** : toute personne qui a l'URL entre directement.
- **State dans un artifact GitHub** : 7 jours de rétention, ni historique ni verrou. Suffisant pour un projet détruit après la démo.
- **Chaos Mesh et ArgoCD** : le chart génère ses certificats à chaque rendu. À vérifier après chaque nouveau cluster ([docs/tests.md](docs/tests.md)).

## Documentation

| Fichier | Contenu |
|---|---|
| [docs/architecture.md](docs/architecture.md) | fonctionnement de Jitsi, infra AWS, Services Kubernetes, trajet du trafic, ports, réglages Helm, montée en charge |
| [docs/terraform.md](docs/terraform.md) | le code Terraform, bloc par bloc |
| [docs/secrets.md](docs/secrets.md) | OpenBao, External Secrets, auto-unseal KMS, script de bootstrap |
| [docs/deploiement.md](docs/deploiement.md) | workflows deploy et destroy, state Terraform, app of apps d'ArgoCD |
| [docs/tests.md](docs/tests.md) | stress test Malleus, Chaos Mesh, expériences et résultats |
| [docs/pieges.md](docs/pieges.md) | les erreurs rencontrées et leurs causes |
