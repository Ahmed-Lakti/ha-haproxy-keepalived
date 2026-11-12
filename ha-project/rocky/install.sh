#!/bin/bash
# Installation native HAProxy + Keepalived sur Rocky Linux 8/9 (SELinux enforcing, firewalld).
# À exécuter en root sur CHAQUE load balancer. Exemple :
#   lb1 : ROLE=MASTER IFACE=ens18 SRC_IP=10.0.0.11 PEER_IP=10.0.0.12 VIP=10.0.0.100 \
#         BACKENDS="10.0.0.21 10.0.0.22 10.0.0.23" AUTH_PASS=Secret123 ./rocky/install.sh
#   lb2 : ROLE=BACKUP IFACE=ens18 SRC_IP=10.0.0.12 PEER_IP=10.0.0.11 (reste identique)
set -euo pipefail
[ "$(id -u)" -eq 0 ] || { echo "Lancer en root"; exit 1; }
cd "$(dirname "$0")/.."

: "${ROLE:?MASTER ou BACKUP}" "${IFACE:?}" "${SRC_IP:?}" "${PEER_IP:?}" "${VIP:?}" "${BACKENDS:?}" "${AUTH_PASS:?}"
[ "$ROLE" = MASTER ] && PRIORITY=110 || PRIORITY=100

dnf install -y haproxy keepalived curl gettext

# --- HAProxy : on réutilise lb/haproxy.cfg avec les vrais backends
awk -v list="$BACKENDS" '
  /^    server web/ { next }
  { print }
  /default-server/ { n=split(list, a, " "); for(i=1;i<=n;i++) printf "    server web%d %s:80 check\n", i, a[i] }
' lb/haproxy.cfg | sed "s/%\[env(HOSTNAME)\]/$(hostname -s)/" > /etc/haproxy/haproxy.cfg
haproxy -c -f /etc/haproxy/haproxy.cfg

# --- Keepalived
install -o root -g root -m 755 lb/check_haproxy.sh /usr/local/bin/check_haproxy.sh
export STATE=$ROLE PRIORITY SRC_IP PEER_IP VIP AUTH_PASS IFACE
envsubst '${STATE} ${PRIORITY} ${SRC_IP} ${PEER_IP} ${VIP} ${AUTH_PASS} ${IFACE}' \
  < lb/keepalived.conf.tpl > /etc/keepalived/keepalived.conf

# --- SELinux : HAProxy vers les backends, script de santé Keepalived vers localhost
setsebool -P haproxy_connect_any 1
setsebool -P keepalived_connect_any 1 2>/dev/null || true
semanage port -a -t http_port_t -p tcp 8404 2>/dev/null || true   # port stats

# --- firewalld : HTTP/HTTPS, stats (réseau interne), VRRP (protocole 112) vers le pair
firewall-cmd --permanent --add-service=http --add-service=https
firewall-cmd --permanent --add-port=8404/tcp
firewall-cmd --permanent --add-rich-rule="rule family=ipv4 source address=$PEER_IP protocol value=vrrp accept"
firewall-cmd --reload

systemctl enable --now haproxy keepalived
echo "OK. VIP : $(ip -4 addr show $IFACE | grep -c $VIP) (1 = ce nœud la porte)"
