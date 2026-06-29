#!/bin/bash
# caddy-setup.sh
# Installs and configures Caddy as a reverse proxy with automatic Let's Encrypt
# certificates via Cloudflare DNS-01. No inbound ports required for cert issuance.
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
[ "$EUID" -ne 0 ] && error "Please run as root (sudo ./caddy-setup.sh)"

# ── Force interactive terminal (required when piped via curl) ─────────────────
[ ! -t 0 ] && exec < /dev/tty

# ── Update mode — if Caddy is already installed, update instead of reinstall ──
if command -v caddy &>/dev/null && [ -f /etc/caddy/Caddyfile ]; then
  echo ""
  echo "╔══════════════════════════════════════════════════════╗"
  echo "║     Caddy — Update Mode                              ║"
  echo "╚══════════════════════════════════════════════════════╝"
  echo ""
  info "Existing Caddy installation detected."
  info "Current version: $(caddy version)"
  echo ""
  step "Updating Caddy"
  apt-get update -q
  DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -q caddy
  caddy upgrade || warn "Caddy binary upgrade failed — may need manual intervention."
  systemctl restart caddy
  info "Updated to: $(caddy version)"
  systemctl is-active caddy &>/dev/null && info "Caddy is running." || warn "Caddy failed to restart — check: journalctl -xe -u caddy"
  echo ""
  exit 0
fi

# ── Log everything ────────────────────────────────────────────────────────────
LOGFILE="/var/log/caddy-setup-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "$LOGFILE") 2>&1

echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║     Caddy Reverse Proxy + Let's Encrypt Setup        ║"
echo "║     Cloudflare DNS-01 — no inbound ports needed      ║"
echo "╚══════════════════════════════════════════════════════╝"
echo ""

# ── Gather input ──────────────────────────────────────────────────────────────
step "1. Configuration"

