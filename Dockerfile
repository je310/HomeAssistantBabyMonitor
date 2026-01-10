ARG BUILD_FROM
FROM $BUILD_FROM

# ffmpeg in HA base images typically includes SRT support already
RUN apk add --no-cache ffmpeg bash

COPY run.sh /run.sh
RUN chmod +x /run.sh

CMD ["/run.sh"]
