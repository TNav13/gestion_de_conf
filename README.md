# Jitsi Meet sur AWS EKS

Déploiement de la visioconférence Jitsi Meet sur AWS :
- **Terraform** crée le réseau, le cluster Kubernetes (EKS) et le load balancer ;
- **Helm** (via ArgoCD) installe Jitsi dans le cluster ;
- **OpenBao** garde les mots de passe internes de Jitsi, que **External Secrets** recopie dans Kubernetes.

```
.
├── learn-terraform-provision-eks-cluster/   Terraform : réseau, cluster EKS, NLB
├── helm/
│   ├── jitsi-meet/                           chart Helm jitsi-meet 3.10.0
│   │   ├── values-aws.yaml                   les réglages du projet
│   │   └── apps/monapp.yaml                  Application ArgoCD de Jitsi
│   ├── openbao/app.yaml                      Application ArgoCD d'OpenBao
│   └── eso/
│       ├── app.yml                           Application ArgoCD d'External Secrets
│       ├── secret-store.yaml                 la connexion à OpenBao
│       └── external-secrets.yaml             secrets OpenBao → Secrets Kubernetes
└── jitsi-kustomize/                          variante Kustomize (ne pas déployer avec Helm)
```

Le dossier `helm/jitsi-meet/` contient le chart complet, identique au chart officiel 3.10.0 (`values.yaml` compris). Tous les réglages du projet sont dans `values-aws.yaml`. ArgoCD lit le chart et `values-aws.yaml` dans ce dépôt, sur GitHub (branche `main`).

---

## 1. Comment fonctionne Jitsi Meet

Jitsi Meet, ce sont 4 programmes :

```
               ┌─────────────── prosody ───────────────┐
               │  messagerie interne (protocole XMPP)  │
               │  tout le monde s'y connecte           │
               └────▲──────────────▲──────────────▲────┘
                    │              │              │
                   web          jicofo           jvb
               (le site)    (l'organisateur) (le relais vidéo)
                    ▲                             ▲
                    │ HTTPS (TCP)                 │ vidéo (UDP)
                    │                             │
                    └──────── Navigateur ─────────┘
```

| Programme | Rôle |
|---|---|
| **web** | Un nginx qui envoie l'appli JavaScript au navigateur et relaie ses messages vers prosody. |
| **prosody** | Le standard : il sait qui est dans quelle salle et fait passer les messages de contrôle (« je rejoins », « je coupe mon micro »…). |
| **jicofo** | L'organisateur : quand une salle s'ouvre, il choisit un jvb et met les participants en relation avec lui. |
| **jvb** | Le relais vidéo : chaque participant lui envoie **un seul** flux, que jvb redistribue aux autres. |

```
 Sans jvb (4 personnes)         Avec jvb
   A ─── B                       A   B
   │ ╲ ╱ │                        ╲ ╱
   │ ╱ ╲ │                        jvb
   C ─── D                        ╱ ╲
 chacun envoie 3 flux            C   D
                             chacun envoie 1 flux
```

Le pair-à-pair est désactivé (`ENABLE_P2P=false`) : même à deux participants, tout passe par jvb.

### Ce qui se passe quand on rejoint une réunion

```
Navigateur        web          prosody        jicofo          jvb
    │              │              │              │              │
    │─ 1. GET ────►│              │              │              │
    │◄── appli ────│              │              │              │
    │              │              │              │              │
    │─ 2. "je rejoins la salle" ─►│              │              │
    │              │              │─ 3. ────────►│              │
    │              │              │              │─ 4. ────────►│
    │              │              │              │◄─────────────│
    │◄─ 5. "envoie ta vidéo à 13.63.25.28:30300" ┘              │
    │              │              │              │              │
    │═ 6. vidéo UDP ═══════════════════════════════════════════►│
```

1. Le navigateur télécharge l'appli depuis web.
2. L'appli envoie « je rejoins la salle ». Le message passe par web (URL `/http-bind`), qui le relaie à prosody.
3. prosody prévient jicofo qu'un participant arrive.
4. jicofo réserve une place pour ce participant sur jvb.
5. jicofo répond au navigateur : « envoie ta vidéo à telle IP, tel port ».
6. Le navigateur envoie sa vidéo **directement** à jvb, en UDP.

