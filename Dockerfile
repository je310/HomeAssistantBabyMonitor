ARG BUILD_FROM
FROM $BUILD_FROM

RUN apk add --no-cache ffmpeg bash wget && \
    wget -qO- https://github.com/bluenviron/mediamtx/releases/download/v1.5.1/mediamtx_v1.5.1_linux_amd64.tar.gz | tar xz -C /usr/local/bin/ && \
    chmod +x /usr/local/bin/mediamtx

COPY run.sh /run.sh
COPY mediamtx.yml /mediamtx.yml
RUN chmod +x /run.sh

CMD ["/run.sh"]