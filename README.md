# Jitsi Meet sur AWS EKS

Déploiement de la visioconférence Jitsi Meet sur AWS, entièrement automatisé :
- **GitHub Actions** lance tout à chaque push : analyse Checkov, Terraform, puis la configuration d'OpenBao ;
- **Terraform** crée le réseau, le cluster Kubernetes (EKS), le load balancer, et installe **ArgoCD** ;
- **ArgoCD** installe Jitsi, External Secrets, OpenBao et Chaos Mesh depuis ce dépôt (Helm) ;
- **OpenBao** garde les mots de passe internes de Jitsi, que **External Secrets** recopie dans Kubernetes. Il se déverrouille seul grâce à une clé AWS KMS ;
- un **stress test** (Malleus, de jitsi-meet-torture) fait entrer chaque jour à 12h de vrais navigateurs dans une réunion (partie 10) ;
- **Chaos Mesh** injecte des pannes (pod tué, CPU saturé, requêtes coupées) pour voir comment Jitsi s'en remet (partie 11).

Aucune commande manuelle après la mise en place initiale (partie 8), sauf pour lancer les expériences de Chaos Mesh.

```
.
├── .github/workflows/
│   ├── deploy.yml                checkov, terraform apply, values-infra, bootstrap OpenBao
│   ├── destroy.yml               terraform destroy + volumes EBS orphelins (lancé à la main)
│   └── stress.yml                stress test Malleus (chaque jour à 12h, ou à la main)
├── scripts/
│   ├── tfstate.sh                state Terraform ↔ artifact GitHub chiffré
│   └── bootstrap-openbao.sh      init et configuration d'OpenBao
├── terraform_infra/              Terraform : réseau, EKS, NLB, KMS, ArgoCD
├── argocd/apps/                  les Applications ArgoCD (app of apps)
│   ├── jitsi-meet.yaml
│   ├── eso.yaml
│   ├── secrets.yaml
│   ├── openbao.yaml
│   └── chaos-mesh.yaml
├── helm/
│   ├── values/
│   │   └── jitsi-meet-aws.yaml   les réglages Jitsi du projet (à la main)
│   ├── jitsi-meet/               chart Helm jitsi-meet 3.10.0
│   │   └── values-infra.yaml     l'URL et les IP du NLB (écrit par la CI)
│   └── eso/
│       ├── serviceaccount.yaml   l'identité d'ESO auprès d'OpenBao
│       ├── secret-store.yaml     la connexion à OpenBao
│       └── external-secrets.yaml secrets OpenBao → Secrets Kubernetes
├── malleus/                      les deux images du stress test
│   ├── grid/Dockerfile           Selenium + Chrome + vidéo et son de test
│   └── malleus/Dockerfile        jitsi-meet-torture (Malleus), commit épinglé
└── chaos-mesh/                   les expériences de panne (lancées à la main, jamais par ArgoCD)
    ├── pod-chaos.yaml
    ├── jvb-cpu-stress.yaml
    └── http-chaos-abort.yaml
```

Le dossier `helm/jitsi-meet/` contient le chart complet, identique au chart officiel 3.10.0 (`values.yaml` compris). Les réglages du projet sont rangés à part, dans `helm/values/jitsi-meet-aws.yaml`, pour ne pas les mélanger au chart. L'URL et les IP du NLB sont dans `values-infra.yaml`, que la CI écrit dans le dossier du chart (partie 5). ArgoCD lit le chart et ces deux fichiers dans ce dépôt, sur GitHub (branche `main`).

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
- **3 IP fixes** (Elastic IP) : un NLB n'envoie du trafic qu'aux nœuds des AZ où il est présent. Les nœuds sont répartis sur 3 AZ et jvb peut tomber dans n'importe laquelle, donc le NLB est présent dans les 3 AZ, avec une adresse par AZ. Ces adresses sont fixées pour que Terraform les connaisse et qu'on puisse les donner à jvb. Elles changent à chaque nouveau cluster : la CI les réécrit alors dans `values-infra.yaml`.
- **NAT** : la porte de **sortie**. Les nœuds n'ont pas d'IP publique, mais doivent télécharger les images Docker.
- **Security groups** (pare-feu) : internet ne joint que le NLB, et les nœuds n'acceptent que le NLB.
- **Certificat autosigné** : le navigateur refuse la caméra sans HTTPS, et le projet n'a pas de nom de domaine. Le NLB déchiffre le HTTPS avec un certificat autosigné : il faut accepter l'avertissement du navigateur une fois.

---

## 3. Kubernetes : nœud, pod, Service

- **Nœud** : une machine EC2 (`c7i-flex.large`). Il y en a 3.
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
 TERRAFORM (crée AWS)                  HELM (crée Kubernetes, via ArgoCD)
 ─────────────────────                 ──────────────────────────────────
 VPC, sous-réseaux, NAT                pods web, prosody, jicofo, jvb
 cluster EKS + 3 nœuds                 Service web  NodePort 30080
 NLB + 3 IP fixes + certificat         Service jvb  NodePort 30300 (UDP)
 pare-feu                                           NodePort 30808 (santé)
        │                                            │
        └──── ils doivent être d'accord sur : ───────┘
              • les ports 30080, 30300, 30808  → écrits en dur des deux côtés
              • l'URL du NLB   ┐  terraform output jitsi_values
              • les 3 IP fixes ┘  → values-infra.yaml, écrit par la CI
