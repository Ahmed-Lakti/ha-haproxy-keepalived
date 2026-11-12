# Déploiement sur Rocky Linux avec Podman

Ce guide adapte le projet à **Rocky Linux 8/9 + Podman**. Deux options :

| Option | Usage | Commande |
|---|---|---|
| **A. Lab Podman** (conteneurs, 1 VM) | Démo, tests de failover, rapport | `sudo ./podman/deploy.sh up` |
| **B. Natif Rocky** (2 VM) | Architecture réelle de production | `./rocky/install.sh` (sur chaque LB) |

---

## Option A : lab Podman

### Points d'attention propres à Podman

- **Mode rootful obligatoire** (`sudo podman`). Keepalived doit ajouter l'IP virtuelle sur l'interface du conteneur
  (`NET_ADMIN`) et échanger du VRRP : cela ne fonctionne pas de façon fiable en rootless.
- **Réseau avec IP fixes** : `podman network create --subnet 172.28.0.0/24` puis `--ip` sur chaque conteneur
  (Podman 4+ avec Netavark, par défaut sur Rocky 9).
- **Images avec noms complets** (`docker.io/library/...`) : évite les erreurs de *short-name resolution*.
- **SELinux** reste en `Enforcing` : aucun `--privileged` ni `:Z` nécessaire ici (pas de volume monté, la config est copiée dans l'image).

### Installation et lancement

```bash
sudo dnf install -y podman curl
sudo systemctl enable --now podman-restart.service   # redémarre les conteneurs "--restart" au boot

cd ha-project
sudo ./podman/deploy.sh up          # construit les images, crée le réseau et les 7 conteneurs
sudo ./podman/deploy.sh status      # affiche l'état et le nœud qui porte la VIP
```

Vérifications :

```bash
curl -I http://172.28.0.100/                       # depuis la VM (le bridge est joignable depuis l'hôte)
sudo podman exec client curl -s http://172.28.0.100/
sudo podman logs -f lb1                            # logs HAProxy + Keepalived
curl http://localhost:8081/stats                   # stats lb1  (8082 pour lb2)
```

Si les stats ne sont pas joignables depuis l'extérieur de la VM :
```bash
sudo firewall-cmd --permanent --add-port=8081-8082/tcp && sudo firewall-cmd --reload
```

### Tests

Les scripts détectent Podman automatiquement (et utilisent `sudo podman` si vous n'êtes pas root).

```bash
./scripts/test_loadbalancing.sh     # attendu : 4 / 4 / 4 requêtes par serveur
./scripts/test_failover.sh          # panne web2, puis panne du LB actif, puis retour
```

Tests manuels :

```bash
sudo podman stop web2                          # le serveur passe DOWN (~6 s), le trafic continue
sudo podman stop lb1                           # lb2 reprend la VIP (~3 s)
sudo podman exec lb2 ip -4 addr show eth0      # on y voit 172.28.0.100
sudo podman exec lb1 pkill haproxy             # panne HAProxy seule : la VIP bascule
sudo podman start lb1                          # lb1 reprend la VIP
```

### Nettoyage
```bash
sudo ./podman/deploy.sh down
```

### Démarrage automatique (optionnel, Quadlet)
Pour piloter les conteneurs avec systemd, créer des fichiers `.container` dans `/etc/containers/systemd/`
(ex. `lb1.container` avec `Image=localhost/ha-lb`, `AddCapability=NET_ADMIN NET_BROADCAST NET_RAW`,
`Network=ha_net`, `IP=172.28.0.11`, les `Environment=` de `deploy.sh`), puis `sudo systemctl daemon-reload && sudo systemctl start lb1`.

> Le `docker-compose.yml` reste fourni pour Docker. Avec Podman, préférez `deploy.sh` : il est déterministe
> (IP fixes, capabilities) alors que le support de `podman-compose` varie selon les versions.

---

## Option B : déploiement natif sur 2 VM Rocky (recommandé en production)

HAProxy et Keepalived sont dans les dépôts AppStream de Rocky ; Keepalived s'intègre mieux au système hôte qu'en conteneur.

Prérequis : 2 VM load balancers (`lb1`, `lb2`), 3 serveurs web, une IP libre pour la VIP dans le même sous-réseau.

Sur **lb1** :
```bash
sudo ROLE=MASTER IFACE=ens18 SRC_IP=10.0.0.11 PEER_IP=10.0.0.12 VIP=10.0.0.100 \
     BACKENDS="10.0.0.21 10.0.0.22 10.0.0.23" AUTH_PASS='Secret123' ./rocky/install.sh
```
Sur **lb2** (même commande, avec `ROLE=BACKUP`, `SRC_IP=10.0.0.12`, `PEER_IP=10.0.0.11`).

Le script :
1. installe `haproxy`, `keepalived`, `curl`, `gettext` ;
2. génère `/etc/haproxy/haproxy.cfg` à partir de `lb/haproxy.cfg` avec vos backends, et le valide ;
3. génère `/etc/keepalived/keepalived.conf` (MASTER prio 110 / BACKUP prio 100) ;
4. configure **SELinux** : `haproxy_connect_any=1` (HAProxy vers les backends), `keepalived_connect_any=1` (script de santé) ;
5. configure **firewalld** : http, https, 8404/tcp, et le protocole **VRRP (112)** depuis le pair ;
6. active et démarre les services.

Vérifications :
```bash
sudo systemctl status haproxy keepalived
ip -4 addr show ens18 | grep 10.0.0.100      # sur le MASTER
curl -I http://10.0.0.100/
sudo journalctl -u keepalived -f             # transitions MASTER/BACKUP
sudo ausearch -m avc -ts recent              # refus SELinux éventuels
```

Test de panne : `sudo systemctl stop haproxy` sur `lb1` (la VIP doit passer sur `lb2` en quelques secondes), puis `sudo systemctl start haproxy`.

Sur les serveurs web Rocky (Nginx/Apache) : ouvrir le port 80 aux seules IP des LB
(`firewall-cmd --permanent --add-rich-rule='rule family=ipv4 source address=10.0.0.11 port port=80 protocol=tcp accept'`)
et exposer un endpoint `/health` renvoyant 200.

## Dépannage rapide

| Symptôme | Cause probable | Correction |
|---|---|---|
| Les deux LB se déclarent MASTER (split-brain) | VRRP bloqué entre les nœuds | Ouvrir le protocole 112 (firewalld) ; vérifier `unicast_peer` et `AUTH_PASS` identiques |
| `Permission denied` / backends 503 en natif | SELinux | `setsebool -P haproxy_connect_any 1` ; consulter `ausearch -m avc` |
| `podman run ... --ip` : erreur | Rootless ou réseau absent | Utiliser `sudo`, vérifier `podman network ls` |
| `short-name did not resolve` | Image sans registre | Utiliser `docker.io/library/<image>` |
| La VIP ne répond pas depuis un autre poste | ARP / hyperviseur (VMware/KVM) | Autoriser le mode promiscuité / l'usurpation d'adresse MAC sur le vSwitch |
