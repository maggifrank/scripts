#!/bin/bash
# caddy-public-setup.sh
# Installs and configures Caddy as a public-facing reverse proxy with automatic
# Let's Encrypt certificates via HTTP-01 challenge.
# Requires ports 80 and 443 open inbound from the internet.
# Works on bare metal, VMs, and LXC containers.

set -euo pipefail
IFS=$'\n\t'

# ── Colors ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC}  $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }
step()  { echo -e "\n${BLUE}──── $1 ────${NC}"; }

# ── Root check ────────────────────────────────────────────────────────────────
[ "$EUID" -ne 0 ] && error "Please run as root (sudo ./caddy-public-setup.sh)"

# ── Force interactive terminal ────────────────────────────────────────────────
[ ! -t 0 ] && exec < /dev/tty

# ── Update mode ───────────────────────────────────────────────────────────────
if command -v caddy &>/dev/null && [ -f /etc/caddy/Caddyfile ]; then
  echo ""
  echo "╔══════════════════════════════════════════════════════╗"
  echo "║     Caddy Public — Update Mode                       ║"
  echo "╚══════════════════════════════════════════════════════╝"
  echo ""
  info "Existing Caddy installation detected."
  info "Current version: $(caddy version)"
  step "Updating Caddy"
  apt-get update -q
  DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -q caddy
  caddy upgrade || warn "Caddy binary upgrade failed."
  systemctl restart caddy
  systemctl is-active caddy &>/dev/null && info "Caddy updated and running." || warn "Caddy failed to restart."
  echo ""
  exit 0
fi

# ── Log everything ────────────────────────────────────────────────────────────
LOGFILE="/var/log/caddy-public-setup-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "$LOGFILE") 2>&1

echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║     Caddy Public Reverse Proxy Setup                 ║"
echo "║     HTTP-01 — requires ports 80 and 443 open         ║"
echo "╚══════════════════════════════════════════════════════╝"
echo ""
warn "This script requires ports 80 and 443 open inbound from the internet."
warn "DNS A records must already point to this server's public IP."
echo ""
read -rp "Proceed? [y/N]: " CONFIRM
[ "${CONFIRM,,}" = "y" ] || { echo "Aborted."; exit 0; }

# ── Gather input ──────────────────────────────────────────────────────────────
step "1. Configuration"

# Email for Let's Encrypt
while true; do
  read -rp "Email for Let's Encrypt notifications: " LE_EMAIL
  if [[ "$LE_EMAIL" =~ ^[^@]+@[^@]+\.[^@]+$ ]]; then
    break
  fi
  warn "Invalid email format. Try again."
done

# Initial services
echo ""
info "Add services to proxy. Format: domain.com IP:port"
info "Example: mysite.com 10.0.0.20:8080"
info "Each service needs its own public DNS A record pointing to this server."
info "Empty line to finish. Add more later with: caddy-add-service"
echo ""
declare -A SERVICES
while true; do
  read -rp "Domain IP:port (or press Enter to finish): " SVCLINE
  [ -z "$SVCLINE" ] && break
  DOMAIN=$(echo "$SVCLINE" | awk '{print $1}')
  UPSTREAM=$(echo "$SVCLINE" | awk '{print $2}')
  if [[ -n "$DOMAIN" && "$UPSTREAM" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+:[0-9]+$ ]]; then
    SERVICES["$DOMAIN"]="$UPSTREAM"
    info "Added: ${DOMAIN} → ${UPSTREAM}"
  else
    warn "Invalid format. Use: domain.com IP:port"
  fi
done

# ── Install dependencies ──────────────────────────────────────────────────────
step "2. Installing dependencies"
apt-get update -q
DEBIAN_FRONTEND=noninteractive apt-get install -y -q curl gpg apt-transport-https
info "Dependencies installed."

# ── Install Caddy ─────────────────────────────────────────────────────────────
step "3. Installing Caddy"
curl -fsSL --max-time 30 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
  | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
curl -fsSL --max-time 30 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
  > /etc/apt/sources.list.d/caddy-stable.list
apt-get update -q
DEBIAN_FRONTEND=noninteractive apt-get install -y -q caddy
info "Caddy installed: $(caddy version)"

# ── Create directories ────────────────────────────────────────────────────────
step "4. Setting up directories"
mkdir -p /etc/caddy /var/lib/caddy /var/log/caddy
chown -R caddy:caddy /var/lib/caddy /var/log/caddy /etc/caddy
setcap CAP_NET_BIND_SERVICE=+eip /usr/bin/caddy
info "Directories and permissions set."

# ── Write Caddyfile ───────────────────────────────────────────────────────────
step "5. Writing Caddyfile"
CADDYFILE="/etc/caddy/Caddyfile"

