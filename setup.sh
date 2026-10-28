#!/usr/bin/env bash
# setup.sh — provision a Debian host for the local-ai Ollama stack.
#
#   1. Install Docker Engine from Docker's apt repository
#      (https://docs.docker.com/engine/install/debian/)
#   2. Daily automatic apt upgrades via cron
#   3. Daily automatic container updates (compose pull + up) via cron
#   4. UFW: default deny incoming + outgoing; allow SSH and the Ollama API in,
#      and the minimum egress needed for apt, Docker pulls, DNS and NTP
#   5. Deploy docker-compose.yml to $INSTALL_DIR and start it
#
# Usage:  sudo ./setup.sh
# Options (environment variables):
#   SSH_PORT=22              SSH port to allow inbound
#   OLLAMA_PORT=11434        Ollama API port to allow inbound
#   ALLOW_FROM=any           Source allowed to reach SSH/Ollama (e.g. 10.90.1.0/24)
#   INSTALL_DIR=/opt/local-ai
#   APT_CRON="17 4 * * *"    Schedule for apt upgrades
#   DOCKER_CRON="47 4 * * *" Schedule for container updates
#   SKIP_COMPOSE_UP=0        Set to 1 to skip starting the stack

set -euo pipefail

SSH_PORT="${SSH_PORT:-22}"
OLLAMA_PORT="${OLLAMA_PORT:-11434}"
ALLOW_FROM="${ALLOW_FROM:-any}"
INSTALL_DIR="${INSTALL_DIR:-/opt/local-ai}"
APT_CRON="${APT_CRON:-17 4 * * *}"
DOCKER_CRON="${DOCKER_CRON:-47 4 * * *}"
SKIP_COMPOSE_UP="${SKIP_COMPOSE_UP:-0}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export DEBIAN_FRONTEND=noninteractive

log()  { printf '\033[1;34m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

# --- Preflight ---------------------------------------------------------------
[[ $EUID -eq 0 ]] || die "Run as root (sudo ./setup.sh)."
[[ -r /etc/os-release ]] || die "/etc/os-release not found."
# shellcheck source=/dev/null
. /etc/os-release
[[ "${ID:-}" == "debian" ]] || die "Debian required (found: ${ID:-unknown})."
case "${VERSION_CODENAME:-}" in
  bookworm|trixie) ;;
  *) warn "Docker supports Debian 12 (bookworm) and 13 (trixie); found '${VERSION_CODENAME:-?}'. Continuing." ;;
esac
[[ -f "$SCRIPT_DIR/docker-compose.yml" ]] || die "docker-compose.yml not found next to setup.sh."

# --- 1. Docker Engine (per docs.docker.com/engine/install/debian) ------------
log "Removing conflicting packages"
conflicts="$(dpkg --get-selections docker.io docker-compose docker-doc docker-buildx podman-docker containerd runc 2>/dev/null | cut -f1 || true)"
if [[ -n "$conflicts" ]]; then
  # shellcheck disable=SC2086
  apt-get remove -y $conflicts
fi

log "Adding Docker apt repository"
apt-get update
apt-get install -y ca-certificates curl
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc

cat > /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/debian
Suites: ${VERSION_CODENAME}
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF

apt-get update

log "Installing Docker Engine"
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
systemctl enable --now docker

log "Verifying Docker"
docker run --rm hello-world >/dev/null && log "Docker OK"

# --- AMD GPU firmware (RX 7600 needs it for amdgpu) --------------------------
log "Installing AMD GPU firmware (requires non-free-firmware component)"
if ! apt-get install -y firmware-amd-graphics; then
  warn "firmware-amd-graphics not installed. Enable 'non-free-firmware' in apt sources if the GPU is not detected."
fi
[[ -e /dev/kfd ]] || warn "/dev/kfd missing — amdgpu/KFD not loaded. A reboot may be required after firmware install."

# --- Packages for cron + firewall --------------------------------------------
apt-get install -y cron ufw
systemctl enable --now cron

# --- 2. Automatic apt upgrades -----------------------------------------------
log "Installing apt auto-update job"
cat > /usr/local/sbin/apt-auto-update <<'EOF'
#!/usr/bin/env bash
# Non-interactive apt upgrade. Keeps existing config files on conflicts.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
exec >>/var/log/apt-auto-update.log 2>&1
echo "=== $(date -Is) ==="
apt-get update
apt-get -y \
  -o Dpkg::Options::=--force-confdef \
  -o Dpkg::Options::=--force-confold \
  upgrade --with-new-pkgs
apt-get -y autoremove --purge
apt-get -y autoclean
[[ -f /var/run/reboot-required ]] && echo "Reboot required."
echo "=== done ==="
EOF
chmod 0755 /usr/local/sbin/apt-auto-update