# Domain
while true; do
  read -rp "Your public domain (e.g. example.is): " DOMAIN
  if [[ "$DOMAIN" =~ ^([a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$ ]]; then
    break
  fi
  warn "Invalid domain format. Try again."
done

# Email for Let's Encrypt
while true; do
  read -rp "Email for Let's Encrypt notifications: " LE_EMAIL
  if [[ "$LE_EMAIL" =~ ^[^@]+@[^@]+\.[^@]+$ ]]; then
    break
  fi
  warn "Invalid email format. Try again."
done

# Cloudflare API token
echo ""
warn "Cloudflare API token needs Zone → DNS → Edit for ${DOMAIN}."
warn "Token will not be shown as you type."
echo ""
while true; do
  read -rsp "Cloudflare API token: " CF_TOKEN
  echo ""
  read -rsp "Confirm Cloudflare API token: " CF_TOKEN_CONFIRM
  echo ""
  [ "$CF_TOKEN" = "$CF_TOKEN_CONFIRM" ] && break
  warn "Tokens do not match. Try again."
done
unset CF_TOKEN_CONFIRM
[ -z "${CF_TOKEN:-}" ] && error "Cloudflare token cannot be empty."

# Validate Cloudflare token
info "Validating Cloudflare token..."
CF_VERIFY=$(curl -sf --max-time 10 \
  -X GET "https://api.cloudflare.com/client/v4/user/tokens/verify" \
  -H "Authorization: Bearer ${CF_TOKEN}" \
  -H "Content-Type: application/json") || error "Could not reach Cloudflare API."
echo "$CF_VERIFY" | grep -q '"success":true' || error "Cloudflare token is invalid or missing permissions."
info "Cloudflare token verified."

# Initial services to proxy
echo ""
info "Add services to proxy. Format: subdomain IP:port"
info "Example: jellyfin 10.0.0.20:8096"
info "Empty line to finish. You can add more later with: caddy-add-service"
echo ""
declare -A SERVICES
while true; do
  read -rp "Subdomain IP:port (or press Enter to finish): " SVCLINE
  [ -z "$SVCLINE" ] && break
  SUBDOMAIN=$(echo "$SVCLINE" | awk '{print $1}')
  UPSTREAM=$(echo "$SVCLINE" | awk '{print $2}')
  if [[ -n "$SUBDOMAIN" && "$UPSTREAM" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+:[0-9]+$ ]]; then
    SERVICES["$SUBDOMAIN"]="$UPSTREAM"
    info "Added: ${SUBDOMAIN}.${DOMAIN} → ${UPSTREAM}"
  else
    warn "Invalid format. Use: subdomain IP:port (e.g. jellyfin 10.0.0.20:8096)"
  fi
done

# ── Install dependencies ──────────────────────────────────────────────────────
step "2. Installing dependencies"
apt-get update -q
DEBIAN_FRONTEND=noninteractive apt-get install -y -q curl jq gpg apt-transport-https
info "Dependencies installed."

# ── Install Caddy with Cloudflare DNS plugin ──────────────────────────────────
step "3. Installing Caddy with Cloudflare DNS plugin"

# Install Caddy from official apt repo
info "Adding Caddy apt repository..."
curl -fsSL --max-time 30 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
  | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
curl -fsSL --max-time 30 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
  > /etc/apt/sources.list.d/caddy-stable.list
apt-get update -q
DEBIAN_FRONTEND=noninteractive apt-get install -y -q caddy
info "Caddy base installed: $(caddy version)"

# Add Cloudflare DNS plugin via caddy add-package
info "Adding Cloudflare DNS plugin..."
caddy add-package github.com/caddy-dns/cloudflare || error "Failed to add Cloudflare plugin. Check internet connectivity."
info "Cloudflare DNS plugin added: $(caddy version)"

# ── Create caddy user and directories ────────────────────────────────────────
step "4. Setting up Caddy user and directories"
if ! id caddy &>/dev/null; then
  useradd --system --no-create-home --shell /usr/sbin/nologin caddy
  info "User 'caddy' created."
fi

mkdir -p /etc/caddy
mkdir -p /var/lib/caddy
mkdir -p /var/log/caddy
chown -R caddy:caddy /var/lib/caddy /var/log/caddy /etc/caddy
info "Directories created."

# Allow Caddy to bind to ports 80 and 443 without root
setcap CAP_NET_BIND_SERVICE=+eip /usr/bin/caddy
info "Port binding capability granted."

# ── Store Cloudflare token securely ──────────────────────────────────────────
step "5. Storing Cloudflare credentials"
CF_ENV="/etc/caddy/cloudflare.env"

# Shred old credentials file if it exists
if [ -f "$CF_ENV" ]; then
  shred -u "$CF_ENV"
  info "Shredded old credentials file."
fi

cat > "$CF_ENV" << EOF
CLOUDFLARE_API_TOKEN=${CF_TOKEN}
EOF
chown caddy:caddy "$CF_ENV"
chmod 600 "$CF_ENV"
unset CF_TOKEN
info "Cloudflare token stored at ${CF_ENV} (chmod 600)."

# ── Write Caddyfile ───────────────────────────────────────────────────────────
step "6. Writing Caddyfile"
CADDYFILE="/etc/caddy/Caddyfile"

cat > "$CADDYFILE" << EOF
# Caddy reverse proxy configuration
# Managed by caddy-setup.sh
# Add new services with: caddy-add-service <subdomain> <ip:port>

{
    email ${LE_EMAIL}
    storage file_system /var/lib/caddy
}

EOF

# Add each service block with Cloudflare DNS-01 tls config
for subdomain in "${!SERVICES[@]}"; do
  upstream="${SERVICES[$subdomain]}"
  cat >> "$CADDYFILE" << EOF
${subdomain}.${DOMAIN} {
    tls {
        dns cloudflare {env.CLOUDFLARE_API_TOKEN}
    }
    reverse_proxy ${upstream}
}

EOF
  info "Added proxy: ${subdomain}.${DOMAIN} → ${upstream}"
done

chown caddy:caddy "$CADDYFILE"
info "Caddyfile written."

# ── Validate Caddyfile ────────────────────────────────────────────────────────
step "7. Validating Caddyfile"
caddy validate --config "$CADDYFILE" && info "Caddyfile is valid." || error "Caddyfile has errors — check above output."

# ── Systemd service ───────────────────────────────────────────────────────────
step "8. Creating systemd service"
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
EnvironmentFile=/etc/caddy/cloudflare.env
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
step "9. Installing caddy-add-service helper"
cat > /usr/local/bin/caddy-add-service << HELPER
#!/bin/bash
# caddy-add-service — add a new reverse proxy entry to Caddy
# Usage: caddy-add-service <subdomain> <ip:port>
# Example: caddy-add-service jellyfin 10.0.0.20:8096

set -euo pipefail

CADDYFILE="/etc/caddy/Caddyfile"
DOMAIN="${DOMAIN}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

[ "\$EUID" -ne 0 ] && { echo -e "\${RED}[ERROR]\${NC} Run as root."; exit 1; }
[ "\$#" -ne 2 ] && { echo "Usage: caddy-add-service <subdomain> <ip:port>"; exit 1; }

SUBDOMAIN="\$1"
UPSTREAM="\$2"

if ! [[ "\$UPSTREAM" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+:[0-9]+\$ ]]; then
  echo -e "\${RED}[ERROR]\${NC} Invalid upstream format. Use IP:port e.g. 10.0.0.20:8096"
  exit 1
fi

# Check for duplicate
if grep -q "^\${SUBDOMAIN}.\${DOMAIN}" "\$CADDYFILE"; then
  echo -e "\${YELLOW}[WARN]\${NC}  \${SUBDOMAIN}.\${DOMAIN} already exists in Caddyfile."
  exit 1
fi

# Append new service block
cat >> "\$CADDYFILE" << EOF

\${SUBDOMAIN}.\${DOMAIN} {
    tls {
        dns cloudflare {env.CLOUDFLARE_API_TOKEN}
    }
    reverse_proxy \${UPSTREAM}
}
EOF

# Validate before reloading
caddy validate --config "\$CADDYFILE" > /dev/null 2>&1 || {
  echo -e "\${RED}[ERROR]\${NC} Caddyfile validation failed — changes rolled back."
  # Remove the block we just added
  head -n -7 "\$CADDYFILE" > "\${CADDYFILE}.tmp" && mv "\${CADDYFILE}.tmp" "\$CADDYFILE"
  exit 1
}

systemctl reload caddy
echo -e "\${GREEN}[INFO]\${NC}  Added: \${SUBDOMAIN}.\${DOMAIN} → \${UPSTREAM}"
echo -e "\${GREEN}[INFO]\${NC}  Caddy reloaded. Certificate will be issued automatically."
HELPER
chmod +x /usr/local/bin/caddy-add-service
info "caddy-add-service helper installed."

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║                    Done!                             ║"
echo "╚══════════════════════════════════════════════════════╝"
echo ""
info "Domain:   ${DOMAIN}"
info "Email:    ${LE_EMAIL}"
echo ""
if [ "${#SERVICES[@]}" -gt 0 ]; then
  info "Proxied services:"
  for subdomain in "${!SERVICES[@]}"; do
    echo "    https://${subdomain}.${DOMAIN} → ${SERVICES[$subdomain]}"
  done
fi
echo ""
warn "IMPORTANT — for each service, add a DNS record in Cloudflare:"
echo "  Type:  A"
echo "  Name:  <subdomain>"
echo "  Value: <IP of this Caddy server>"
echo "  Proxy: DNS only (grey cloud) — NOT proxied through Cloudflare"
echo ""
info "Add more services:   caddy-add-service <subdomain> <ip:port>"
info "Reload after edits:  systemctl reload caddy"
info "View logs:           journalctl -u caddy -f"
info "Edit Caddyfile:      nano /etc/caddy/Caddyfile"
echo ""
info "Log saved to: $LOGFILE"
echo ""