**Il y a donc deux chemins, et toute l'infrastructure en découle :**
- **le chemin contrôle** (étapes 1 à 5) passe par une seule porte, web, en HTTPS ;
- **le chemin vidéo** (étape 6) va directement à jvb, en UDP, à l'adresse que jvb annonce.

jvb doit annoncer une adresse joignable **depuis internet**. S'il annonçait son IP privée (10.0.x.x), la vidéo n'arriverait jamais. C'est le rôle de `jvb.publicIPs`.

---

## 2. L'infrastructure AWS

```
                               INTERNET
                                   │
                 TCP 80/443 (site) │ UDP 30300 (vidéo)
                                   ▼
┌─ VPC 10.0.0.0/16 (ton réseau privé chez AWS) ──────────────────┐
│                                                                │
│  SOUS-RÉSEAUX PUBLICS (joignables depuis internet)             │
│  ┌────────────────────────── NLB ───────────────────────────┐  │
│  │    IP fixe A          IP fixe B          IP fixe C       │  │
│  └─────────────────────────────┬────────────────────────────┘  │
│   NAT : la sortie internet     │                               │
│   des nœuds (images Docker)    │ vers les NodePorts des nœuds  │
│                                ▼                               │
│  SOUS-RÉSEAUX PRIVÉS (pas joignables depuis internet)          │
│  ┌─ nœud 1 ─────┐     ┌─ nœud 2 ─────┐     ┌─ nœud 3 ─────┐    │
│  │ pod web      │     │ pod prosody  │     │ pod jvb      │    │
│  │              │     │ pod jicofo   │     │              │    │
│  └──────────────┘     └──────────────┘     └──────────────┘    │
│       AZ a                 AZ b                 AZ c           │
└────────────────────────────────────────────────────────────────┘
```

La répartition des pods sur les nœuds est un exemple : c'est Kubernetes qui choisit.

- **Région** : `eu-north-1` (Stockholm). Une **AZ** est un datacenter distinct de la région ; on en utilise 3.
- **NLB** (Network Load Balancer) : la **seule porte d'entrée** depuis internet. Il reçoit sur ses ports publics et fait suivre vers les nœuds. C'est un NLB et pas un ALB, parce qu'un ALB ne transporte pas l'UDP de la vidéo.
- **3 IP fixes** (Elastic IP) : un NLB n'envoie du trafic qu'aux nœuds des AZ où il est présent. Les nœuds sont répartis sur 3 AZ et jvb peut tomber dans n'importe laquelle, donc le NLB est présent dans les 3 AZ, avec une adresse par AZ. Ces adresses sont fixées pour que Terraform les connaisse et qu'on puisse les donner à jvb. Elles changent après un `terraform destroy` suivi d'un `apply`.
- **NAT** : la porte de **sortie**. Les nœuds n'ont pas d'IP publique, mais doivent télécharger les images Docker.
- **Security groups** (pare-feu) : internet ne joint que le NLB, et les nœuds n'acceptent que le NLB.
- **Certificat autosigné** : le navigateur refuse la caméra sans HTTPS, et le projet n'a pas de nom de domaine. Le NLB déchiffre le HTTPS avec un certificat autosigné : il faut accepter l'avertissement du navigateur une fois.

---

## 3. Kubernetes : nœud, pod, Service

- **Nœud** : une machine EC2 (`t3.small`). Il y en a 3.
- **Pod** : un programme qui tourne sur un nœud (web, prosody, jicofo, jvb).
- **Service** : une adresse stable devant un pod. Un pod change d'IP à chaque redémarrage, le Service non.
  - **ClusterIP** : joignable seulement à l'intérieur du cluster. C'est le cas de prosody : seuls web, jicofo et jvb lui parlent.
  - **NodePort** : ouvre en plus **le même port sur tous les nœuds** (entre 30000 et 32767). Arriver sur n'importe quel nœud par ce port mène au pod.

