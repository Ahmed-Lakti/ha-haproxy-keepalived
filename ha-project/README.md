# Architecture de haute disponibilité avec HAProxy + Keepalived

Projet complet : répartition de charge **HAProxy**, redondance du load balancer par **Keepalived (VRRP)** et
3 serveurs web **Nginx**. Le tout est reproductible en une commande avec Docker Compose.

> **Environnement Rocky Linux + Podman** : voir [ROCKY_PODMAN.md](ROCKY_PODMAN.md) (lab Podman rootful et installation native).
> Les commandes `docker compose` ci-dessous valent pour Docker ; avec Podman, utilisez `sudo ./podman/deploy.sh up`.

---

## 1. Objectifs

| Objectif | Solution |
|---|---|
| Pas de point de défaillance unique (SPOF) sur les serveurs web | 3 backends + health checks HAProxy |
| Pas de SPOF sur le load balancer | 2 HAProxy en actif/passif + IP virtuelle (VIP) Keepalived |
| Basculement automatique et rapide | VRRP (annonces 1 s) + script de santé HAProxy |
| Supervision | Page de statistiques HAProxy, logs HTTP |
| Protection de base | Limitation de débit par IP, TLS prêt à activer |

## 2. Choix de la solution open source

| Critère | **HAProxy** | Nginx | Traefik | LVS/IPVS |
|---|---|---|---|---|
| Couche | L4 + L7 | L7 (L4 limité) | L7 | L4 |
| Health checks actifs (version libre) | Oui, très riches | Non (passifs seulement) | Oui | Oui |
| Performances | Excellentes | Très bonnes | Bonnes | Excellentes |
| Stats / observabilité natives | Oui | Limitées | Dashboard + metrics | Faibles |
| Configuration | Fichier déclaratif | Fichier | Dynamique (labels, API) | CLI |

**Choix : HAProxy.** Référence du domaine, health checks actifs gratuits, ACL, stick-tables, statistiques intégrées.
HAProxy ne gère pas lui-même sa redondance : on lui associe **Keepalived**, qui déplace une IP virtuelle d'un nœud à l'autre.

## 3. Architecture

```
                         Clients
                            |
                  VIP 172.28.0.100  (Keepalived / VRRP)
                            |
             +--------------+--------------+
             |                             |
   lb1 (MASTER, prio 110)        lb2 (BACKUP, prio 100)
   HAProxy + Keepalived  <--VRRP-->  HAProxy + Keepalived
   172.28.0.11                    172.28.0.12
             \                             /
              +-------------+--------------+
                            | round-robin + health check /health
              +-------------+-------------+
              |             |             |
            web1          web2          web3
        172.28.0.21   172.28.0.22   172.28.0.23
```

**Fonctionnement du basculement**

1. `lb1` détient la VIP (priorité la plus haute) et envoie des annonces VRRP chaque seconde à `lb2`.
2. Si `lb1` tombe (machine, conteneur) : plus d'annonces, `lb2` prend la VIP après ~3 s (3 × `advert_int`).
3. Si seul HAProxy plante sur `lb1` : le script `check_haproxy.sh` échoue 2 fois, la priorité passe de 110 à 90
   (`weight -20`), donc inférieure à celle de `lb2` (100), et la VIP bascule.
4. Quand `lb1` revient, il reprend la VIP (préemption).

## 4. Structure du projet

```
ha-project/
├── ROCKY_PODMAN.md             # guide Rocky Linux + Podman (lab et natif)
├── podman/deploy.sh            # déploiement du lab avec Podman (rootful)
├── rocky/install.sh            # installation native HAProxy+Keepalived sur Rocky
├── docker-compose.yml          # variante Docker : 2 LB, 3 web, client de test
├── lb/
│   ├── Dockerfile              # Alpine + HAProxy + Keepalived
│   ├── haproxy.cfg             # configuration HAProxy
│   ├── keepalived.conf.tpl     # modèle Keepalived (variables d'environnement)
│   ├── check_haproxy.sh        # script de santé pour Keepalived
│   └── entrypoint.sh           # lance HAProxy et Keepalived
├── web/                        # Nginx : /health + page indiquant le serveur
└── scripts/
    ├── test_loadbalancing.sh   # test de répartition
    └── test_failover.sh        # tests de panne (web puis load balancer)
```

## 5. Démarrage rapide (lab Docker)

Prérequis : Docker Engine + plugin Compose (Linux, macOS ou Windows).

```bash
cd ha-project
docker compose up -d --build
docker compose ps
```

Vérifier quel nœud détient la VIP :

```bash
docker exec lb1 ip -4 addr show eth0 | grep 172.28.0.100
```

Interroger le service (depuis le conteneur client) :

```bash
docker compose exec client curl -s -D- http://172.28.0.100/
```

Statistiques HAProxy : http://localhost:8081/stats (lb1) et http://localhost:8082/stats (lb2).

