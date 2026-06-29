#!/bin/bash
# step-ca-setup.sh
# Installs and configures step-ca as an internal private CA with ACME support.
# Works on bare metal, VMs, and LXC containers.
# After setup, services can request certificates automatically via ACME,
# just like Let's Encrypt but fully internal.

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
[ "$EUID" -ne 0 ] && error "Please run as root (sudo ./step-ca-setup.sh)"

# ── Force interactive terminal (required when piped via curl) ─────────────────
[ ! -t 0 ] && exec < /dev/tty

# ── Log everything ────────────────────────────────────────────────────────────
LOGFILE="/var/log/step-ca-setup-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "$LOGFILE") 2>&1

echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║          step-ca Internal CA Setup                   ║"
echo "║          with ACME provisioner                       ║"
echo "╚══════════════════════════════════════════════════════╝"
echo ""
warn "This sets up a private Certificate Authority for your homelab."
warn "Services can request TLS certificates automatically via ACME."
echo ""
read -rp "Proceed? [y/N]: " CONFIRM
[ "${CONFIRM,,}" = "y" ] || { echo "Aborted."; exit 0; }

# ── Gather input ──────────────────────────────────────────────────────────────
step "1. Configuration"

# CA name
read -rp "CA name (e.g. 'Homelab CA' or 'Talva CA'): " CA_NAME
[ -z "$CA_NAME" ] && error "CA name cannot be empty."

# DNS name / IP for the CA server
mapfile -t ALL_IPS < <(ip -o -f inet addr show | awk '{print $4}' | grep -v '^127\.' | cut -d'/' -f1)

