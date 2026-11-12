#!/bin/sh
# Script de santé appelé par Keepalived : exit 0 = OK, !=0 = priorité réduite
curl -fsS --max-time 1 http://127.0.0.1:8404/healthz >/dev/null 2>&1 || exit 1
