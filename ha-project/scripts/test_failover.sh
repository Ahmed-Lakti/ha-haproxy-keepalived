#!/bin/bash
# Scénarios de panne : (1) un serveur web, (2) le load balancer actif
cd "$(dirname "$0")/.." && source scripts/common.sh

hits()  { for i in $(seq 1 9); do c curl -s -m 2 -D- -o /dev/null http://$VIP/ | grep -i '^x-backend' | tr -d '\r'; done | sort | uniq -c; }
owner() { for n in lb1 lb2; do E exec $n ip -4 addr show eth0 2>/dev/null | grep -q "$VIP" && echo "$n"; done; }

echo "### État initial : VIP portée par : $(owner)"; hits

echo; echo "### Scénario 1 : arrêt de web2"
E stop web2 >/dev/null; sleep 8; hits
E start web2 >/dev/null; sleep 8; echo "-- web2 redémarré :"; hits

echo; echo "### Scénario 2 : arrêt du load balancer actif ($(owner))"
ACTIVE=$(owner)
E stop "$ACTIVE" >/dev/null &
START=$(date +%s); FAIL=0
until c curl -s -m 1 -o /dev/null -w '%{http_code}' http://$VIP/ | grep -q 200; do FAIL=$((FAIL+1)); done
echo "Service rétabli après ~$(( $(date +%s) - START )) s (requêtes échouées : $FAIL)"
wait
echo "VIP portée maintenant par : $(owner)"; hits

echo; echo "### Retour à la normale"
E start "$ACTIVE" >/dev/null; sleep 8; echo "VIP portée par : $(owner)"
