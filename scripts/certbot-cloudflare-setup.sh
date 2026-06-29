#!/bin/bash
# certbot-cloudflare-setup.sh
# Run this on a Debian/Ubuntu LXC to set up Let's Encrypt via Cloudflare DNS-01
# No inbound ports required.

set -euo pipefail
IFS=$'\n\t'

# ── Colors ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info()    { echo -e "${GREEN}[INFO]${NC}  $1"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $1"; }
error()   { echo -e "${RED}[ERROR]${NC} $1"; cleanup; exit 1; }
step()    { echo -e "\n${BLUE}──── $1 ────${NC}"; }

# ── Temp file tracking for cleanup ───────────────────────────────────────────
TEMP_FILES=()

cleanup() {
  for f in "${TEMP_FILES[@]:-}"; do
    [ -f "$f" ] && shred -u "$f" 2>/dev/null && info "Shredded temp file: $f"
  done
}
trap cleanup EXIT INT TERM

# ── Root check ────────────────────────────────────────────────────────────────
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}[ERROR]${NC} Please run as root (sudo ./certbot-cloudflare-setup.sh)"
  exit 1
fi

# ── Force interactive terminal (required when piped via curl) ─────────────────
[ ! -t 0 ] && exec < /dev/tty

# ── Dependency check ──────────────────────────────────────────────────────────
for cmd in curl apt-get shred; do
  command -v "$cmd" &>/dev/null || error "Required command not found: $cmd"
done

echo ""
echo "╔══════════════════════════════════════════════╗"
echo "║     Certbot + Cloudflare DNS-01 Setup        ║"
echo "╚══════════════════════════════════════════════╝"
echo ""
warn "This script will request a Let's Encrypt certificate."
warn "Let's Encrypt rate limit: 5 duplicate certs per domain per week."
echo ""

# ── Gather input ──────────────────────────────────────────────────────────────
step "Configuration"

# Domain
while true; do
  read -rp "Enter your domain (e.g. example.com): " DOMAIN
  # Basic domain format check
  if [[ "$DOMAIN" =~ ^[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z]{2,})+$ ]]; then
    break
  fi
  warn "That doesn't look like a valid domain. Try again."
done

# Wildcard
read -rp "Also generate wildcard cert (*.${DOMAIN})? [y/N]: " WILDCARD
WILDCARD=${WILDCARD,,}

# Email
while true; do
  read -rp "Enter your email (for Let's Encrypt expiry notices): " EMAIL
  if [[ "$EMAIL" =~ ^[^@]+@[^@]+\.[^@]+$ ]]; then
    break
  fi
  warn "That doesn't look like a valid email. Try again."
done

# Cloudflare token — silent input, never echoed
echo ""
warn "Your Cloudflare API token will not be shown as you type."
warn "Ensure it has: Zone → DNS → Edit, scoped to ${DOMAIN} only."
echo ""
while true; do
  read -rsp "Enter your Cloudflare API token: " CF_TOKEN
  echo ""
  read -rsp "Confirm your Cloudflare API token: " CF_TOKEN_CONFIRM
  echo ""
  if [ "$CF_TOKEN" = "$CF_TOKEN_CONFIRM" ]; then
    break
  fi
  warn "Tokens do not match. Try again."
done
unset CF_TOKEN_CONFIRM

# ── Validate token against Cloudflare API ─────────────────────────────────────
step "Validating Cloudflare API token"

CF_VERIFY=$(curl -sf --max-time 10 \
  -X GET "https://api.cloudflare.com/client/v4/user/tokens/verify" \
  -H "Authorization: Bearer ${CF_TOKEN}" \
  -H "Content-Type: application/json") || error "Could not reach Cloudflare API. Check network connectivity."

if ! echo "$CF_VERIFY" | grep -q '"success":true'; then
  error "Cloudflare API token is invalid or lacks required permissions. Aborting."
fi
info "Cloudflare API token verified successfully."

