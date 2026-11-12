#!/bin/bash
# Vérifie la répartition round-robin via la VIP
cd "$(dirname "$0")/.." && source scripts/common.sh
echo "== 12 requêtes vers http://$VIP =="
for i in $(seq 1 12); do
  c curl -s -D- -o /dev/null http://$VIP/ | grep -i '^x-backend' | tr -d '\r'
done | sort | uniq -c
