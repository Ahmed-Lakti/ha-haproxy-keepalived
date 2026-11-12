#!/bin/bash
# Lance HAProxy + Keepalived dans le même conteneur. Si l'un meurt, le conteneur
# s'arrête et Docker le redémarre (restart: unless-stopped).
set -euo pipefail
export IFACE="${IFACE:-eth0}"
envsubst '${STATE} ${PRIORITY} ${SRC_IP} ${PEER_IP} ${VIP} ${AUTH_PASS} ${IFACE}' \
  < /etc/keepalived/keepalived.conf.tpl > /etc/keepalived/keepalived.conf

haproxy -c -f /usr/local/etc/haproxy/haproxy.cfg      # validation de la config

haproxy -f /usr/local/etc/haproxy/haproxy.cfg -db &
keepalived --dont-fork --log-console --log-detail &

trap 'kill $(jobs -p) 2>/dev/null' TERM INT
wait -n
exit $?