```
         Service web : NodePort 30080 (mode normal)
   nœud 1 :30080 ──┐
   nœud 2 :30080 ──┼──► pod web :8000     (qui tourne sur le nœud 1)
   nœud 3 :30080 ──┘    Kubernetes redirige le trafic tout seul
```

```
         Service jvb : NodePort 30300, externalTrafficPolicy: Local
   nœud 1 :30300 ──✗    pas de pod jvb ici → ne répond pas
   nœud 2 :30300 ──✗    pas de pod jvb ici → ne répond pas
   nœud 3 :30300 ─────► pod jvb :30300
```

Avec `externalTrafficPolicy: Local`, seul le nœud qui **héberge** jvb répond. Ça sert à deux choses :
- jvb voit la vraie adresse du navigateur, et pas celle d'un nœud intermédiaire ;
- le NLB peut repérer le bon nœud grâce au health check (voir plus bas).

---

## 4. Le trajet du trafic

### Le site (chemin contrôle)

```
Navigateur
   │  HTTPS :443 (chiffré)
   ▼
NLB ── déchiffre le HTTPS avec le certificat autosigné
   │  HTTP :30080 (en clair, mais à l'intérieur du VPC)
   ▼
n'importe quel nœud :30080 ── NodePort du Service web
   │  Kubernetes redirige vers le pod
   ▼
pod web :8000 (nginx)
   ├── fichiers de l'appli → renvoyés au navigateur
   └── /http-bind (messages) → Service prosody :5280 (ClusterIP, interne)
                                   ▼
                               pod prosody ◄──► jicofo, jvb
```

### La vidéo

```
Navigateur
   │  UDP :30300 vers 13.63.25.28 (l'adresse annoncée par jvb)
   ▼
NLB ── ne déchiffre rien, fait juste suivre
   │  UDP :30300, uniquement vers le nœud déclaré « sain »
   ▼
nœud 3 :30300 ── NodePort du Service jvb (mode Local)
   ▼
pod jvb :30300
```

**Comment le NLB trouve le bon nœud :** il interroge régulièrement chaque nœud sur `http://nœud:30808/about/health`. Seul le nœud qui porte jvb répond 200 (mode `Local`), et c'est le seul à qui le NLB envoie l'UDP. On ne teste pas directement le port UDP, parce qu'en UDP rien ne répond « je vais bien ». Si jvb redémarre sur un autre nœud, le NLB le suit tout seul.

**Pourquoi 30300 partout :** jvb annonce « envoie-moi sur IP:30300 » et ne connaît que son propre port d'écoute. Il faut donc le même numéro pour l'écoute publique du NLB, pour le NodePort et pour le pod. Un NodePort doit être entre 30000 et 32767 : c'est pour ça que le port par défaut de jvb (10000) a été remplacé par 30300.

---

## 5. Le contrat entre Terraform et Helm

```
 TERRAFORM (crée AWS)                  HELM (crée Kubernetes)
 ─────────────────────                 ──────────────────────
 VPC, sous-réseaux, NAT                pods web, prosody, jicofo, jvb
 cluster EKS + 3 nœuds                 Service web  NodePort 30080
 NLB + 3 IP fixes + certificat         Service jvb  NodePort 30300 (UDP)
 pare-feu                                           NodePort 30808 (santé)
        │                                            │
        └──── ils doivent être d'accord sur : ───────┘
              • les ports 30080, 30300, 30808
              • l'URL du NLB   → publicURL dans values-aws.yaml
              • les 3 IP fixes → jvb.publicIPs dans values-aws.yaml
```

Si un de ces numéros change d'un côté sans changer de l'autre, Jitsi ne marche plus.

| Port | Où | Sert à |
|---|---|---|
| 80 / 443 | NLB (public) | le site (443 = chiffré) |
| 30300 UDP | NLB, nœuds, pod jvb | la vidéo |
| 30080 | nœuds → pod web :8000 | le site, une fois déchiffré |
| 30808 | nœuds → pod jvb :8080 | le health check de jvb |
| 5280 | prosody (interne) | les messages de contrôle |

Réglages de `helm/jitsi-meet/values-aws.yaml`, qui remplacent ceux du chart officiel :