```

Les ports ne changent jamais. L'URL et les IP du NLB changent à chaque nouveau cluster : c'est la CI qui les recopie (partie 8). Si un de ces numéros change d'un côté sans changer de l'autre, Jitsi ne marche plus.

| Port | Où | Sert à |
|---|---|---|
| 80 / 443 | NLB (public) | le site (443 = chiffré) |
| 30300 UDP | NLB, nœuds, pod jvb | la vidéo |
| 30080 | nœuds → pod web :8000 | le site, une fois déchiffré |
| 30808 | nœuds → pod jvb :8080 | le health check de jvb |
| 5280 | prosody (interne) | les messages de contrôle |

L'Application ArgoCD de Jitsi lit deux fichiers de values, dans cet ordre (le second l'emporte, Helm fusionne les blocs) :

| Fichier | Écrit par | Contenu |
|---|---|---|
| `helm/values/jitsi-meet-aws.yaml` | à la main | les réglages du projet (tableau ci-dessous) |
| `helm/jitsi-meet/values-infra.yaml` | la CI, après chaque `terraform apply` | `publicURL`, `jvb.publicIPs`, et une annotation `jitsi/public-url` sur tous les pods |

Le premier est hors du dossier du chart : l'Application le désigne par `../values/jitsi-meet-aws.yaml`, relatif au chart. ArgoCD accepte un fichier de values situé ailleurs tant qu'il est dans le même dépôt.

**Pourquoi l'annotation :** le chart range `PUBLIC_URL` dans une ConfigMap commune, et aucun pod ne redémarre quand elle change. Sans rien d'autre, web garderait l'URL de l'ancien NLB. L'annotation change avec l'URL : Kubernetes voit des pods modifiés et les redémarre.

Réglages de `helm/values/jitsi-meet-aws.yaml`, qui remplacent ceux du chart officiel :

| Réglage | Valeur | Pourquoi |
|---|---|---|
| `web.service` | `NodePort` 30080 | cible du NLB pour le site |
| `web.extraEnvs` | `ENABLE_P2P: "false"` | toute la vidéo passe par jvb |
| `web.extraEnvs` | `ENABLE_PREJOIN_PAGE: "false"` | pas d'écran de pré-connexion : sans ça, le stress test entre sans micro ni caméra (partie 10) |
| `jicofo.strategy` | `type: Recreate` | jamais deux jicofo en même temps pendant un redéploiement (pièges, partie 8) |
| `jvb.disableStun` | `true` | inutile, les IP publiques sont déjà connues |
| `jvb.UDPPort` / `jvb.nodePort` | 30300 | même port partout |
| `jvb.service` | `NodePort`, `Local` | voir la partie 3 |
| `jvb.service.extraPorts` | 8080 → NodePort 30808 | health check du NLB |
| `jicofo.xmpp.existingSecretName` | `jitsi-jicofo-bao` | mot de passe de jicofo venant d'OpenBao (partie 7) |
| `jvb.xmpp.existingSecretName` | `jitsi-jvb-bao` | identifiant et mot de passe de jvb venant d'OpenBao (partie 7) |
| `enableAuth` / `enableGuests` | `false` / `false` | pas de comptes utilisateurs (partie 7) |
| `prosody.persistence` | `true`, classe `gp2` | servait aux comptes utilisateurs ; inutile depuis `enableAuth: false`, mais sans effet gênant |

---

## 6. Le code Terraform, bloc par bloc

Le code est dans `terraform_infra/`. La première partie de `main.tf` vient du tutoriel HashiCorp (réseau et cluster), la suite concerne Jitsi (le load balancer), OpenBao (la clé KMS) et ArgoCD. **Terraform ne tourne que dans la CI** (partie 8).

| Bloc | Ce qu'il crée | Pourquoi |
|---|---|---|
| `data "aws_availability_zones"` | rien : la liste des 3 AZ `a`, `b`, `c` | liste fermée, pour qu'une AZ ajoutée par AWS ne change pas le réseau toute seule |
| `module "vpc"` | le réseau, 3 sous-réseaux publics, 3 privés, 1 NAT | les nœuds sont isolés d'internet et sortent par le NAT |
| `module "eks"` | le cluster et 1 groupe de 3 nœuds `c7i-flex.large` (3 à 5) | le groupe est un Auto Scaling Group (ASG) AWS, qui répartit les nœuds sur les 3 AZ |
| `module "eks"` → `access_entries` | l'accès admin au cluster pour le compte root | pour `kubectl` depuis un poste ; la CI, elle, est admin parce qu'elle crée le cluster |
| `module "irsa-ebs-csi"` | un rôle IAM pour le pilote de disques EBS | le pod reçoit des droits AWS sans clé stockée (IRSA) |
| `aws_kms_key`, `aws_kms_alias` | la clé du déverrouillage d'OpenBao, alias fixe `alias/openbao-unseal` | chaque cluster recrée la clé, mais l'alias garde le même nom, écrit dans la config d'OpenBao |
| `aws_iam_policy "openbao_kms"`, `module "irsa-openbao"` | le rôle `openbao-unseal` (nom fixe), donné au ServiceAccount `openbao/openbao` | OpenBao a le droit de chiffrer et déchiffrer avec la clé, et rien d'autre |
| `locals` (`jitsi_targets`, `jitsi_listeners`) | rien : deux tables de ports | parcourues par les `for_each` qui suivent |
| `tls_private_key`, `tls_self_signed_cert`, `aws_acm_certificate` | le certificat autosigné, importé dans ACM | HTTPS obligatoire pour la caméra ; un NLB ne prend que des certificats ACM |
| `aws_security_group` et ses règles | les pare-feu du NLB et des nœuds | internet → NLB → nœuds, rien d'autre |
| `aws_eip` | 3 IP publiques | jvb doit connaître son adresse publique |
| `aws_lb` | le NLB, dans les 3 sous-réseaux publics | transporte TCP et UDP |
| `aws_lb_target_group` | `jitsi-web` (TCP 30080) et `jitsi-jvb` (UDP 30300) | où envoyer le trafic, avec leur health check |
| `aws_lb_listener` | les écoutes 80, 443 (TLS) et 30300 (UDP) | ce que le NLB écoute publiquement |
| `aws_autoscaling_attachment` | 2 liaisons (2 target groups × 1 groupe de nœuds) | tout nouveau nœud est ajouté au NLB automatiquement |
| `provider "helm"`, `helm_release "argocd"` | ArgoCD (chart `argo-cd` 10.18.0) | installé dès que les nœuds sont prêts (`depends_on = [module.eks]`) |
| `helm_release "argocd-apps"` | l'app racine d'ArgoCD (chart `argocd-apps` 2.0.8) | point de départ de tout ce que déploie ArgoCD (partie 8) |
| `output "jitsi_values"` | rien : le contenu de `values-infra.yaml` | la CI l'écrit tel quel (`terraform output -raw jitsi_values`) |

Le NLB est créé par Terraform plutôt que par Kubernetes (Service `LoadBalancer`) pour deux raisons : il est dans le state, donc `terraform destroy` le supprime proprement, et ses IP sont connues avant le déploiement de Jitsi.

Les descriptions des security groups sont en ASCII : AWS refuse les accents dedans.

Les commentaires `# checkov:skip=…` marquent les alertes de Checkov (partie 8) qui ne s'appliquent pas ici, avec la raison : la protection contre la suppression du NLB bloquerait `destroy`, un health check ELB sur l'ASG remplacerait en boucle les nœuds qui ne portent pas jvb, et deux faux positifs (EIP attachées au NLB, redirection HTTPS qui n'existe que sur un ALB).