cat > "$CADDYFILE" << EOF
# Caddy public reverse proxy configuration
# Managed by caddy-public-setup.sh
# Add new services with: caddy-add-service <domain> <ip:port>

{
    email ${LE_EMAIL}
    storage file_system /var/lib/caddy
}

EOF

for domain in "${!SERVICES[@]}"; do
  upstream="${SERVICES[$domain]}"
  cat >> "$CADDYFILE" << EOF
${domain} {
    reverse_proxy ${upstream}
}

EOF
  info "Added: ${domain} → ${upstream}"
done

chown caddy:caddy "$CADDYFILE"
info "Caddyfile written."

# ── Validate ──────────────────────────────────────────────────────────────────
step "6. Validating Caddyfile"
caddy validate --config "$CADDYFILE" && info "Caddyfile is valid." || error "Caddyfile has errors."

# ── Systemd service ───────────────────────────────────────────────────────────
step "7. Creating systemd service"
cat > /etc/systemd/system/caddy.service << 'EOF'
[Unit]
Description=Caddy Reverse Proxy
Documentation=https://caddyserver.com/docs/
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=30
StartLimitBurst=3

[Service]
Type=notify
User=caddy
Group=caddy
ExecStart=/usr/bin/caddy run --config /etc/caddy/Caddyfile
ExecReload=/usr/bin/caddy reload --config /etc/caddy/Caddyfile --force
TimeoutStopSec=5s
LimitNOFILE=1048576
PrivateTmp=true
ProtectSystem=strict
AmbientCapabilities=CAP_NET_BIND_SERVICE
ReadWritePaths=/var/lib/caddy /var/log/caddy /etc/caddy
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable caddy
systemctl start caddy
sleep 3
systemctl is-active caddy &>/dev/null && info "Caddy is running." || error "Caddy failed to start. Check: journalctl -xe -u caddy"

# ── Install caddy-add-service helper ─────────────────────────────────────────
step "8. Installing caddy-add-service helper"
cat > /usr/local/bin/caddy-add-service << HELPER
#!/bin/bash
# caddy-add-service — add a new reverse proxy entry to Caddy (public mode)
# Usage: caddy-add-service <domain> <ip:port>
# Example: caddy-add-service mysite.com 10.0.0.20:8080

set -euo pipefail

CADDYFILE="/etc/caddy/Caddyfile"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

[ "\$EUID" -ne 0 ] && { echo -e "\${RED}[ERROR]\${NC} Run as root."; exit 1; }
[ "\$#" -ne 2 ] && { echo "Usage: caddy-add-service <domain> <ip:port>"; exit 1; }

DOMAIN="\$1"
UPSTREAM="\$2"

if ! [[ "\$UPSTREAM" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+:[0-9]+\$ ]]; then
  echo -e "\${RED}[ERROR]\${NC} Invalid upstream format. Use IP:port e.g. 10.0.0.20:8080"
  exit 1
fi

if grep -q "^\${DOMAIN}" "\$CADDYFILE"; then
  echo -e "\${YELLOW}[WARN]\${NC}  \${DOMAIN} already exists in Caddyfile."
  exit 1
fi

cat >> "\$CADDYFILE" << EOF

\${DOMAIN} {
    reverse_proxy \${UPSTREAM}
}
EOF

caddy validate --config "\$CADDYFILE" > /dev/null 2>&1 || {
  echo -e "\${RED}[ERROR]\${NC} Caddyfile validation failed — changes rolled back."
  head -n -5 "\$CADDYFILE" > "\${CADDYFILE}.tmp" && mv "\${CADDYFILE}.tmp" "\$CADDYFILE"
  exit 1
}

systemctl reload caddy
echo -e "\${GREEN}[INFO]\${NC}  Added: \${DOMAIN} → \${UPSTREAM}"
echo -e "\${GREEN}[INFO]\${NC}  Certificate will be issued automatically when traffic hits port 80."
HELPER
chmod +x /usr/local/bin/caddy-add-service
info "caddy-add-service helper installed."

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║                    Done!                             ║"
echo "╚══════════════════════════════════════════════════════╝"
echo ""
info "Email: ${LE_EMAIL}"
echo ""
if [ "${#SERVICES[@]}" -gt 0 ]; then
  info "Proxied services:"
  for domain in "${!SERVICES[@]}"; do
    echo "    https://${domain} → ${SERVICES[$domain]}"
  done
fi
echo ""
warn "Make sure DNS A records point to this server's public IP for each domain."
warn "Certificates are issued automatically on first request — no manual steps needed."
echo ""
info "Add more services:   caddy-add-service <domain> <ip:port>"
info "Reload after edits:  systemctl reload caddy"
info "View logs:           journalctl -u caddy -f"
info "Edit Caddyfile:      nano /etc/caddy/Caddyfile"
echo ""
info "Log saved to: $LOGFILE"
echo ""