| Réglage | Valeur | Pourquoi |
|---|---|---|
| `publicURL` | URL du NLB | adresse du site donnée aux navigateurs |
| `web.service` | `NodePort` 30080 | cible du NLB pour le site |
| `web.extraEnvs` | `ENABLE_P2P: "false"` | toute la vidéo passe par jvb |
| `jvb.publicIPs` | les 3 IP du NLB | adresses annoncées pour la vidéo |
| `jvb.disableStun` | `true` | inutile, les IP publiques sont déjà connues |
| `jvb.UDPPort` / `jvb.nodePort` | 30300 | même port partout |
| `jvb.service` | `NodePort`, `Local` | voir la partie 3 |
| `jvb.service.extraPorts` | 8080 → NodePort 30808 | health check du NLB |
| `jicofo.xmpp.existingSecretName` | `jitsi-jicofo-bao` | mot de passe de jicofo venant d'OpenBao (partie 7) |
| `jvb.xmpp.existingSecretName` | `jitsi-jvb-bao` | identifiant et mot de passe de jvb venant d'OpenBao (partie 7) |
| `enableAuth` / `enableGuests` | `true` / `true` | un compte pour créer une salle, invités acceptés ensuite (partie 7) |
| `prosody.persistence` | `true`, classe `gp2` | les comptes utilisateurs survivent aux redémarrages de prosody |

---

## 6. Le code Terraform, bloc par bloc

La première moitié de `main.tf` vient du tutoriel HashiCorp (réseau et cluster). La seconde moitié concerne Jitsi (le load balancer).

| Bloc | Ce qu'il crée | Pourquoi |
|---|---|---|
| `module "vpc"` | le réseau, 3 sous-réseaux publics, 3 privés, 1 NAT | les nœuds sont isolés d'internet et sortent par le NAT |
| `module "eks"` | le cluster et 1 groupe de 3 nœuds `t3.small` (3 à 5) | le groupe est un Auto Scaling Group (ASG) AWS, qui répartit les nœuds sur les 3 AZ |
| `module "irsa-ebs-csi"` | un rôle IAM pour le pilote de disques EBS | le pod reçoit des droits AWS sans clé stockée (IRSA) |
| `locals` (`jitsi_targets`, `jitsi_listeners`) | rien : deux tables de ports | parcourues par les `for_each` qui suivent |
| `tls_private_key`, `tls_self_signed_cert`, `aws_acm_certificate` | le certificat autosigné, importé dans ACM | HTTPS obligatoire pour la caméra ; un NLB ne prend que des certificats ACM |
| `aws_security_group` et ses règles | les pare-feu du NLB et des nœuds | internet → NLB → nœuds, rien d'autre |
| `aws_eip` | 3 IP publiques | jvb doit connaître son adresse publique |
| `aws_lb` | le NLB, dans les 3 sous-réseaux publics | transporte TCP et UDP |
| `aws_lb_target_group` | `jitsi-web` (TCP 30080) et `jitsi-jvb` (UDP 30300) | où envoyer le trafic, avec leur health check |
| `aws_lb_listener` | les écoutes 80, 443 (TLS) et 30300 (UDP) | ce que le NLB écoute publiquement |
| `aws_autoscaling_attachment` | 2 liaisons (2 target groups × 1 groupe de nœuds) | tout nouveau nœud est ajouté au NLB automatiquement |

Le NLB est créé par Terraform plutôt que par Kubernetes (Service `LoadBalancer`) pour deux raisons : il est dans le state, donc `terraform destroy` le supprime proprement, et ses IP sont connues avant le déploiement de Jitsi.

---

## 7. Les secrets et les comptes

### Les mots de passe internes : OpenBao + External Secrets

jicofo et jvb se connectent à prosody avec un identifiant et un mot de passe. Ce sont des **comptes internes**, pas ceux des utilisateurs. Par défaut, le chart les génère au hasard et les range dans des Secrets Kubernetes. Ici, ils sont gardés dans **OpenBao** (un coffre à secrets, version libre de Vault), qui devient la source de vérité.

