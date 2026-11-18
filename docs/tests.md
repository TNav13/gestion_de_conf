# Tests : stress test et Chaos Mesh

## Le stress test : Malleus

Malleus est l'outil de test de charge de [jitsi-meet-torture](https://github.com/jitsi/jitsi-meet-torture), le projet de tests de Jitsi. Il pilote de vrais navigateurs Chrome (Selenium) qui rejoignent une salle et envoient une vidéo et un son de test.

### Les deux images

| Image | Dossier | Contenu |
|---|---|---|
| `grid` | `malleus/grid/` | `selenium/standalone-chrome` (tag épinglé) + la vidéo `FourPeople_1280x720_30.y4m` et le son `fakeAudioStream.wav` dans `/usr/share/jitsi-meet-torture/resources` |
| `malleus` | `malleus/malleus/` | Maven + Java 11 (la version de la CI de torture) et jitsi-meet-torture au commit `4c00915`, compilé au build |

Les fichiers de test sont dans l'image **grid**, pas dans malleus : c'est Chrome, sur le grid, qui les lit. `malleus.sh` passe `-Dremote.resource.path=/usr/share/jitsi-meet-torture`, d'où ce chemin.

### Le workflow stress

`.github/workflows/stress.yml` se lance chaque jour à 12h, heure de Paris (`timezone: Europe/Paris`), ou à la main. Il n'a besoin d'aucun accès à AWS.

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
- 5 participants et pas 10 : à 10, c'est le runner (4 vCPU) qui sature, pas Jitsi ([pièges](pieges.md)).

### Ce que mesure un run

Un run vert veut dire que les 5 participants sont restés dans la conférence pendant 5 minutes. **Il ne vérifie pas que la vidéo passe.** Pour ça, il faut lire les statistiques du jvb pendant le run :

```bash
kubectl -n jitsi exec deploy/jitsi-jitsi-meet-jvb-0 -- curl -s localhost:8080/colibri/stats \
  | jq '{conferences, participants, endpoints_sending_video, bit_rate_download, bit_rate_upload, stress_level}'
```

Run du 18 novembre 2026 : 5 participants sur 5 envoient de la vidéo, le jvb reçoit 1,9 Mbit/s et en redistribue 4,5, avec un `stress_level` de 0,10 au maximum. Jitsi est loin de sa limite.

---

## Chaos Mesh : injecter des pannes

