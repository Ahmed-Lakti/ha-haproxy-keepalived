# Détecte le moteur : Podman (rootful via sudo) ou Docker
VIP=172.28.0.100
ENGINE=${ENGINE:-$(command -v podman >/dev/null 2>&1 && echo podman || echo docker)}
E() {
  if [ "$ENGINE" = podman ] && [ "$(id -u)" -ne 0 ]; then sudo podman "$@"; else "$ENGINE" "$@"; fi
}
c() { E exec client "$@"; }
