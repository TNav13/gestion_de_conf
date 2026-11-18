# Les secrets : OpenBao et External Secrets

## Les mots de passe internes

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

**Changer un mot de passe interne :** ESO met à jour le Secret dans l'heure (ou tout de suite avec `force-sync`), mais les pods ne lisent leurs variables qu'au démarrage. Il faut redémarrer prosody, jicofo et jvb.

## Le déverrouillage automatique (auto-unseal KMS)

Au démarrage, OpenBao est **scellé** : il ne peut rien lire tant qu'il n'a pas sa clé maîtresse. Ici, cette clé est chiffrée par une clé AWS KMS (`seal "awskms"` dans `argocd/apps/openbao.yaml`). Le pod obtient le droit d'utiliser KMS par son ServiceAccount, annoté avec le rôle IAM `openbao-unseal` (IRSA), sans aucune clé AWS écrite quelque part.

Résultat : à chaque redémarrage du pod, OpenBao se déverrouille seul (« unsealed with stored key »). L'init n'a lieu qu'une fois par cluster ; avec KMS, elle donne une **recovery key** à la place des clés de déverrouillage.

OpenBao est en **2.6** (chart 0.29.6) : à partir de la 2.7, le seal `awskms` n'est plus intégré et devient un plugin à installer à part. Le stockage est `file`, celui du chart 0.29 (`pebbledb` n'existe qu'en 2.7).

## La configuration d'OpenBao : `scripts/bootstrap-openbao.sh`

Lancé par la CI après chaque `terraform apply`. Chaque étape regarde d'abord ce qui existe déjà : on peut le relancer sans rien casser.

1. Attendre que le pod `openbao-0` soit **Running**, pas Ready : OpenBao ne devient Ready qu'une fois déverrouillé, donc attendre Ready bloquerait pour toujours.
2. Si OpenBao n'est pas initialisé : `bao operator init`. Le root token et la recovery key sont rangés, chiffrés, dans AWS SSM Parameter Store (`/gestion-conf/openbao/init`). Ils ne passent jamais dans les logs : le dépôt est public, ses logs de CI aussi.
3. Attendre le déverrouillage par KMS.
4. Créer le moteur `kv`, l'auth `kubernetes` et sa config, la policy `jicofo_jvb` et le role `jitsi`.
5. Tirer au hasard les mots de passe de jicofo et jvb, **une seule fois** : s'ils existent déjà, ils ne sont jamais régénérés (les pods ne les lisent qu'au démarrage).
6. Relancer ESO, qui après ses échecs du début (OpenBao pas encore prêt) pourrait attendre jusqu'à ~16 min avant de réessayer, puis attendre que les deux ExternalSecrets soient prêts.

Les pièges rencontrés avec OpenBao et ESO sont dans [pieges.md](pieges.md).

## Pas d'authentification des utilisateurs

Avec `enableAuth: false`, il n'y a pas de comptes : toute personne qui a l'URL peut créer une salle et la rejoindre. Pour en remettre une : `enableAuth: true` avec des comptes prosody, ou l'auth par **JWT**. Sa clé de signature (`JWT_APP_SECRET`) irait dans OpenBao par le même chemin ESO (`prosody.jwt.existingSecretName`), mais il faudrait un outil pour fabriquer les tokens des utilisateurs.