---

## 7. Les secrets

### Les mots de passe internes : OpenBao + External Secrets

jicofo et jvb se connectent à prosody avec un identifiant et un mot de passe. Ce sont des **comptes internes**, que personne ne tape. Par défaut, le chart les génère au hasard et les range dans des Secrets Kubernetes. Ici, ils sont gardés dans **OpenBao** (un coffre à secrets, version libre de Vault), qui devient la source de vérité.

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

| Où | Objet | Créé par |
|---|---|---|
| OpenBao | moteur `kv` (KV version 2) : `kv/jicofo`, `kv/jvb` | le script de bootstrap |
| OpenBao | auth `kubernetes` | le script de bootstrap |
| OpenBao | policy `jicofo_jvb` : lecture seule des deux secrets | le script de bootstrap |
| OpenBao | role `jitsi` : donne la policy au ServiceAccount `eso-jitsi` | le script de bootstrap |
| namespace `jitsi` | ServiceAccount `eso-jitsi` : l'identité que présente ESO | Git (`helm/eso/serviceaccount.yaml`), via ArgoCD |
| namespace `jitsi` | SecretStore `secret-store` : l'adresse d'OpenBao et la méthode d'auth | Git (`helm/eso/`), via ArgoCD |
| namespace `jitsi` | ExternalSecrets `jicofo`, `jvb` : quoi copier, et vers quel Secret | Git (`helm/eso/`), via ArgoCD |

Les noms des clés dans OpenBao deviennent tels quels les noms des variables d'environnement (`dataFrom.extract`) : ils doivent être exacts (`JVB_AUTH_USER`, pas `JVB_AUTH_USER_`).

### Le déverrouillage automatique (auto-unseal KMS)

Au démarrage, OpenBao est **scellé** : il ne peut rien lire tant qu'il n'a pas sa clé maîtresse. Ici, cette clé est chiffrée par une clé AWS KMS (`seal "awskms"` dans `argocd/apps/openbao.yaml`). Le pod obtient le droit d'utiliser KMS par son ServiceAccount, annoté avec le rôle IAM `openbao-unseal` (IRSA), sans aucune clé AWS écrite quelque part.

Résultat : à chaque redémarrage du pod, OpenBao se déverrouille seul (« unsealed with stored key »). L'init n'a lieu qu'une fois par cluster ; avec KMS, elle donne une **recovery key** à la place des clés de déverrouillage.