cat > /etc/cron.d/apt-auto-update <<EOF
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
$APT_CRON root /usr/local/sbin/apt-auto-update
EOF
chmod 0644 /etc/cron.d/apt-auto-update

# --- 3. Automatic container updates ------------------------------------------
log "Deploying stack to $INSTALL_DIR"
install -d -m 0755 "$INSTALL_DIR"
install -m 0644 "$SCRIPT_DIR/docker-compose.yml" "$INSTALL_DIR/docker-compose.yml"

log "Installing container auto-update job"
cat > /usr/local/sbin/docker-auto-update <<EOF
#!/usr/bin/env bash
# Pull newer images for the stack, recreate changed containers, prune old images.
set -euo pipefail
exec >>/var/log/docker-auto-update.log 2>&1
echo "=== \$(date -Is) ==="
cd "$INSTALL_DIR"
docker compose pull
docker compose up -d --remove-orphans
docker image prune -f
echo "=== done ==="
EOF
chmod 0755 /usr/local/sbin/docker-auto-update

cat > /etc/cron.d/docker-auto-update <<EOF
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
$DOCKER_CRON root /usr/local/sbin/docker-auto-update
EOF
chmod 0644 /etc/cron.d/docker-auto-update

cat > /etc/logrotate.d/auto-update <<'EOF'
/var/log/apt-auto-update.log /var/log/docker-auto-update.log {
    weekly
    rotate 8
    compress
    missingok
    notifempty
}
EOF

# --- 4. UFW ------------------------------------------------------------------
log "Configuring UFW"
ufw --force reset >/dev/null
ufw default deny incoming
ufw default deny outgoing
ufw default deny routed

# Inbound
if [[ "$ALLOW_FROM" == "any" ]]; then
  ufw allow in "$SSH_PORT/tcp" comment 'SSH'
  ufw allow in "$OLLAMA_PORT/tcp" comment 'Ollama API'
else
  ufw allow in from "$ALLOW_FROM" to any port "$SSH_PORT" proto tcp comment 'SSH'
  ufw allow in from "$ALLOW_FROM" to any port "$OLLAMA_PORT" proto tcp comment 'Ollama API'
fi

# Outbound: minimum required for apt, Docker Hub / registry pulls, Ollama model pulls, DNS, NTP, DHCP.
ufw allow out 53 comment 'DNS'
ufw allow out 80/tcp comment 'HTTP (apt)'
ufw allow out 443/tcp comment 'HTTPS (apt, docker, ollama)'
ufw allow out 123/udp comment 'NTP'
ufw allow out 67/udp comment 'DHCP'

# Docker-published ports bypass UFW's INPUT rules. Enforce ALLOW_FROM for the
# Ollama port in the DOCKER-USER chain so the restriction actually applies.
AFTER_RULES=/etc/ufw/after.rules
sed -i '/^# BEGIN local-ai DOCKER-USER$/,/^# END local-ai DOCKER-USER$/d' "$AFTER_RULES"
if [[ "$ALLOW_FROM" != "any" ]]; then
  cat >> "$AFTER_RULES" <<EOF
# BEGIN local-ai DOCKER-USER
*filter
:DOCKER-USER - [0:0]
-A DOCKER-USER -m conntrack --ctstate RELATED,ESTABLISHED -j RETURN
-A DOCKER-USER -p tcp -m conntrack --ctorigdstport $OLLAMA_PORT --ctdir ORIGINAL -s $ALLOW_FROM -j RETURN
-A DOCKER-USER -p tcp -m conntrack --ctorigdstport $OLLAMA_PORT --ctdir ORIGINAL -j DROP
-A DOCKER-USER -j RETURN
COMMIT
# END local-ai DOCKER-USER
EOF
fi

ufw --force enable
systemctl enable ufw >/dev/null
# Docker re-creates its own chains; restart so they sit correctly after UFW's.
systemctl restart docker

# --- 5. Start the stack ------------------------------------------------------
if [[ "$SKIP_COMPOSE_UP" != "1" ]]; then
  log "Starting Ollama stack"
  (cd "$INSTALL_DIR" && docker compose up -d)
fi

log "Done."
ufw status verbose
echo
echo "Stack dir:          $INSTALL_DIR"
echo "apt updates:        $APT_CRON  -> /var/log/apt-auto-update.log"
echo "container updates:  $DOCKER_CRON  -> /var/log/docker-auto-update.log"
[[ -e /dev/kfd ]] || echo "WARNING: /dev/kfd missing. Reboot, then: cd $INSTALL_DIR && docker compose up -d"
