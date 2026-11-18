# Client Malleus (jitsi-meet-torture) : pilote les navigateurs du grid vers Jitsi
# Version Java de la CI de torture
FROM maven:3.9.16-eclipse-temurin-11

# Commit épinglé de jitsi-meet-torture (16/04/2026)
ADD https://github.com/jitsi/jitsi-meet-torture.git#4c00915e97006ff2224bb509eb3582bf3a10ca85 /torture
WORKDIR /torture

# Avec ce paramètre d'URL, Jitsi fait entrer les participants sans micro ni caméra
# (la page de pré-connexion est désactivée côté serveur : ENABLE_PREJOIN_PAGE dans helm/values/jitsi-meet-aws.yaml)
RUN sed -i '/config.prejoinConfig.enabled=false/d' src/test/java/org/jitsi/meet/test/web/WebParticipant.java \
 && ! grep -q prejoinConfig src/test/java/org/jitsi/meet/test/web/WebParticipant.java

# Dépendances et compilation au build : un run ne retélécharge que le provider TestNG de surefire
RUN mvn -B -q test-compile

# Sans --instance-url, malleus.sh vise meet.jit.si : on préfère qu'il échoue.
# (Les arguments positionnels forcent quand même meet.jit.si : toujours utiliser --option=valeur)
ENV MALLEUS_INSTANCE_URL=https://instance-url-manquante.invalid

ENTRYPOINT ["sh", "scripts/malleus.sh"]