> Sous Linux, la VIP `172.28.0.100` est aussi joignable directement depuis l'hôte. Sous macOS/Windows, utilisez le conteneur `client`.

## 6. Tests

### 6.1 Répartition de charge
```bash
./scripts/test_loadbalancing.sh
```
Résultat attendu : 12 requêtes réparties à parts égales (4 / 4 / 4) entre `web1`, `web2`, `web3`.

### 6.2 Pannes
```bash
./scripts/test_failover.sh
```

| Scénario | Action | Résultat attendu |
|---|---|---|
| Panne d'un serveur web | `docker stop web2` | Marqué DOWN après 3 checks (~6 s), trafic réparti sur web1/web3, aucune erreur persistante |
| Retour du serveur | `docker start web2` | Réintégré après 2 checks OK, montée en charge progressive (`slowstart 10s`) |
| Panne du LB actif | `docker stop lb1` | VIP reprise par `lb2` en ~3 s, service continu |
| Panne HAProxy seul | `docker exec lb1 pkill haproxy` | Keepalived baisse la priorité, VIP bascule sur `lb2` (le conteneur redémarre aussi) |
| Retour du LB initial | `docker start lb1` | `lb1` reprend la VIP |

### 6.3 Test de charge (optionnel)
```bash
docker run --rm --network ha-lab_ha_net williamyeh/hey -z 20s -c 50 http://172.28.0.100/
```
Attention : la limite anti-abus (100 requêtes / 10 s / IP) renverra des 429. Augmentez-la ou retirez la règle pour ce test.

## 7. Déploiement en production (serveurs ou VM)

Les fichiers de configuration sont directement réutilisables sur deux VM Debian/Ubuntu (`lb1`, `lb2`) :

```bash
sudo apt update && sudo apt install -y haproxy keepalived curl

# Sur les deux nœuds
sudo cp lb/haproxy.cfg /etc/haproxy/haproxy.cfg      # adapter les IP des backends
sudo cp lb/check_haproxy.sh /usr/local/bin/ && sudo chmod 755 /usr/local/bin/check_haproxy.sh
sudo sysctl -w net.ipv4.ip_nonlocal_bind=1            # + persister dans /etc/sysctl.d/
sudo haproxy -c -f /etc/haproxy/haproxy.cfg

# Générer /etc/keepalived/keepalived.conf depuis le modèle
#   lb1 : STATE=MASTER PRIORITY=110 | lb2 : STATE=BACKUP PRIORITY=100
#   interface = nom réel de la carte (ex. ens18), VIP = IP libre du LAN
STATE=MASTER PRIORITY=110 SRC_IP=10.0.0.11 PEER_IP=10.0.0.12 VIP=10.0.0.100 AUTH_PASS=Secret123 \
  envsubst < lb/keepalived.conf.tpl | sudo tee /etc/keepalived/keepalived.conf
sudo sed -i 's/interface eth0/interface ens18/; s#/24 dev eth0#/24 dev ens18#' /etc/keepalived/keepalived.conf

sudo systemctl enable --now haproxy keepalived
```

Pare-feu : autoriser le protocole VRRP (IP 112) entre les deux LB, ainsi que 80/443 en entrée.

## 8. Durcissement et bonnes pratiques

- **TLS** : décommenter le `bind *:443` dans `haproxy.cfg`, fournir un `.pem` (certificat + clé), activer la redirection HTTP→HTTPS.
- **Secrets** : changer `VRRP_PASS` (`export VRRP_PASS=...`), activer `stats auth`, restreindre `:8404` au réseau d'administration.
- **Persistance de session** : si l'application est stateful, ajouter `cookie SRV insert indirect nocache` et `cookie web1` sur chaque `server`, ou `balance source`.
- **Algorithme** : `leastconn` si les requêtes ont des durées très variables.
- **Réseau** : `X-Forwarded-For` est déjà transmis (`option forwardfor`) pour conserver l'IP client.
- **Supervision** : exporter les métriques avec le endpoint Prometheus intégré de HAProxy (`http-request use-service prometheus-exporter if { path /metrics }`), alerter sur les serveurs DOWN et les changements d'état VRRP.
- **Sauvegarde** : versionner les fichiers de configuration (Git), déployer via Ansible.

## 9. Limites et évolutions

- Actif/passif : un seul LB traite le trafic. Pour de l'actif/actif : deux VIP croisées, ou DNS round-robin, ou ECMP/BGP.
- Le lab utilise un seul hôte Docker : il valide la logique, pas la résilience matérielle. En production, placer les LB sur des hôtes distincts.
- Évolutions possibles : certificats Let's Encrypt automatisés, WAF (ModSecurity), Prometheus + Grafana, déploiement Ansible/Terraform.

## 10. Nettoyage

```bash
docker compose down -v
```