# ── Check if cert already exists ─────────────────────────────────────────────
CERT_PATH="/etc/letsencrypt/live/${DOMAIN}"
if [ -d "$CERT_PATH" ]; then
  echo ""
  warn "A certificate for ${DOMAIN} already exists at ${CERT_PATH}."
  read -rp "Overwrite / renew it? [y/N]: " OVERWRITE
  OVERWRITE=${OVERWRITE,,}
  if [ "$OVERWRITE" != "y" ]; then
    info "Aborting — existing cert left untouched."
    exit 0
  fi
fi

# ── Install packages ──────────────────────────────────────────────────────────
step "Installing packages"
apt-get update -q
DEBIAN_FRONTEND=noninteractive apt-get install -y -q certbot python3-certbot-dns-cloudflare

# ── Write credentials file ────────────────────────────────────────────────────
step "Writing credentials"

CREDS_DIR="/root/.secrets"
CREDS_FILE="${CREDS_DIR}/cloudflare.ini"

# If an old creds file exists, shred it first
if [ -f "$CREDS_FILE" ]; then
  shred -u "$CREDS_FILE"
  info "Shredded old credentials file."
fi

mkdir -p "$CREDS_DIR"
chmod 700 "$CREDS_DIR"

# Write to temp file first, then move atomically
TEMP_CREDS=$(mktemp /root/.secrets/.cf-XXXXXX)
TEMP_FILES+=("$TEMP_CREDS")
cat > "$TEMP_CREDS" <<EOF
dns_cloudflare_api_token = ${CF_TOKEN}
EOF
chmod 600 "$TEMP_CREDS"
mv "$TEMP_CREDS" "$CREDS_FILE"
# Remove from temp tracking since it's now the real file
TEMP_FILES=("${TEMP_FILES[@]/$TEMP_CREDS}")

# Unset token from memory as soon as it's written
unset CF_TOKEN

info "Credentials written to ${CREDS_FILE} (chmod 600, dir chmod 700)."

# ── Build certbot domain args ─────────────────────────────────────────────────
DOMAIN_ARGS="-d ${DOMAIN}"
if [ "$WILDCARD" = "y" ]; then
  DOMAIN_ARGS="${DOMAIN_ARGS} -d *.${DOMAIN}"
  info "Wildcard enabled — cert will cover *.${DOMAIN}"
fi

# ── Request certificate ───────────────────────────────────────────────────────
step "Requesting certificate"

certbot certonly \
  --dns-cloudflare \
  --dns-cloudflare-credentials "$CREDS_FILE" \
  --email "$EMAIL" \
  --agree-tos \
  --non-interactive \
  --dns-cloudflare-propagation-seconds 30 \
  $DOMAIN_ARGS

# ── Verify renewal ────────────────────────────────────────────────────────────
step "Testing auto-renewal"
certbot renew --dry-run
info "Auto-renewal dry-run passed."

# ── Verify systemd timer ──────────────────────────────────────────────────────
if systemctl is-enabled certbot.timer &>/dev/null; then
  info "certbot.timer is enabled and will handle auto-renewal."
else
  warn "certbot.timer not found — setting up cron fallback..."
  # Add cron job as fallback (runs twice daily, standard certbot recommendation)
  (crontab -l 2>/dev/null; echo "0 3,15 * * * certbot renew --quiet --deploy-hook 'systemctl reload nginx 2>/dev/null || true'") | crontab -
  info "Cron job added for renewal at 03:00 and 15:00 daily."
fi

# ── Harden the letsencrypt directory ─────────────────────────────────────────
chmod 700 /etc/letsencrypt/live/ 2>/dev/null || true
chmod 700 /etc/letsencrypt/archive/ 2>/dev/null || true

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════════╗"
echo "║                   Done!                      ║"
echo "╚══════════════════════════════════════════════╝"
echo ""
info "Certificate files:"
echo "    /etc/letsencrypt/live/${DOMAIN}/fullchain.pem"
echo "    /etc/letsencrypt/live/${DOMAIN}/privkey.pem"
echo ""
info "Check renewal timer:    systemctl status certbot.timer"
info "Check cert expiry:      certbot certificates"
echo ""
warn "Never commit /root/.secrets/cloudflare.ini to version control."
warn "The API token is stored there — keep it off GitHub."
echo ""