```
 OpenBao (namespace openbao)      External Secrets (ESO)        namespace jitsi
 ───────────────────────────      ──────────────────────        ───────────────
 kv/jicofo                                                      Secret jitsi-jicofo-bao
   JICOFO_AUTH_PASSWORD   ──────► lit OpenBao        ──────►      → jicofo, prosody
 kv/jvb                           toutes les heures             Secret jitsi-jvb-bao
   JVB_AUTH_USER          ──────► et écrit les       ──────►      → jvb, prosody
   JVB_AUTH_PASSWORD              Secrets Kubernetes
```

**Pourquoi un intermédiaire (ESO) :** les images Jitsi lisent leurs mots de passe dans des **variables d'environnement**, au démarrage, et ne savent pas interroger OpenBao. ESO lit OpenBao et écrit un Secret Kubernetes ordinaire ; le chart l'utilise grâce à `existingSecretName`, sans aucun template modifié. L'injecteur d'OpenBao (un conteneur ajouté au pod) écrit des **fichiers**, que Jitsi ne lit pas : il est désactivé.

**Comment ESO prouve son identité à OpenBao (auth `kubernetes`) :**

```
ESO ── token du ServiceAccount eso-jitsi ──► OpenBao ── « ce token est-il valide ? » ──► API Kubernetes
                                                │
              role jitsi : ServiceAccount eso-jitsi du namespace jitsi
                           → policy jicofo_jvb : lecture de kv/data/jicofo et kv/data/jvb
```

| Où | Objet | Rôle |
|---|---|---|
| OpenBao | moteur `kv` (KV version 2) | stocke les secrets `kv/jicofo` et `kv/jvb` |
| OpenBao | auth `kubernetes` | accepte les tokens de ServiceAccount, après vérification par l'API Kubernetes |
| OpenBao | policy `jicofo_jvb` | lecture seule des deux secrets |
| OpenBao | role `jitsi` | donne la policy au ServiceAccount `eso-jitsi` du namespace `jitsi` |
| namespace `jitsi` | ServiceAccount `eso-jitsi` | l'identité que présente ESO |
| namespace `jitsi` | SecretStore `secret-store` | l'adresse d'OpenBao et la méthode d'auth |
| namespace `jitsi` | ExternalSecrets `jicofo`, `jvb` | quoi copier, et vers quel Secret |

Les noms des clés dans OpenBao deviennent tels quels les noms des variables d'environnement (`dataFrom.extract`) : ils doivent être exacts (`JVB_AUTH_USER`, pas `JVB_AUTH_USER_`).

**Pièges rencontrés :**
- En KV version 2, les données sont rangées sous `kv/data/...` : la policy vise `kv/data/jicofo`. La règle `kv/data/jicofo/*` ne couvre que ce qui est *sous* `jicofo/`, pas `jicofo` lui-même.
- `kubernetes_host` doit valoir `https://kubernetes.default.svc`, **sans point final**. Avec un point, le nom n'est pas complété en `.cluster.local`, OpenBao ne joint pas l'API Kubernetes et répond seulement `permission denied`.
- Le role doit donner la policy (`token_policies`) : sans elle, ESO se connecte mais n'a le droit de rien lire.
- Après une erreur, ESO réessaie de moins en moins souvent. Pour le relancer tout de suite :
  `kubectl -n jitsi annotate externalsecret jicofo jvb force-sync=$(date +%s) --overwrite`

### Les comptes des utilisateurs : l'auth interne de prosody

Avec `enableAuth: true` et `enableGuests: true` :
- **créer** une salle demande un compte (domaine `meet.jitsi`, mots de passe stockés hachés par prosody) ;
- un **invité** peut rejoindre sans compte une salle déjà ouverte (domaine `guest.meet.jitsi`, anonyme).

prosody range les comptes dans `/var/lib/prosody`. Ce dossier est sur un disque EBS de 3 Go (`prosody.persistence`), sinon les comptes disparaîtraient à chaque redémarrage du pod.

Les comptes ne sont pas dans OpenBao : prosody ne crée pas de comptes utilisateurs à partir de variables d'environnement. Ils sont créés à la main avec `prosodyctl` (partie 8, étape 9).

---

## 8. Déployer