OpenBao est en **2.6** (chart 0.29.6) : à partir de la 2.7, le seal `awskms` n'est plus intégré et devient un plugin à installer à part. Le stockage est `file`, celui du chart 0.29 (`pebbledb` n'existe qu'en 2.7).

### La configuration d'OpenBao : `scripts/bootstrap-openbao.sh`

Lancé par la CI après chaque `terraform apply`. Chaque étape regarde d'abord ce qui existe déjà : on peut le relancer sans rien casser.

1. Attendre que le pod `openbao-0` soit **Running**, pas Ready : OpenBao ne devient Ready qu'une fois déverrouillé, donc attendre Ready bloquerait pour toujours.
2. Si OpenBao n'est pas initialisé : `bao operator init`. Le root token et la recovery key sont rangés, chiffrés, dans AWS SSM Parameter Store (`/gestion-conf/openbao/init`). Ils ne passent jamais dans les logs : le dépôt est public, ses logs de CI aussi.
3. Attendre le déverrouillage par KMS.
4. Créer le moteur `kv`, l'auth `kubernetes` et sa config, la policy `jicofo_jvb` et le role `jitsi`.
5. Tirer au hasard les mots de passe de jicofo et jvb, **une seule fois** : s'ils existent déjà, ils ne sont jamais régénérés (les pods ne les lisent qu'au démarrage).
6. Relancer ESO, qui après ses échecs du début (OpenBao pas encore prêt) pourrait attendre jusqu'à ~16 min avant de réessayer, puis attendre que les deux ExternalSecrets soient prêts.

**Pièges rencontrés :**
- En KV version 2, les données sont rangées sous `kv/data/...` : la policy vise `kv/data/jicofo`. La règle `kv/data/jicofo/*` ne couvre que ce qui est *sous* `jicofo/`, pas `jicofo` lui-même.
- `kubernetes_host` doit valoir `https://kubernetes.default.svc`, **sans point final**. Avec un point, le nom n'est pas complété en `.cluster.local`, OpenBao ne joint pas l'API Kubernetes et répond seulement `permission denied`.
- Le role doit donner la policy (`token_policies`) : sans elle, ESO se connecte mais n'a le droit de rien lire.
- Le ServiceAccount `eso-jitsi` doit être dans Git : créé à la main, il manque sur chaque nouveau cluster et ESO ne peut pas se connecter.
- OpenBao 2.7 avec `seal "awskms"` plante au démarrage (`unknown wrapper: awskms`) : voir plus haut.
- Après une erreur, ESO réessaie de moins en moins souvent. Pour le relancer tout de suite :
  `kubectl -n jitsi annotate externalsecret jicofo jvb force-sync=$(date +%s) --overwrite`

### Pas de comptes utilisateurs

Avec `enableAuth: false`, il n'y a pas de comptes : toute personne qui a l'URL peut créer une salle et la rejoindre. Il n'y a donc rien à créer dans prosody.

---

## 8. Déployer

### Une seule fois, à la main

| Où | Quoi |
|---|---|
| AWS IAM → Identity providers | fournisseur OpenID Connect `token.actions.githubusercontent.com`, audience `sts.amazonaws.com` (**sans point final**) |
| AWS IAM → Roles | rôle `deploy_eks` (droits `AdministratorAccess`), qui fait confiance à ce fournisseur avec deux conditions : `aud` = `sts.amazonaws.com`, et `sub` = `repo:TNav13@187294659/gestion_de_conf@1425369785:*` |
| GitHub → Settings → Secrets and variables → Actions | **variable** `DEPLOY_EKS` = l'ARN du rôle ; **secret** `TF_STATE_PASSPHRASE` = une phrase de chiffrement (`openssl rand -base64 32`) |

Le `sub` est l'identité que GitHub présente à AWS. Pour les dépôts créés après le 15 juillet 2026, GitHub y met les **identifiants numériques** du compte (`@187294659`) et du dépôt (`@1425369785`) : ils ne changent jamais, même si on renomme le compte ou le dépôt, et personne ne peut recréer un dépôt du même nom pour prendre le rôle.

### Déployer : un push

Le workflow `.github/workflows/deploy.yml` se lance à chaque push sur `main` qui touche `terraform_infra/`, `scripts/` ou le workflow lui-même, ou à la main (Actions → deploy → Run workflow).

```
push sur main
 ├─ job checkov    analyse statique du Terraform, des manifestes et des workflows
 └─ job deploy     (attend checkov)
     1. connexion à AWS par OIDC : le rôle deploy_eks, sans clé stockée
     2. récupération du state : dernier artifact tfstate, déchiffré   (scripts/tfstate.sh pull)
     3. terraform apply : réseau, EKS, NLB, KMS, ArgoCD et l'app racine
     4. state chiffré et sauvegardé en artifact, même si l'apply échoue (scripts/tfstate.sh encrypt)
     5. values-infra.yaml ← terraform output jitsi_values, commité par github-actions[bot]
     6. bootstrap d'OpenBao                                            (scripts/bootstrap-openbao.sh)
```

