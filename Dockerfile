FROM alpine:3.22

LABEL maintainer="BIRD2 Antifilter Container"
LABEL description="BIRD2 with antifilter lists for Mikrotik RouterOS Container"

RUN apk add --no-cache \
    bird2 \
    curl \
    bash \
    dcron \
    diffutils \
    && rm -rf /var/cache/apk/*

RUN mkdir -p /etc/bird/list /etc/bird/list_rsc /etc/bird/list_custom /etc/bird/black_list /var/run/bird /var/log \
    && ln -sf /usr/sbin/bird2 /usr/local/bin/bird2 \
    && ln -sf /usr/sbin/birdc /usr/local/bin/birdc

COPY bin/bird2.sh /bin/bird2.sh
COPY bin/entrypoint.sh /bin/entrypoint.sh

RUN chmod +x /bin/bird2.sh /bin/entrypoint.sh

EXPOSE 179

CMD ["/bin/entrypoint.sh"]