Chaos Mesh (chart 2.8.8) est installé par ArgoCD (`argocd/apps/chaos-mesh.yaml`) dans le namespace `chaos-mesh` : un contrôleur, un `chaos-daemon` par nœud (c'est lui qui agit dans les conteneurs) et un dashboard.

| Réglage | Pourquoi |
|---|---|
| `chaosDaemon.runtime: containerd`, `chaosDaemon.socketPath: /run/containerd/containerd.sock` | les nœuds EKS tournent sous containerd ; le chart suppose Docker par défaut |
| `dashboard.securityMode: "false"` | pas de jeton pour le dashboard (entre guillemets : la valeur d'un paramètre Helm doit être une chaîne) |
| `ServerSideApply=true` | trois CRDs (`workflownodes`, `schedules`, `workflows`) dépassent les 256 Ko qu'accepte l'apply classique d'ArgoCD |
| `ignoreDifferences` + `RespectIgnoreDifferences=true` | les certificats générés par le chart, ci-dessous |

### Les certificats générés au rendu

Le chart fabrique ses certificats (webhooks, mTLS entre le contrôleur et les daemons) et une annotation `rollme` **au hasard, à chaque rendu** (`genCA`, `randAlphaNum`). C'est prévu pour `helm install`, qui ne rend qu'une fois. ArgoCD, lui, refait le rendu (à l'expiration de son cache de 24 h, à un hard refresh, à une modification de l'app) : à chaque fois, de nouveaux certificats et un redémarrage du contrôleur et des daemons.

À l'installation, ArgoCD a synchronisé 4 fois de suite et mélangé plusieurs rendus : le contrôleur et les daemons n'avaient plus la même CA (`x509: certificate signed by unknown authority`). Aucune expérience qui passe par le daemon (CPU, réseau, HTTP, disque) n'était injectée ; seul `pod-kill`, qui passe par l'API Kubernetes, marchait.

`ignoreDifferences` (l'annotation `rollme`, les 4 Secrets de certificats, les `caBundle` des webhooks) et `RespectIgnoreDifferences=true` font garder à ArgoCD ce qui est déjà dans le cluster.

**Si ça recommence** (le workflow chaos échoue, ou `kubectl -n jitsi get stresschaos <nom> -o yaml` montre `Not Injected` avec une erreur x509), remettre les certificats en cohérence :

```bash
kubectl -n chaos-mesh delete secret chaos-mesh-webhook-certs chaos-mesh-daemon-certs \
  chaos-mesh-daemon-client-certs chaos-mesh-chaosd-client-certs
kubectl delete mutatingwebhookconfiguration chaos-mesh-mutation
kubectl delete validatingwebhookconfiguration chaos-mesh-validation chaos-mesh-validation-auth
# ArgoCD les recrée à partir d'un seul rendu ; les pods rechargent ensuite les certificats :
kubectl -n chaos-mesh delete pod -l app.kubernetes.io/component=controller-manager
kubectl -n chaos-mesh delete pod -l app.kubernetes.io/component=chaos-daemon
```

Supprimer les pods plutôt que faire un `rollout restart` : l'annotation que ce dernier ajoute au Deployment serait vue comme une différence et annulée par ArgoCD. Sur chaque nouveau cluster, vérifier avec une expérience courte. La solution définitive serait cert-manager (`webhook.certManager.enabled`), qui produit les certificats une seule fois.

### Les expériences : `chaos-mesh/`

Ce dossier est en dehors de `argocd/apps/` : ArgoCD n'y touche jamais, et une expérience ne tourne que quand on la lance.

| Fichier | Ce qu'il fait | Effet |
|---|---|---|
| `pod-chaos.yaml` | `pod-failure` du jvb pendant 30 s : le conteneur ne répond plus, sans être supprimé | attendu : vidéo coupée 30 s, réunions conservées |
| `jvb-cpu-stress.yaml` | 2 workers à 100 % dans le pod jvb pendant 2 min | mesuré sur 20 s : le nœud du jvb à 1 886 millicores sur 2 000 |
| `http-chaos-abort.yaml` | coupe les requêtes `/http-bind` du pod web (port 8000) pendant 20 s | attendu : le site s'affiche, mais personne ne peut entrer en réunion. Pas encore testé |

### Le workflow chaos

`.github/workflows/chaos.yml` se lance à la main (Actions → chaos → Run workflow), en choisissant l'expérience (le nom du fichier sans `.yaml`). Il est séparé du stress test : on lance d'abord **stress**, puis **chaos** une fois les participants entrés (environ 3 minutes après le début du stress, build compris). Le job :

1. se connecte au cluster avec le rôle `deploy_eks` (OIDC, comme deploy) ;
2. supprime l'expérience si elle existe déjà (le webhook de Chaos Mesh refuse de la modifier), puis l'applique ;
3. échoue avec la raison si elle n'est pas injectée dans la minute (par exemple les certificats, plus haut) ;
4. affiche les stats du jvb toutes les 10 s (participants, flux vidéo, débits, `stress_level`) jusqu'à la fin de l'expérience, puis 20 s après ;
5. supprime l'expérience, même si le suivi a échoué.

Le résultat se lit à deux endroits : le run **stress** est vert si les 5 participants ont tenu malgré la panne, et les stats du run **chaos** montrent ce que la panne a coupé, et combien de temps.

À la main, l'équivalent est :

```bash
kubectl apply -f chaos-mesh/jvb-cpu-stress.yaml
kubectl -n jitsi get stresschaos                     # injectée ? terminée ?
kubectl delete -f chaos-mesh/jvb-cpu-stress.yaml     # obligatoire avant de la relancer
```

### Ce qu'on a observé

Le `pod-kill` du jvb, fait depuis le dashboard, a montré la reprise : le nouveau pod jvb est enregistré auprès de jicofo 3 s après, et jicofo y réinvite les participants. Personne n'est éjecté, car la réunion vit dans prosody. Seul dans une salle, on ne remarque rien : jicofo n'utilise un jvb qu'à partir de 2 participants.

| Pod visé | Ce qui tombe | Ce qui continue |
|---|---|---|
| web | le site, les nouvelles entrées, puis la signalisation (`/http-bind` passe par web) | le média des réunions en cours |
| jvb | le média, quelques secondes | les salles, la signalisation |
| prosody | tout : c'est le point de défaillance unique | rien |
