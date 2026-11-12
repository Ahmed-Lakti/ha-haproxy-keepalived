#!/bin/bash
# Déploie le lab HA avec Podman (rootful). Usage : sudo ./podman/deploy.sh {up|down|status}
set -euo pipefail
[ "$(id -u)" -eq 0 ] || { echo "Lancer en root : sudo $0 $*"; exit 1; }
cd "$(dirname "$0")/.."

NET=ha_net; SUBNET=172.28.0.0/24; VIP=172.28.0.100
PASS=${VRRP_PASS:-ChangeMe1}
LBOPTS=(--restart unless-stopped --cap-add NET_ADMIN,NET_BROADCAST,NET_RAW --network "$NET")

up() {
  podman network exists $NET || podman network create --subnet $SUBNET $NET
  podman build -t ha-lb  ./lb
  podman build -t ha-web ./web

  for i in 1 2 3; do
    podman run -d --name web$i --hostname web$i --network $NET --ip 172.28.0.2$i \
      --restart unless-stopped localhost/ha-web
  done

  podman run -d --name lb1 --hostname lb1 "${LBOPTS[@]}" --ip 172.28.0.11 -p 8081:8404 \
    -e STATE=MASTER -e PRIORITY=110 -e SRC_IP=172.28.0.11 -e PEER_IP=172.28.0.12 \
    -e VIP=$VIP -e AUTH_PASS="$PASS" localhost/ha-lb
  podman run -d --name lb2 --hostname lb2 "${LBOPTS[@]}" --ip 172.28.0.12 -p 8082:8404 \
    -e STATE=BACKUP -e PRIORITY=100 -e SRC_IP=172.28.0.12 -e PEER_IP=172.28.0.11 \
    -e VIP=$VIP -e AUTH_PASS="$PASS" localhost/ha-lb

  # Conteneur client de test (réutilise l'image lb qui contient curl)
  podman run -d --name client --network $NET --ip 172.28.0.50 --entrypoint sleep localhost/ha-lb infinity
  status
}

down() {
  podman rm -f lb1 lb2 web1 web2 web3 client 2>/dev/null || true
  podman network rm $NET 2>/dev/null || true
}

status() {
  podman ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
  for n in lb1 lb2; do
    podman exec $n ip -4 addr show eth0 2>/dev/null | grep -q "$VIP" && echo "VIP $VIP portée par : $n"
  done
}

case "${1:-}" in up) up;; down) down;; status) status;; *) echo "Usage: $0 {up|down|status}"; exit 1;; esac