```bash
# 1. L'infrastructure
cd learn-terraform-provision-eks-cluster
terraform init
terraform apply

# 2. L'accès au cluster depuis kubectl
aws eks update-kubeconfig --region "$(terraform output -raw region)" \
  --name "$(terraform output -raw cluster_name)"

# 3. L'URL et les IP du NLB, à reporter dans helm/jitsi-meet/values-aws.yaml
terraform output jitsi_url          # → publicURL
terraform output jitsi_public_ips   # → jvb.publicIPs
# puis commit et push : ArgoCD lit values-aws.yaml sur GitHub

# 4. ArgoCD (s'il n'est pas déjà installé)
kubectl create namespace argocd
kubectl apply -n argocd --server-side \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
cd ..                               # la suite se lance depuis la racine du dépôt

# 5. OpenBao : installation, initialisation, déverrouillage
kubectl apply -f helm/openbao/app.yaml
kubectl -n openbao exec -it openbao-0 -- bao operator init -key-shares=2 -key-threshold=2
#   → affiche 2 clés de déverrouillage et le root token : à garder hors du dépôt
kubectl -n openbao exec -it openbao-0 -- bao operator unseal   # 1re clé
kubectl -n openbao exec -it openbao-0 -- bao operator unseal   # 2e clé

# 6. OpenBao : secrets, policy, auth kubernetes, role (dans le pod)
kubectl -n openbao exec -it openbao-0 -- sh
bao login                                      # root token
bao secrets enable -path=kv kv-v2
bao kv put kv/jicofo JICOFO_AUTH_PASSWORD='<mot de passe>'
bao kv put kv/jvb JVB_AUTH_USER=jvb JVB_AUTH_PASSWORD='<mot de passe>'
bao policy write jicofo_jvb - <<'EOF'
path "kv/data/jicofo" { capabilities = ["read"] }
path "kv/data/jvb"    { capabilities = ["read"] }
EOF
bao auth enable kubernetes
bao write auth/kubernetes/config kubernetes_host=https://kubernetes.default.svc
bao write auth/kubernetes/role/jitsi \
  bound_service_account_names=eso-jitsi \
  bound_service_account_namespaces=jitsi \
  token_policies=jicofo_jvb ttl=1h
exit

# 7. External Secrets, puis ses objets dans le namespace jitsi
kubectl apply -f helm/eso/app.yml
kubectl -n argocd get application eso          # attendre Synced / Healthy
kubectl create namespace jitsi
kubectl -n jitsi create serviceaccount eso-jitsi
kubectl apply -f helm/eso/secret-store.yaml -f helm/eso/external-secrets.yaml
kubectl -n jitsi get secretstore,externalsecret   # Valid, puis SecretSynced

# 8. Jitsi
kubectl apply -f helm/jitsi-meet/apps/monapp.yaml
kubectl -n jitsi get pods                      # 4 pods Running

# 9. Un compte utilisateur Jitsi
kubectl -n jitsi exec -it jitsi-jitsi-meet-prosody-0 -- \
  prosodyctl --config /run/prosody/config/prosody.cfg.lua register <user> meet.jitsi '<mot de passe>'
```

L'ordre compte : Jitsi (étape 8) vient après les Secrets d'ESO (étape 7). Sinon ses pods attendent en `CreateContainerConfigError` jusqu'à ce que les Secrets existent.

Dans cette version de l'image prosody, la configuration est dans `/run/prosody/config/`, et non dans `/config/` comme l'indique la doc de docker-jitsi-meet.

Ouvre ensuite l'URL donnée par `terraform output -raw jitsi_url` et accepte l'avertissement de certificat.

ArgoCD doit pouvoir lire ce dépôt GitHub : il doit être public, ou ses identifiants doivent être ajoutés dans ArgoCD.

Sans ArgoCD, pour tester (après les étapes 5 à 7) : `helm upgrade --install jitsi helm/jitsi-meet -n jitsi -f helm/jitsi-meet/values-aws.yaml`, lancé depuis la racine du dépôt.

