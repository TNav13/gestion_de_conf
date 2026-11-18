# Architecture

## Comment fonctionne Jitsi Meet

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

## L'infrastructure AWS

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
- **3 IP fixes** (Elastic IP) : un NLB n'envoie du trafic qu'aux nœuds des AZ où il est présent. Les nœuds sont répartis sur 3 AZ et jvb peut tomber dans n'importe laquelle, donc le NLB est présent dans les 3 AZ, avec une adresse par AZ. Ces adresses sont fixées pour que Terraform les connaisse et qu'on puisse les donner à jvb.
- **NAT** : la porte de **sortie**. Les nœuds n'ont pas d'IP publique, mais doivent télécharger les images Docker.
- **Security groups** (pare-feu) : internet ne joint que le NLB, et les nœuds n'acceptent que le NLB.
- **Certificat autosigné** : le navigateur refuse la caméra sans HTTPS, et le projet n'a pas de nom de domaine. Le NLB déchiffre le HTTPS avec un certificat autosigné : il faut accepter l'avertissement du navigateur une fois.

---

## Kubernetes : nœud, pod, Service

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

## Le trajet du trafic

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

## Le contrat entre Terraform et Helm

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

Les ports ne changent jamais. L'URL et les IP du NLB changent à chaque nouveau cluster : c'est la CI qui les recopie. Si un de ces numéros change d'un côté sans changer de l'autre, Jitsi ne marche plus.

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

Le premier est rangé hors du chart, qui reste identique au chart officiel 3.10.0. L'Application le désigne par `../values/jitsi-meet-aws.yaml`, relatif au chart : ArgoCD accepte un fichier de values situé ailleurs tant qu'il est dans le même dépôt.

**Pourquoi l'annotation :** le chart range `PUBLIC_URL` dans une ConfigMap commune, et aucun pod ne redémarre quand elle change. Sans rien d'autre, web garderait l'URL de l'ancien NLB. L'annotation change avec l'URL : Kubernetes voit des pods modifiés et les redémarre.

Réglages de `helm/values/jitsi-meet-aws.yaml`, qui remplacent ceux du chart officiel :

| Réglage | Valeur | Pourquoi |
|---|---|---|
| `web.service` | `NodePort` 30080 | cible du NLB pour le site |
| `web.extraEnvs` | `ENABLE_P2P: "false"` | toute la vidéo passe par jvb |
| `web.extraEnvs` | `ENABLE_PREJOIN_PAGE: "false"` | pas d'écran de pré-connexion : sans ça, le stress test entre sans micro ni caméra ([tests](tests.md)) |
| `jicofo.strategy` | `type: Recreate` | jamais deux jicofo en même temps pendant un redéploiement ([pièges](pieges.md)) |
| `jvb.disableStun` | `true` | inutile, les IP publiques sont déjà connues |
| `jvb.UDPPort` / `jvb.nodePort` | 30300 | même port partout |
| `jvb.service` | `NodePort`, `Local` | voir plus haut |
| `jvb.service.extraPorts` | 8080 → NodePort 30808 | health check du NLB |
| `jicofo.xmpp.existingSecretName` | `jitsi-jicofo-bao` | mot de passe de jicofo venant d'OpenBao ([secrets](secrets.md)) |
| `jvb.xmpp.existingSecretName` | `jitsi-jvb-bao` | identifiant et mot de passe de jvb venant d'OpenBao ([secrets](secrets.md)) |
| `enableAuth` / `enableGuests` | `false` / `false` | pas de comptes utilisateurs : toute personne qui a l'URL peut créer une salle |
| `prosody.persistence` | `true`, classe `gp2` | servait aux comptes utilisateurs ; inutile depuis `enableAuth: false`, mais sans effet gênant |

**Premier déploiement avec l'ancienne URL :** sur un nouveau cluster, ArgoCD déploie d'abord le `values-infra.yaml` encore dans Git, celui du cluster précédent. Les pods redémarrent quelques minutes plus tard, quand la CI commite les nouvelles valeurs.

---

## Monter en charge : un seul jvb

Pour ce projet, un seul jvb est le bon choix :
- c'est la valeur par défaut du chart (`jvb.replicaCount: 1`) ;
- une conférence tourne de toute façon sur un seul jvb : un 2ᵉ jvb ajoute de la place pour d'autres conférences, pas pour la tienne ;
- si le pod ou son nœud tombe, Kubernetes relance jvb ailleurs et le health check redirige le NLB tout seul. La vidéo est coupée pendant le redémarrage, puis les participants se reconnectent.

Ce n'est pas de la haute disponibilité. Pour monter en charge, on ajoute des jvb, chacun joignable à sa propre adresse publique, et jicofo répartit les conférences entre eux. Le chart propose deux façons de faire :
- **`jvb.portRangeSize: N`** : N jvb derrière les mêmes IP, chacun sur son port (30300, 30301…). Avec cette infra, il faudrait aussi une écoute et un target group par port dans Terraform, et un health check par jvb : aujourd'hui, le port 30808 répond dès qu'*un* jvb est sur le nœud, et le NLB pourrait envoyer le flux du premier jvb au nœud du second.
- **`jvb.useHostPort` + `jvb.autoscaling`** : un jvb par nœud, ajouté ou retiré automatiquement selon la charge (HPA). Il faut alors des nœuds avec une IP publique, donc une autre infra réseau, et metrics-server, qui n'est pas installé.

Les autres composants ne se multiplient pas : prosody ne se met pas en cluster (c'est le point de défaillance unique, et son disque EBS l'attache à une seule AZ), et il n'y a qu'un jicofo par prosody.

**Nœuds** : des `c7i-flex.large` (2 vCPU, 4 Go, éligibles au free tier) suffisent pour une démo. Un `t3.small` n'accepte que 11 pods par nœud (une IP du VPC par pod), trop peu pour ArgoCD, ESO, OpenBao, Chaos Mesh et Jitsi ; un `large` en accepte 29. Le chart donne une limite de 4 Gi de mémoire à jvb et jicofo, alors qu'un nœud n'en a qu'environ 3,1 allouables : la limite ne protège rien, c'est le nœud entier qui manque de mémoire avant.