Depuis zéro, il faut environ 17 minutes (dont 14 pour `terraform apply`). Sans changement d'infra, environ 2 minutes.

**Pour redéployer, utiliser Run workflow, jamais « Re-run jobs ».** Un re-run rejoue le run d'origine sur **son** commit, pas sur le dernier de `main` : Terraform appliquerait l'ancien code, et le commit de `values-infra.yaml` entrerait en conflit avec celui déjà sur `main` (`CONFLICT (content): Merge conflict in helm/jitsi-meet/values-infra.yaml`). Le conflit est un garde-fou : sans lui, le bot pousserait des valeurs calculées par l'ancien code.

Les changements dans `helm/` ou `argocd/` ne relancent pas la CI : ArgoCD relit GitHub toutes les 2 minutes environ et les applique (bouton **Refresh** sur l'app `root` pour ne pas attendre). Le commit de la CI ne relance pas non plus le workflow : un push fait avec le jeton automatique `GITHUB_TOKEN` ne déclenche aucun workflow.

**Ne jamais lancer `terraform apply` depuis un poste** : le state est dans l'artifact, pas sur le poste, et un apply en root créerait une deuxième access entry pour root, ce qu'EKS refuse.

### Le state Terraform : un artifact chiffré

GitHub ne sait pas garder un state Terraform. Le state est donc chiffré (AES-256, avec le secret `TF_STATE_PASSPHRASE`) et envoyé en **artifact** `tfstate` à la fin de chaque run ; le run suivant récupère le plus récent. Le chiffrement est obligatoire : les artifacts d'un dépôt public sont téléchargeables par n'importe quel compte GitHub, et le state contient en clair la clé privée du certificat.

- Le state est sauvegardé **même si `terraform apply` échoue** : ce qui a déjà été créé doit rester connu, sinon le run suivant recréerait tout en double.
- Il n'est **jamais** sauvegardé si sa récupération a échoué (mauvaise phrase de chiffrement, API GitHub injoignable) : un state vide écraserait le bon.
- `deploy` et `destroy` ne tournent jamais en même temps (même groupe `concurrency`), donc deux runs n'écrivent jamais le state en même temps.
- Les artifacts sont gardés 7 jours.

### ArgoCD : l'app of apps

Une **Application** ArgoCD dit : « prends telle source dans Git, et applique-la dans tel namespace ». Terraform ne crée qu'une seule Application, **root**, qui lit le dossier `argocd/apps/`. Ce dossier ne contient que des Applications, qu'ArgoCD crée à leur tour :

```
Terraform ──► Application root  (lit argocd/apps/ sur GitHub)
                 ├─► Application eso      → chart external-secrets 2.15.0
                 ├─► Application secrets  → helm/eso/ (ServiceAccount, SecretStore, ExternalSecrets)
                 ├─► Application openbao    → chart openbao 0.29.6
                 ├─► Application chaos-mesh → chart chaos-mesh 2.8.8 (partie 11)
                 └─► Application jitsi      → helm/jitsi-meet/ + helm/values/jitsi-meet-aws.yaml + values-infra.yaml
```

Ajouter une app, c'est poser un fichier dans `argocd/apps/` ; le supprimer retire l'app. La règle : **un fichier `kind: Application` va dans `argocd/apps/`, les charts, les values et les manifestes restent dans `helm/`.** Tout ce qui est ailleurs (`chaos-mesh/`, `malleus/`) n'est jamais appliqué par ArgoCD.

L'app `secrets` a besoin des types `SecretStore` et `ExternalSecret`, qui n'existent qu'une fois ESO installé. Elle réessaie donc sans limite (`retry.limit: -1`) et saute la vérification préalable des types (`SkipDryRunOnMissingResource=true`) : sinon, un sync raté n'est jamais retenté sur le même commit.

ArgoCD lit ce dépôt sur GitHub : il doit être public, ou ses identifiants doivent être ajoutés dans ArgoCD.

### Se connecter au cluster

```bash
aws eks list-clusters --region eu-north-1          # le nom a un suffixe aléatoire
aws eks update-kubeconfig --region eu-north-1 --name <nom>
kubectl get nodes

# Interface d'ArgoCD : https://localhost:8080, utilisateur admin
# (le "; echo" évite le % que zsh affiche après le mot de passe, qui n'en fait pas partie ;
#  après 5 échecs, ArgoCD bloque le compte 5 minutes, même avec le bon mot de passe)
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo
kubectl -n argocd port-forward svc/argocd-server 8080:443

# Se connecter à OpenBao avec le root token rangé dans SSM
aws ssm get-parameter --region eu-north-1 --name /gestion-conf/openbao/init --with-decryption \
  --query Parameter.Value --output text | jq -r .root_token
kubectl -n openbao exec -it openbao-0 -- bao login

# Dashboard de Chaos Mesh : http://localhost:2333 (sans jeton)
kubectl -n chaos-mesh port-forward svc/chaos-dashboard 2333:2333
```

Ouvre ensuite l'URL `publicURL` de `helm/jitsi-meet/values-infra.yaml` et accepte l'avertissement de certificat.

### Tout supprimer

GitHub → Actions → **destroy** → Run workflow, puis taper `destroy` pour confirmer. Le workflow récupère le state, lance `terraform destroy`, sauvegarde le state vidé (le prochain deploy repart de zéro), puis supprime les volumes EBS laissés par les disques de prosody et d'OpenBao : créés par Kubernetes et pas par Terraform, ils survivraient au cluster et resteraient facturés. Les clés KMS ne disparaissent pas tout de suite : AWS impose une attente de 7 jours minimum.

### Pièges rencontrés

| Erreur | Cause |
|---|---|
| `The web identity token provided could not be validated` | l'audience du fournisseur OIDC était `sts.amazonaws.com.`, avec un point final |
| `Not authorized to perform sts:AssumeRoleWithWebIdentity` | la condition `sub` du rôle attendait l'ancien format `repo:TNav13/gestion_de_conf:*` |
| job checkov en échec | la dernière release de `checkov-action` embarque Checkov 2.0 (2022) : Checkov 3 est installé avec `pip` |
| `cannot pull with rebase: You have unstaged changes` | `terraform init` ajoute les empreintes Linux dans `.terraform.lock.hcl` sur le runner : `git pull --rebase --autostash` |
| tout recréé au run suivant | sans sauvegarde, le state reste sur le runner et disparaît avec lui : d'où l'artifact |
| `CONFLICT (content): Merge conflict in helm/jitsi-meet/values-infra.yaml` | « Re-run jobs » sur un ancien run, qui rejoue l'ancien commit : utiliser Run workflow (plus haut) |
| aucune conférence ne démarre, jicofo `Running` mais 0 bridge, `conflict: Replaced by new connection` dans ses logs | pendant un redéploiement, l'ancien et le nouveau jicofo se sont connectés en même temps à prosody ; celui qui est éjecté ne se reconnecte jamais. Corrigé par `jicofo.strategy: Recreate`. Dépannage : `kubectl -n jitsi delete pod -l app.kubernetes.io/component=jicofo` |

**Débugger une connexion OIDC refusée :** le log GitHub dit seulement « Not authorized ». Le détail est dans CloudTrail (région `eu-north-1`, Event history, événement `AssumeRoleWithWebIdentity`) : `userIdentity.userName` montre le `sub` exact présenté par GitHub, à comparer avec la condition du rôle. CloudTrail met 5 à 15 minutes à afficher un événement.

**Checkov** tourne en mode rapport (`--soft-fail`) : il affiche ses alertes sans bloquer le déploiement. Il en reste 7, acceptées pour ce projet : le port 80 ouvert, pas de logs d'accès du NLB, pas de policy KMS écrite à la main, et des modules épinglés par numéro de version plutôt que par commit. Pour le rendre bloquant, retirer `--soft-fail` dans `deploy.yml`.

**Modifier un disque de prosody** (`prosody.persistence`) : Kubernetes interdit de changer les disques d'un StatefulSet existant, et la sync ArgoCD échoue (`Forbidden: updates to statefulset spec`). Il faut supprimer le StatefulSet, qu'ArgoCD recrée : `kubectl -n jitsi delete sts jitsi-jitsi-meet-prosody`. De même, OpenBao est en `updateStrategy: OnDelete` : après un changement de sa config, il faut supprimer le pod `openbao-0` pour qu'elle soit prise en compte.

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
- **prosody, point de défaillance unique** : il ne se met pas en cluster, toute la signalisation passe par lui, et son disque EBS l'attache à une seule AZ (son pod ne peut revenir que sur le nœud de cette AZ).
- **Limites mémoire plus grandes que les nœuds** : le chart donne 4 Gi à jvb et jicofo, alors qu'un nœud n'en a qu'environ 3,1 allouables. La limite ne protège rien : c'est le nœud entier qui manque de mémoire avant.
- **Pas d'écran de pré-connexion** : désactivé pour le stress test (partie 10), les utilisateurs entrent directement avec micro et caméra.
- **Certificat autosigné** : avertissement dans le navigateur. Avec un nom de domaine, on utiliserait un certificat ACM validé.
- **State dans un artifact** : pas d'historique, et pas de verrou en dehors du groupe `concurrency` des workflows ; les artifacts expirent au bout de 7 jours. Suffisant pour un projet détruit après la démo ; pour durer, on passerait à un backend S3.
- **OpenBao figé en 2.6** : pour passer en 2.7, il faudrait installer le plugin KMS AWS et le déclarer dans la config.
- **Premier déploiement avec l'ancienne URL** : sur un nouveau cluster, ArgoCD déploie d'abord le `values-infra.yaml` encore dans Git, celui du cluster précédent. Les pods redémarrent quelques minutes plus tard, quand la CI commite les nouvelles valeurs.
- **Nœuds** : des `c7i-flex.large` (2 vCPU, 4 Go, éligibles au free tier) suffisent pour une démo. Un `t3.small` n'accepte que 11 pods par nœud (une IP du VPC par pod), trop peu pour ArgoCD, ESO, OpenBao et Jitsi ; un `large` en accepte 29.
- **Changer un mot de passe interne** : ESO met à jour le Secret dans l'heure (ou tout de suite avec `force-sync`), mais les pods ne lisent leurs variables qu'au démarrage. Il faut redémarrer prosody, jicofo et jvb.
- **Pas d'authentification** : n'importe qui ayant l'URL peut créer une salle. Pour en remettre une, `enableAuth: true` avec des comptes prosody, ou l'auth par **JWT** : sa clé de signature (`JWT_APP_SECRET`) irait dans OpenBao par le même chemin ESO (`prosody.jwt.existingSecretName`), mais il faudrait un outil pour fabriquer les tokens des utilisateurs.

---

## 10. Le stress test : Malleus

Malleus est l'outil de test de charge de [jitsi-meet-torture](https://github.com/jitsi/jitsi-meet-torture), le projet de tests de Jitsi. Il pilote de vrais navigateurs Chrome (Selenium) qui rejoignent une salle et envoient une vidéo et un son de test.

### Les deux images

| Image | Dossier | Contenu |
|---|---|---|
| `grid` | `malleus/grid/` | `selenium/standalone-chrome` (tag épinglé) + la vidéo `FourPeople_1280x720_30.y4m` et le son `fakeAudioStream.wav` dans `/usr/share/jitsi-meet-torture/resources` |
| `malleus` | `malleus/malleus/` | Maven + Java 11 (la version de la CI de torture) et jitsi-meet-torture au commit `4c00915`, compilé au build |

Les fichiers de test sont dans l'image **grid**, pas dans malleus : c'est Chrome, sur le grid, qui les lit. `malleus.sh` passe `-Dremote.resource.path=/usr/share/jitsi-meet-torture`, d'où ce chemin.

### Le workflow `.github/workflows/stress.yml`

Lancé chaque jour à 12h, heure de Paris (`timezone: Europe/Paris`), ou à la main (Actions → stress → Run workflow). Il n'a besoin d'aucun accès à AWS.

1. Lit `publicURL` dans `helm/jitsi-meet/values-infra.yaml` et vérifie que Jitsi répond. Après un `destroy`, le fichier garde l'ancienne URL : le job échoue tout de suite, en rouge.
2. Construit les deux images sur le runner (environ 2 minutes).
3. Démarre le grid sous le nom `selenium-grid`, avec 5 sessions Chrome (`SE_NODE_MAX_SESSIONS=5`) et un `/dev/shm` agrandi, sans quoi Chrome plante dans Docker.
4. Lance Malleus : une conférence `bench0`, 5 participants qui envoient tous audio et vidéo, pendant 5 minutes.

```bash
docker run --rm --network stress malleus \
  --conferences=1 --participants=5 --senders=5 --audio-senders=5 \
  --duration=300 --room-name-prefix=bench \
  --hub-url=http://selenium-grid:4444/wd/hub \
  --instance-url="$JITSI_URL" --allow-insecure-certs=true --headless
```

- **Toujours la forme `--option=valeur`** : avec des arguments positionnels, `malleus.sh` force l'URL `https://meet.jit.si`, le Jitsi public. Sans `--instance-url`, l'image vise une adresse invalide et échoue (garde-fou dans le Dockerfile).
- `--allow-insecure-certs=true` : le certificat du NLB est autosigné.
- Un seul run à la fois (`concurrency: stress`) : deux runs rejoindraient la même salle.

### Ce que mesure un run

Un run vert veut dire que les 5 participants sont restés dans la conférence pendant 5 minutes. **Il ne vérifie pas que la vidéo passe.** Pour ça, il faut lire les statistiques du jvb pendant le run :

```bash
kubectl -n jitsi exec deploy/jitsi-jitsi-meet-jvb-0 -- curl -s localhost:8080/colibri/stats \
  | jq '{conferences, participants, endpoints_sending_video, bit_rate_download, bit_rate_upload, stress_level}'
```

Run du 18 novembre 2026 : 5 participants sur 5 envoient de la vidéo, le jvb reçoit 1,9 Mbit/s et en redistribue 4,5, avec un `stress_level` de 0,10 au maximum. Jitsi est loin de sa limite.

### Pièges rencontrés

| Problème | Cause |
|---|---|
| les participants entrent sans micro ni caméra, le jvb ne reçoit rien | torture ajoute `config.prejoinConfig.enabled=false` à ses URL, et Jitsi traite ce paramètre comme « entrer sans média » (`disableInitialGUM`), sauf dans une iframe. L'écran de pré-connexion est donc désactivé côté serveur (`ENABLE_PREJOIN_PAGE`), et le Dockerfile retire ce paramètre de torture (`sed`) |
| à 10 participants : pages rechargées, `APP is not defined`, vidéo en 180p | c'est le runner (4 vCPU) qui sature, pas Jitsi : le jvb ne dépassait pas 0,17 de `stress_level`. D'où 5 participants |
| Chrome du grid très lent sur un Mac Apple Silicon | `selenium/standalone-chrome` n'existe qu'en amd64 : en local, il tourne en émulation. Les runners GitHub sont en amd64 |

---

## 11. Chaos Mesh : injecter des pannes

Chaos Mesh (chart 2.8.8) est installé par ArgoCD (`argocd/apps/chaos-mesh.yaml`) dans le namespace `chaos-mesh` : un contrôleur, un `chaos-daemon` par nœud (c'est lui qui agit dans les conteneurs) et un dashboard.

| Réglage | Pourquoi |
|---|---|
| `chaosDaemon.runtime: containerd`, `chaosDaemon.socketPath: /run/containerd/containerd.sock` | les nœuds EKS tournent sous containerd ; le chart suppose Docker par défaut |
| `dashboard.securityMode: "false"` | pas de jeton pour le dashboard. Entre guillemets : dans une Application, la valeur d'un paramètre Helm doit être une chaîne, sinon Kubernetes refuse l'Application |
| `ServerSideApply=true` | trois CRDs (`workflownodes`, `schedules`, `workflows`) dépassent les 256 Ko qu'accepte l'apply classique d'ArgoCD |
| `ignoreDifferences` + `RespectIgnoreDifferences=true` | les certificats générés par le chart, ci-dessous |

### Les certificats générés au rendu

Le chart fabrique ses certificats (webhooks, mTLS entre le contrôleur et les daemons) et une annotation `rollme` **au hasard, à chaque rendu** (`genCA`, `randAlphaNum`). C'est prévu pour `helm install`, qui ne rend qu'une fois. ArgoCD, lui, refait le rendu (à l'expiration de son cache de 24 h, à un hard refresh, à une modification de l'app) : à chaque fois, de nouveaux certificats et un redémarrage du contrôleur et des daemons.

À l'installation, ArgoCD a synchronisé 4 fois de suite et mélangé plusieurs rendus : le contrôleur et les daemons n'avaient plus la même CA (`x509: certificate signed by unknown authority`). Aucune expérience qui passe par le daemon (CPU, réseau, HTTP, disque) n'était injectée ; seul `pod-kill`, qui passe par l'API Kubernetes, marchait.

`ignoreDifferences` (l'annotation `rollme`, les 4 Secrets de certificats, les `caBundle` des webhooks) et `RespectIgnoreDifferences=true` font garder à ArgoCD ce qui est déjà dans le cluster.

**Si ça recommence** (expérience `Not Injected`, erreur x509 dans `kubectl -n jitsi get stresschaos <nom> -o yaml`), remettre les certificats en cohérence :

```bash
kubectl -n chaos-mesh delete secret chaos-mesh-webhook-certs chaos-mesh-daemon-certs \
  chaos-mesh-daemon-client-certs chaos-mesh-chaosd-client-certs
kubectl delete mutatingwebhookconfiguration chaos-mesh-mutation
kubectl delete validatingwebhookconfiguration chaos-mesh-validation chaos-mesh-validation-auth
# ArgoCD les recrée à partir d'un seul rendu ; les pods rechargent ensuite les certificats :
kubectl -n chaos-mesh delete pod -l app.kubernetes.io/component=controller-manager
kubectl -n chaos-mesh delete pod -l app.kubernetes.io/component=chaos-daemon
```

Supprimer les pods plutôt que faire un `rollout restart` : l'annotation que ce dernier ajoute au Deployment serait vue comme une différence et annulée par ArgoCD. Sur chaque nouveau cluster, vérifier avec un StressChaos de 20 s. La solution définitive serait cert-manager (`webhook.certManager.enabled`), qui produit les certificats une seule fois.

### Les expériences : `chaos-mesh/`

Ce dossier est en dehors de `argocd/apps/` : ArgoCD n'y touche jamais, et une expérience ne tourne que quand on la lance. De préférence pendant un run du stress test :

```bash
kubectl apply -f chaos-mesh/jvb-cpu-stress.yaml
kubectl -n jitsi get stresschaos                     # injectée ? terminée ?
kubectl delete -f chaos-mesh/jvb-cpu-stress.yaml     # obligatoire avant de la relancer
```

| Fichier | Ce qu'il fait | Effet |
|---|---|---|
| `pod-chaos.yaml` | `pod-failure` du jvb pendant 30 s : le conteneur ne répond plus, sans être supprimé | attendu : vidéo coupée 30 s, réunions conservées |
| `jvb-cpu-stress.yaml` | 2 workers à 100 % dans le pod jvb pendant 2 min | mesuré sur 20 s : le nœud du jvb à 1 886 millicores sur 2 000 |
| `http-chaos-abort.yaml` | coupe les requêtes `/http-bind` du pod web (port 8000) pendant 20 s | attendu : le site s'affiche, mais personne ne peut entrer en réunion. Pas encore testé |

Le `pod-kill` du jvb, fait depuis le dashboard, a montré la reprise : le nouveau pod jvb est enregistré auprès de jicofo 3 s après, et jicofo y réinvite les participants. Personne n'est éjecté, car la réunion vit dans prosody. Seul dans une salle, on ne remarque rien : jicofo n'utilise un jvb qu'à partir de 2 participants.

| Pod visé | Ce qui tombe | Ce qui continue |
|---|---|---|
| web | le site, les nouvelles entrées, puis la signalisation (`/http-bind` passe par web) | le média des réunions en cours |
| jvb | le média, quelques secondes | les salles, la signalisation |
| prosody | tout : c'est le point de défaillance unique | rien |