**Modifier un disque de prosody** (`prosody.persistence`) : Kubernetes interdit de changer les disques d'un StatefulSet existant, et la sync ArgoCD échoue (`Forbidden: updates to statefulset spec`). Il faut supprimer le StatefulSet, qu'ArgoCD recrée : `kubectl -n jitsi delete sts jitsi-jitsi-meet-prosody`. De même, un pod de StatefulSet bloqué par une mauvaise config n'est pas remplacé tout seul après la correction : `kubectl -n jitsi delete pod jitsi-jitsi-meet-prosody-0`.

**Pour tout supprimer :** les disques d'OpenBao et de prosody sont des volumes EBS créés par Kubernetes, pas par Terraform. Un `terraform destroy` seul les laisserait chez AWS (et facturés). Il faut d'abord les supprimer depuis Kubernetes :

```bash
kubectl -n argocd delete application jitsi openbao eso
kubectl delete namespace jitsi openbao     # supprime les PVC, donc les volumes EBS
kubectl get pv                             # attendre que la liste soit vide
cd learn-terraform-provision-eks-cluster && terraform destroy
```

Ne déploie pas Kustomize et Helm en même temps : les deux utilisent le namespace `jitsi` et les mêmes NodePorts.

---

## 9. Choix et limites

### Un seul jvb

Pour ce projet, un seul jvb est le bon choix :
- c'est la valeur par défaut du chart (`jvb.replicaCount: 1`) ;
- une conférence tourne de toute façon sur un seul jvb : un 2ᵉ jvb ajoute de la place pour d'autres conférences, pas pour la tienne ;
- si le pod ou son nœud tombe, Kubernetes relance jvb ailleurs et le health check redirige le NLB tout seul. La vidéo est coupée pendant le redémarrage, puis les participants se reconnectent.

Ce n'est pas de la haute disponibilité. Pour monter en charge, on ajoute des jvb, chacun joignable à sa propre adresse publique, et jicofo répartit les conférences entre eux. Le chart propose deux façons de faire :
- **`jvb.portRangeSize: N`** : N jvb derrière les mêmes IP, chacun sur son port (30300, 30301…). Avec cette infra, il faudrait aussi une écoute et un target group par port dans Terraform, et un health check par jvb : aujourd'hui, le port 30808 répond dès qu'*un* jvb est sur le nœud, et le NLB pourrait envoyer le flux du premier jvb au nœud du second.
- **`jvb.useHostPort` + `jvb.autoscaling`** : un jvb par nœud, ajouté ou retiré automatiquement selon la charge (HPA). Il faut alors des nœuds avec une IP publique, donc une autre infra réseau.

### Autres limites

- **Pas de haute disponibilité réelle** : un seul jvb et une seule passerelle NAT.
- **Certificat autosigné** : avertissement dans le navigateur. Avec un nom de domaine, on utiliserait un certificat ACM validé.
- **Valeurs recopiées à la main** : après un nouvel `apply`, l'URL et les IP du NLB changent et doivent être reportées dans `values-aws.yaml`.
- **Petits nœuds** : des `t3.small` (2 Go de RAM) suffisent pour une démo, pas pour beaucoup de participants.
- **OpenBao à déverrouiller à la main** : à chaque redémarrage du pod `openbao-0` (nœud remplacé, mise à jour), OpenBao repart verrouillé. Il faut refaire `bao operator unseal` avec les 2 clés. Pendant ce temps, ESO ne peut plus lire, mais les Secrets déjà créés restent en place et Jitsi continue de tourner.
- **Configuration d'OpenBao hors de Git** : secrets, policy, auth et role sont créés en ligne de commande (partie 8, étape 6). Un nouveau cluster repart d'un OpenBao vide, de même que le ServiceAccount `eso-jitsi` et les comptes Jitsi.
- **Changer un mot de passe interne** : ESO met à jour le Secret dans l'heure (ou tout de suite avec `force-sync`), mais les pods ne lisent leurs variables qu'au démarrage. Il faut redémarrer prosody, jicofo et jvb.
- **Comptes utilisateurs hors d'OpenBao** : ils vivent dans prosody. L'alternative serait l'auth par **JWT** : la clé de signature (`JWT_APP_SECRET`) irait dans OpenBao par le même chemin ESO (`prosody.jwt.existingSecretName`), mais il faudrait un outil pour fabriquer les tokens des utilisateurs.
