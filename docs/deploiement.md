# Déploiement : CI, state Terraform et ArgoCD

## Le workflow deploy

`.github/workflows/deploy.yml` se lance à chaque push sur `main` qui touche `terraform_infra/`, `scripts/` ou le workflow lui-même, ou à la main (Actions → deploy → Run workflow).

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

Le commit de la CI ne relance pas le workflow : un push fait avec le jeton automatique `GITHUB_TOKEN` ne déclenche aucun workflow. Les changements dans `helm/` ou `argocd/` ne relancent pas la CI non plus : ArgoCD relit GitHub toutes les 2 minutes environ et les applique (bouton **Refresh** sur l'app `root` pour ne pas attendre).

**Redéployer : Run workflow, jamais « Re-run jobs ».** Un re-run rejoue le run d'origine sur **son** commit, pas sur le dernier de `main` : Terraform appliquerait l'ancien code, et le commit de `values-infra.yaml` entrerait en conflit avec celui déjà sur `main`. Ce conflit est un garde-fou : sans lui, le bot pousserait des valeurs calculées par l'ancien code.

**Checkov** tourne en mode rapport (`--soft-fail`) : il affiche ses alertes sans bloquer le déploiement. Il en reste 7, acceptées pour ce projet : le port 80 ouvert, pas de logs d'accès du NLB, pas de policy KMS écrite à la main, et des modules épinglés par numéro de version plutôt que par commit. Pour le rendre bloquant, retirer `--soft-fail` dans `deploy.yml`.

## Le state Terraform : un artifact chiffré

GitHub ne sait pas garder un state Terraform. Le state est donc chiffré (AES-256, avec le secret `TF_STATE_PASSPHRASE`) et envoyé en **artifact** `tfstate` à la fin de chaque run ; le run suivant récupère le plus récent. Le chiffrement est obligatoire : les artifacts d'un dépôt public sont téléchargeables par n'importe quel compte GitHub, et le state contient en clair la clé privée du certificat.

- Le state est sauvegardé **même si `terraform apply` échoue** : ce qui a déjà été créé doit rester connu, sinon le run suivant recréerait tout en double.
- Il n'est **jamais** sauvegardé si sa récupération a échoué (mauvaise phrase de chiffrement, API GitHub injoignable) : un state vide écraserait le bon.
- `deploy` et `destroy` ne tournent jamais en même temps (même groupe `concurrency`), donc deux runs n'écrivent jamais le state en même temps.
- Les artifacts sont gardés 7 jours. Pas d'historique ni de verrou en dehors du groupe `concurrency` : suffisant pour un projet détruit après la démo ; pour durer, on passerait à un backend S3.

C'est aussi pourquoi on ne lance jamais `terraform apply` depuis un poste : le state n'y est pas, et un apply en root créerait une deuxième access entry pour root, ce qu'EKS refuse.

## Le workflow destroy

Actions → **destroy** → Run workflow, puis taper `destroy` pour confirmer. Le workflow récupère le state, lance `terraform destroy` et sauvegarde le state vidé (le prochain deploy repart de zéro).

Il supprime ensuite les volumes EBS laissés par les disques de prosody et d'OpenBao : créés par Kubernetes et pas par Terraform, ils survivraient au cluster et resteraient facturés. Il attend d'abord que chaque disque soit détaché, au cas où un nœud finirait de s'arrêter. Le nom du cluster, noté avant le destroy, passe d'une étape à l'autre par une sortie d'étape (`$GITHUB_OUTPUT`).

Les clés KMS ne disparaissent pas tout de suite : AWS impose une attente de 7 jours minimum. Le paramètre SSM `/gestion-conf/openbao/init` reste aussi : le deploy suivant l'écrase.

## ArgoCD : l'app of apps

Une **Application** ArgoCD dit : « prends telle source dans Git, et applique-la dans tel namespace ». Terraform ne crée qu'une seule Application, **root**, qui lit le dossier `argocd/apps/`. Ce dossier ne contient que des Applications, qu'ArgoCD crée à leur tour :

```
Terraform ──► Application root  (lit argocd/apps/ sur GitHub)
                 ├─► Application eso        → chart external-secrets 2.15.0
                 ├─► Application secrets    → helm/eso/ (ServiceAccount, SecretStore, ExternalSecrets)
                 ├─► Application openbao    → chart openbao 0.29.6
                 ├─► Application chaos-mesh → chart chaos-mesh 2.8.8
                 └─► Application jitsi      → helm/jitsi-meet/ + helm/values/jitsi-meet-aws.yaml + values-infra.yaml
```

Ajouter une app, c'est poser un fichier dans `argocd/apps/` ; le supprimer retire l'app.

L'app `secrets` a besoin des types `SecretStore` et `ExternalSecret`, qui n'existent qu'une fois ESO installé. Elle réessaie donc sans limite (`retry.limit: -1`) et saute la vérification préalable des types (`SkipDryRunOnMissingResource=true`) : sinon, un sync raté n'est jamais retenté sur le même commit.

ArgoCD lit ce dépôt sur GitHub : il doit être public, ou ses identifiants doivent être ajoutés dans ArgoCD.
