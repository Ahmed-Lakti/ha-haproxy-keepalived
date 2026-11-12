FROM docker.io/library/alpine:3.20
RUN apk add --no-cache haproxy keepalived curl bash gettext iproute2
COPY haproxy.cfg /usr/local/etc/haproxy/haproxy.cfg
COPY keepalived.conf.tpl /etc/keepalived/keepalived.conf.tpl
COPY check_haproxy.sh /usr/local/bin/check_haproxy.sh
COPY entrypoint.sh /entrypoint.sh
RUN chmod 755 /usr/local/bin/check_haproxy.sh /entrypoint.sh
ENTRYPOINT ["/entrypoint.sh"]
