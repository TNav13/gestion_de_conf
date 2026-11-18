# Pièges rencontrés

## CI et AWS

| Erreur | Cause |
|---|---|
| `The web identity token provided could not be validated` | l'audience du fournisseur OIDC était `sts.amazonaws.com.`, avec un point final |
| `Not authorized to perform sts:AssumeRoleWithWebIdentity` | la condition `sub` du rôle attendait l'ancien format `repo:TNav13/gestion_de_conf:*` |
| job checkov en échec | la dernière release de `checkov-action` embarque Checkov 2.0 (2022) : Checkov 3 est installé avec `pip` |
| `cannot pull with rebase: You have unstaged changes` | `terraform init` ajoute les empreintes Linux dans `.terraform.lock.hcl` sur le runner : `git pull --rebase --autostash` |
| tout recréé au run suivant | sans sauvegarde, le state reste sur le runner et disparaît avec lui : d'où l'artifact |
| `CONFLICT (content): Merge conflict in helm/jitsi-meet/values-infra.yaml` | « Re-run jobs » sur un ancien run, qui rejoue l'ancien commit : utiliser Run workflow |
| `Context access might be invalid` dans l'IDE | une variable écrite dans `$GITHUB_ENV` est invisible pour l'extension GitHub Actions : passer par une sortie d'étape (`$GITHUB_OUTPUT`) |

**Débugger une connexion OIDC refusée :** le log GitHub dit seulement « Not authorized ». Le détail est dans CloudTrail (région `eu-north-1`, Event history, événement `AssumeRoleWithWebIdentity`) : `userIdentity.userName` montre le `sub` exact présenté par GitHub, à comparer avec la condition du rôle. CloudTrail met 5 à 15 minutes à afficher un événement.

Le `sub` est l'identité que GitHub présente à AWS. Pour les dépôts créés après le 15 juillet 2026, GitHub y met les **identifiants numériques** du compte (`@187294659`) et du dépôt (`@1425369785`) : ils ne changent jamais, même si on renomme le compte ou le dépôt, et personne ne peut recréer un dépôt du même nom pour prendre le rôle.

## Kubernetes et Jitsi

| Problème | Cause |
|---|---|
| aucune conférence ne démarre, jicofo `Running` mais 0 bridge, `conflict: Replaced by new connection` dans ses logs | pendant un redéploiement, l'ancien et le nouveau jicofo se sont connectés en même temps à prosody ; celui qui est éjecté ne se reconnecte jamais. Corrigé par `jicofo.strategy: Recreate`. Dépannage : `kubectl -n jitsi delete pod -l app.kubernetes.io/component=jicofo` |
| `Forbidden: updates to statefulset spec` en changeant `prosody.persistence` | Kubernetes interdit de changer les disques d'un StatefulSet existant. Supprimer le StatefulSet, qu'ArgoCD recrée : `kubectl -n jitsi delete sts jitsi-jitsi-meet-prosody` |
| la config d'OpenBao n'est pas prise en compte | OpenBao est en `updateStrategy: OnDelete` : supprimer le pod `openbao-0` |

## OpenBao et External Secrets

- En KV version 2, les données sont rangées sous `kv/data/...` : la policy vise `kv/data/jicofo`. La règle `kv/data/jicofo/*` ne couvre que ce qui est *sous* `jicofo/`, pas `jicofo` lui-même.
- `kubernetes_host` doit valoir `https://kubernetes.default.svc`, **sans point final**. Avec un point, le nom n'est pas complété en `.cluster.local`, OpenBao ne joint pas l'API Kubernetes et répond seulement `permission denied`.
- Le role doit donner la policy (`token_policies`) : sans elle, ESO se connecte mais n'a le droit de rien lire.
- Le ServiceAccount `eso-jitsi` doit être dans Git : créé à la main, il manque sur chaque nouveau cluster et ESO ne peut pas se connecter.
- OpenBao 2.7 avec `seal "awskms"` plante au démarrage (`unknown wrapper: awskms`) : le seal est devenu un plugin, d'où la 2.6.
- Après une erreur, ESO réessaie de moins en moins souvent. Pour le relancer tout de suite :
  `kubectl -n jitsi annotate externalsecret jicofo jvb force-sync=$(date +%s) --overwrite`

## Stress test

| Problème | Cause |
|---|---|
| les participants entrent sans micro ni caméra, le jvb ne reçoit rien | torture ajoute `config.prejoinConfig.enabled=false` à ses URL, et Jitsi traite ce paramètre comme « entrer sans média » (`disableInitialGUM`), sauf dans une iframe. L'écran de pré-connexion est donc désactivé côté serveur (`ENABLE_PREJOIN_PAGE`), et le Dockerfile retire ce paramètre de torture (`sed`) |
| à 10 participants : pages rechargées, `APP is not defined`, vidéo en 180p | c'est le runner (4 vCPU) qui sature, pas Jitsi : le jvb ne dépassait pas 0,17 de `stress_level`. D'où 5 participants |
| Chrome du grid très lent sur un Mac Apple Silicon | `selenium/standalone-chrome` n'existe qu'en amd64 : en local, il tourne en émulation. Les runners GitHub sont en amd64 |

## Chaos Mesh

| Problème | Cause |
|---|---|
| expérience `Not Injected`, `x509: certificate signed by unknown authority` | ArgoCD a mélangé plusieurs rendus des certificats du chart : explication et procédure dans [tests.md](tests.md) |
| `spec.source.helm.parameters[2].value … must be of type string` | `value: false` sans guillemets dans l'Application : mettre `"false"` |
| sync en échec, `metadata.annotations: Too long` | trois CRDs dépassent 256 Ko : `ServerSideApply=true` |
| `Cannot update chaos spec` en relançant une expérience | le webhook refuse de modifier une expérience existante : la supprimer avant de la réappliquer |
| un HTTPChaos sur `/http-bind` ne coupe rien | la signalisation BOSH passe par des `POST` : ne pas filtrer `method: GET` |
| un sélecteur avec deux fois `app.kubernetes.io/component` | YAML garde la dernière valeur, et `labelSelectors` est un ET : une seule valeur par clé, ou `expressionSelectors` avec `operator: In` |