if [ "${#ALL_IPS[@]}" -eq 0 ]; then
  warn "Could not detect any IP addresses."
  while true; do
    read -rp "Enter this server's IP: " CA_IP
    [[ "$CA_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] && break
    warn "Invalid IP. Try again."
  done
elif [ "${#ALL_IPS[@]}" -eq 1 ]; then
  CA_IP="${ALL_IPS[0]}"
  info "Detected server IP: ${CA_IP}"
  read -rp "Use ${CA_IP}? [Y/n]: " IP_CONFIRM
  if [ "${IP_CONFIRM,,}" = "n" ]; then
    while true; do
      read -rp "Enter server IP manually: " CA_IP
      [[ "$CA_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] && break
      warn "Invalid IP. Try again."
    done
  fi
else
  info "Multiple IP addresses detected:"
  for i in "${!ALL_IPS[@]}"; do
    echo -e "  ${CYAN}$((i+1)))${NC} ${ALL_IPS[$i]}"
  done
  echo -e "  ${CYAN}$((${#ALL_IPS[@]}+1)))${NC} Enter manually"
  echo ""
  while true; do
    read -rp "Select IP [1-$((${#ALL_IPS[@]}+1))]: " IPCHOICE
    if [[ "$IPCHOICE" =~ ^[0-9]+$ ]] && [ "$IPCHOICE" -ge 1 ] && [ "$IPCHOICE" -le "${#ALL_IPS[@]}" ]; then
      CA_IP="${ALL_IPS[$((IPCHOICE-1))]}"
      break
    elif [ "$IPCHOICE" -eq "$((${#ALL_IPS[@]}+1))" ]; then
      while true; do
        read -rp "Enter server IP manually: " CA_IP
        [[ "$CA_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] && break
        warn "Invalid IP. Try again."
      done
      break
    fi
    warn "Invalid selection."
  done
fi
info "Using CA IP: ${CA_IP}"

# Optional DNS name for the CA
read -rp "DNS name for this CA server (e.g. ca.home.lan) [leave blank to use IP only]: " CA_DNS

# Port
read -rp "Port for step-ca to listen on [default: 443]: " CA_PORT
CA_PORT=${CA_PORT:-443}

# CA provisioner password
echo ""
warn "You will be asked to set a password to protect the CA provisioner key."
warn "Store this securely — you need it to manage the CA."
echo ""
while true; do
  read -rsp "CA provisioner password: " CA_PASS
  echo ""
  read -rsp "Confirm password: " CA_PASS_CONFIRM
  echo ""
  [ "$CA_PASS" = "$CA_PASS_CONFIRM" ] && break
  warn "Passwords do not match. Try again."
done
unset CA_PASS_CONFIRM

# Cert validity
read -rp "Default certificate validity in hours [default: 2160 = 90 days]: " CERT_HOURS
CERT_HOURS=${CERT_HOURS:-2160}

# ── Install dependencies ──────────────────────────────────────────────────────
step "2. Installing dependencies"
apt-get update -q
DEBIAN_FRONTEND=noninteractive apt-get install -y -q curl wget jq
info "Dependencies installed."

# ── Install step CLI and step-ca ─────────────────────────────────────────────
step "3. Installing step CLI and step-ca"

# Get latest versions from GitHub API
STEP_VERSION=$(curl -fsSL https://api.github.com/repos/smallstep/cli/releases/latest | jq -r '.tag_name' | tr -d 'v')
STEPCA_VERSION=$(curl -fsSL https://api.github.com/repos/smallstep/certificates/releases/latest | jq -r '.tag_name' | tr -d 'v')

info "Latest step CLI version: ${STEP_VERSION}"
info "Latest step-ca version:  ${STEPCA_VERSION}"

ARCH=$(dpkg --print-architecture)
case "$ARCH" in
  amd64)  ARCH_SUFFIX="amd64" ;;
  arm64)  ARCH_SUFFIX="arm64" ;;
  armhf)  ARCH_SUFFIX="armv7" ;;
  *)      error "Unsupported architecture: $ARCH" ;;
esac

# Download and install step CLI
STEP_DEB="step-cli_${STEP_VERSION}_${ARCH_SUFFIX}.deb"
STEP_URL="https://dl.smallstep.com/cli/docs-cli-install/latest/${STEP_DEB}"
info "Downloading step CLI..."
curl -fsSL "$STEP_URL" -o "/tmp/${STEP_DEB}" || error "Failed to download step CLI."
dpkg -i "/tmp/${STEP_DEB}"
rm -f "/tmp/${STEP_DEB}"
info "step CLI installed: $(step version | head -1)"

# Download and install step-ca
STEPCA_DEB="step-ca_${STEPCA_VERSION}_${ARCH_SUFFIX}.deb"
STEPCA_URL="https://dl.smallstep.com/certificates/docs-ca-install/latest/${STEPCA_DEB}"
info "Downloading step-ca..."
curl -fsSL "$STEPCA_URL" -o "/tmp/${STEPCA_DEB}" || error "Failed to download step-ca."
dpkg -i "/tmp/${STEPCA_DEB}"
rm -f "/tmp/${STEPCA_DEB}"
info "step-ca installed: $(step-ca version | head -1)"

# ── Create dedicated user ─────────────────────────────────────────────────────
step "4. Creating step-ca system user"
if ! id step &>/dev/null; then
  useradd --system --no-create-home --shell /usr/sbin/nologin step
  info "User 'step' created."
else
  info "User 'step' already exists."
fi

# ── Initialise the CA ─────────────────────────────────────────────────────────
step "5. Initialising CA"

CA_DIR="/etc/step-ca"
mkdir -p "$CA_DIR"

# Build DNS/IP SANs for the CA certificate
if [ -n "${CA_DNS:-}" ]; then
  CA_SANS="${CA_DNS},${CA_IP}"
else
  CA_SANS="${CA_IP}"
fi

# Write password to temp file for non-interactive init
PASS_FILE=$(mktemp /tmp/step-pass-XXXXXX)
echo "$CA_PASS" > "$PASS_FILE"
chmod 600 "$PASS_FILE"
unset CA_PASS

STEPPATH="$CA_DIR" step ca init \
  --name "$CA_NAME" \
  --dns "$CA_SANS" \
  --address ":${CA_PORT}" \
  --provisioner "acme" \
  --provisioner-password-file "$PASS_FILE" \
  --password-file "$PASS_FILE" \
  --deployment-type standalone \
  --acme

shred -u "$PASS_FILE"
info "CA initialised."

# ── Add ACME provisioner explicitly (ensure it's configured) ─────────────────
step "6. Configuring ACME provisioner"

CA_CONFIG="${CA_DIR}/config/ca.json"

# Check if ACME provisioner already exists
if grep -q '"type": "ACME"' "$CA_CONFIG" 2>/dev/null; then
  info "ACME provisioner already configured."
else
  warn "Adding ACME provisioner to CA config..."
  STEPPATH="$CA_DIR" step ca provisioner add acme --type ACME
  info "ACME provisioner added."
fi

# Set certificate validity in CA config
jq --argjson hours "$CERT_HOURS" \
  '.authority.provisioners[] |= if .type == "ACME" then .claims = {"maxTLSCertDuration": "\($hours)h", "defaultTLSCertDuration": "\($hours)h"} else . end' \
  "$CA_CONFIG" > "${CA_CONFIG}.tmp" && mv "${CA_CONFIG}.tmp" "$CA_CONFIG"
info "Certificate validity set to ${CERT_HOURS} hours."

# ── Set ownership ─────────────────────────────────────────────────────────────
step "7. Setting permissions"
chown -R step:step "$CA_DIR"
chmod 700 "$CA_DIR"
chmod 700 "${CA_DIR}/secrets" 2>/dev/null || true
chmod 700 "${CA_DIR}/config" 2>/dev/null || true
info "Permissions set."

# ── Allow binding to port 443 without root ────────────────────────────────────
if [ "$CA_PORT" -le 1024 ]; then
  step "7b. Granting low port binding capability"
  setcap CAP_NET_BIND_SERVICE=+eip "$(which step-ca)"
  info "step-ca can now bind to port ${CA_PORT} without root."
fi

# ── Systemd service ───────────────────────────────────────────────────────────
step "8. Creating systemd service"
cat > /etc/systemd/system/step-ca.service << EOF
[Unit]
Description=step-ca Internal Certificate Authority
Documentation=https://smallstep.com/docs/step-ca
After=network-online.target
Wants=network-online.target
StartLimitIntervalSec=30
StartLimitBurst=3

[Service]
Type=simple
User=step
Group=step
Environment=STEPPATH=${CA_DIR}
ExecStart=$(which step-ca) ${CA_DIR}/config/ca.json
Restart=on-failure
RestartSec=5

# Hardening
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
ReadWritePaths=${CA_DIR}
PrivateTmp=yes
PrivateDevices=yes

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable step-ca
systemctl start step-ca
sleep 3
systemctl is-active step-ca &>/dev/null && info "step-ca is running." || error "step-ca failed to start. Check: journalctl -xe -u step-ca"

# ── Export root certificate ───────────────────────────────────────────────────
step "9. Exporting root certificate"
ROOT_CERT="${CA_DIR}/certs/root_ca.crt"
cp "$ROOT_CERT" /usr/local/share/ca-certificates/step-ca-root.crt
update-ca-certificates
info "Root CA certificate installed system-wide."
info "Root cert also available at: ${ROOT_CERT}"

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║                    Done!                             ║"
echo "╚══════════════════════════════════════════════════════╝"
echo ""
info "CA Name:       ${CA_NAME}"
info "CA Address:    https://${CA_IP}:${CA_PORT}"
[ -n "${CA_DNS:-}" ] && info "CA DNS:        https://${CA_DNS}:${CA_PORT}"
info "ACME endpoint: https://${CA_IP}:${CA_PORT}/acme/acme/directory"
[ -n "${CA_DNS:-}" ] && info "ACME endpoint: https://${CA_DNS}:${CA_PORT}/acme/acme/directory"
echo ""
info "Root certificate: ${ROOT_CERT}"
echo ""
warn "IMPORTANT — install the root cert on every device/service that needs to trust this CA:"
echo "  Linux:  copy ${ROOT_CERT} to /usr/local/share/ca-certificates/ and run update-ca-certificates"
echo "  Browser: import ${ROOT_CERT} as a trusted CA"
echo ""
info "Useful commands:"
echo "  CA status:          systemctl status step-ca"
echo "  View CA config:     cat ${CA_DIR}/config/ca.json"
echo "  List provisioners:  STEPPATH=${CA_DIR} step ca provisioner list"
echo "  Issue cert:         STEPPATH=${CA_DIR} step ca certificate myhost.home.lan cert.pem key.pem"
echo "  Check cert:         step certificate inspect cert.pem"
echo ""
info "Log saved to: $LOGFILE"
echo ""