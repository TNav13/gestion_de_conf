FROM selenium/standalone-chrome:157.0-20261101

USER root

RUN mkdir -p /usr/share/jitsi-meet-torture/resources

ADD --chmod=644 https://github.com/jitsi/jitsi-meet-torture/releases/download/example-video-source/FourPeople_1280x720_30.y4m /usr/share/jitsi-meet-torture/resources/FourPeople_1280x720_30.y4m
ADD --chmod=644 https://raw.githubusercontent.com/jitsi/jitsi-meet-torture/4c00915e97006ff2224bb509eb3582bf3a10ca85/resources/fakeAudioStream.wav /usr/share/jitsi-meet-torture/resources/fakeAudioStream.wav

USER 1200