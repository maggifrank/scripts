#!/bin/bash
# bind9-setup.sh
# Installs and configures BIND9 as a local DNS server with forwarder and split-horizon.
# Internal hostnames resolve to local IPs; everything else forwards upstream.

set -euo pipefail
IFS=$'\n\t'

# ── Colors ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC}  $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }
step()  { echo -e "\n${BLUE}──── $1 ────${NC}"; }

# ── Root check ────────────────────────────────────────────────────────────────
[ "$EUID" -ne 0 ] && error "Please run as root (sudo ./bind9-setup.sh)"

# ── Log everything ────────────────────────────────────────────────────────────
LOGFILE="/var/log/bind9-setup-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "$LOGFILE") 2>&1

echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║         BIND9 Local DNS + Forwarder Setup            ║"
echo "╚══════════════════════════════════════════════════════╝"
echo ""

# ── Gather input ──────────────────────────────────────────────────────────────
step "Configuration"

# Local domain
while true; do
  read -rp "Local domain name (e.g. home.lan or home.yourdomain.com): " LOCAL_DOMAIN
  if [[ "$LOCAL_DOMAIN" =~ ^([a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$ ]]; then
    break
  fi
  warn "Invalid domain format. Try again."
done

# Server IP — collect all non-loopback IPs and let user pick
mapfile -t ALL_IPS < <(ip -o -f inet addr show | awk '{print $4}' | grep -v '^127\.' | cut -d'/' -f1)

if [ "${#ALL_IPS[@]}" -eq 0 ]; then
  warn "Could not detect any IP addresses."
  while true; do
    read -rp "Enter server IP manually (e.g. 10.0.0.53): " SERVER_IP
    [[ "$SERVER_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] && break
    warn "Invalid IP address. Try again."
  done
elif [ "${#ALL_IPS[@]}" -eq 1 ]; then
  SERVER_IP="${ALL_IPS[0]}"
  info "Detected server IP: ${SERVER_IP}"
  read -rp "Use ${SERVER_IP}? [Y/n]: " IP_CONFIRM
  if [ "${IP_CONFIRM,,}" = "n" ]; then
    while true; do
      read -rp "Enter server IP manually: " SERVER_IP
      [[ "$SERVER_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] && break
      warn "Invalid IP address. Try again."
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
    read -rp "Select IP to use [1-$((${#ALL_IPS[@]}+1))]: " IPCHOICE
    if [[ "$IPCHOICE" =~ ^[0-9]+$ ]] && [ "$IPCHOICE" -ge 1 ] && [ "$IPCHOICE" -le "${#ALL_IPS[@]}" ]; then
      SERVER_IP="${ALL_IPS[$((IPCHOICE-1))]}"
      break
    elif [ "$IPCHOICE" -eq "$((${#ALL_IPS[@]}+1))" ]; then
      while true; do
        read -rp "Enter server IP manually: " SERVER_IP
        [[ "$SERVER_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] && break
        warn "Invalid IP address. Try again."
      done
      break
    fi
    warn "Invalid selection."
  done
fi
info "Using server IP: ${SERVER_IP}"

# Derive reverse zone from IP (e.g. 10.0.0.x → 0.0.10.in-addr.arpa)
IFS='.' read -r oct1 oct2 oct3 oct4 <<< "$SERVER_IP"
REVERSE_ZONE="${oct3}.${oct2}.${oct1}.in-addr.arpa"
NETWORK_PREFIX="${oct1}.${oct2}.${oct3}"

# Subnet allowed to query this server (auto-detect)
DETECTED_SUBNET=$(ip -o -f inet addr show | awk -v ip="$SERVER_IP" '$4 ~ ip {print $4}' | head -1 | sed 's|/[0-9]*||')
DETECTED_PREFIX=$(ip -o -f inet addr show | awk -v ip="$SERVER_IP" '$4 ~ ip {print $4}' | head -1 | cut -d'/' -f2)

if [[ -n "$DETECTED_SUBNET" && -n "$DETECTED_PREFIX" ]]; then
  # Build network address from IP + prefix
  DETECTED_NETWORK="${oct1}.${oct2}.${oct3}.0/${DETECTED_PREFIX}"
  info "Detected local subnet: ${DETECTED_NETWORK}"
  read -rp "Use ${DETECTED_NETWORK}? [Y/n]: " SUBNET_CONFIRM
  SUBNET_CONFIRM=${SUBNET_CONFIRM,,}
  if [ "$SUBNET_CONFIRM" = "n" ]; then
    while true; do
      read -rp "Enter subnet manually (e.g. 10.0.0.0/24): " LOCAL_SUBNET
      [[ "$LOCAL_SUBNET" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]] && break
      warn "Invalid format. Use CIDR notation e.g. 10.0.0.0/24"
    done
  else
    LOCAL_SUBNET="$DETECTED_NETWORK"
  fi
else
  warn "Could not auto-detect subnet."
  while true; do
    read -rp "Local subnet to allow queries from (e.g. 10.0.0.0/24): " LOCAL_SUBNET
    [[ "$LOCAL_SUBNET" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]] && break
    warn "Invalid format. Use CIDR notation e.g. 10.0.0.0/24"
  done
fi

# Forwarders
echo ""
info "Enter upstream DNS forwarders (press Enter after each, empty line to finish)."
info "Recommended: 1.1.1.1 (Cloudflare) or 8.8.8.8 (Google) or your ISP's DNS."
FORWARDERS=()
while true; do
  read -rp "Forwarder IP (or press Enter to finish): " FWD
  [ -z "$FWD" ] && break
  if [[ "$FWD" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    FORWARDERS+=("$FWD")
  else
    warn "Invalid IP, try again."
  fi
done

if [ "${#FORWARDERS[@]}" -eq 0 ]; then
  warn "No forwarders entered — defaulting to Cloudflare (1.1.1.1) and Google (8.8.8.8)."
  FORWARDERS=("1.1.1.1" "8.8.8.8")
fi

# Build forwarder string for named.conf
FORWARDER_LINES=""
for fwd in "${FORWARDERS[@]}"; do
  FORWARDER_LINES+="        ${fwd};"$'\n'
done

# Initial DNS records
echo ""
info "Add initial A records for your local domain."
info "Format: hostname IP (e.g. 'proxmox 10.0.0.10'). Empty line to finish."
declare -A DNS_RECORDS
while true; do
  read -rp "Hostname IP (or press Enter to finish): " RECORD
  [ -z "$RECORD" ] && break
  HOST=$(echo "$RECORD" | awk '{print $1}')
  IP=$(echo "$RECORD" | awk '{print $2}')
  if [[ -n "$HOST" && "$IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    DNS_RECORDS["$HOST"]="$IP"
    info "Added: ${HOST}.${LOCAL_DOMAIN} → ${IP}"
  else
    warn "Invalid format. Use: hostname IP"
  fi
done

echo ""
info "Starting BIND9 installation..."

# ── Install ───────────────────────────────────────────────────────────────────
step "1. Installing BIND9"
apt-get update -q
DEBIAN_FRONTEND=noninteractive apt-get install -y -q bind9 bind9utils bind9-doc dnsutils
info "BIND9 installed."

# ── Entropy (haveged) ─────────────────────────────────────────────────────────
step "2. Ensuring sufficient entropy (haveged)"
DEBIAN_FRONTEND=noninteractive apt-get install -y -q haveged
systemctl enable haveged
systemctl start haveged
info "haveged installed and running — entropy pool healthy."

# ── AppArmor ──────────────────────────────────────────────────────────────────
step "3. Handling AppArmor BIND9 profile"
if command -v apparmor_parser &>/dev/null && [ -f /etc/apparmor.d/usr.sbin.named ]; then
  DISABLE_DIR="/etc/apparmor.d/disable"
  mkdir -p "$DISABLE_DIR"
  if [ ! -f "${DISABLE_DIR}/usr.sbin.named" ]; then
    ln -s /etc/apparmor.d/usr.sbin.named "${DISABLE_DIR}/usr.sbin.named"
    apparmor_parser -R /etc/apparmor.d/usr.sbin.named 2>/dev/null || true
    info "AppArmor BIND9 profile disabled — prevents LXC confinement conflicts."
  else
    info "AppArmor BIND9 profile already disabled."
  fi
else
  info "AppArmor not active or BIND9 profile not found — skipping."
fi

# ── Backup existing config ────────────────────────────────────────────────────
step "4. Backing up existing config"
BACKUP_DIR="/etc/bind/backup-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$BACKUP_DIR"
cp -r /etc/bind/*.conf* "$BACKUP_DIR/" 2>/dev/null || true
info "Existing config backed up to $BACKUP_DIR"

# ── named.conf.options ────────────────────────────────────────────────────────
step "5. Writing named.conf.options"
cat > /etc/bind/named.conf.options << EOF
acl "trusted" {
    localhost;
    ${LOCAL_SUBNET};
};

options {
    directory "/var/cache/bind";

    // Only allow trusted clients to query
    allow-query     { trusted; };
    allow-recursion { trusted; };
    allow-query-cache { trusted; };

    // Forwarders — upstream DNS for unknown names
    forwarders {
${FORWARDER_LINES}    };
    forward only;

    // Do not expose version string
    version "not currently available";

    // Disable zone transfers (no secondary DNS)
    allow-transfer { none; };

    // Disable notifies
    notify no;

    // Listen on all interfaces (restrict if needed)
    listen-on { any; };
    listen-on-v6 { none; };

    // Recommended defaults
    dnssec-validation no;
    auth-nxdomain no;
    recursion yes;
};
EOF
info "named.conf.options written."

# ── named.conf.local ──────────────────────────────────────────────────────────
step "6. Writing named.conf.local"
cat > /etc/bind/named.conf.local << EOF
// Forward zone — local domain
zone "${LOCAL_DOMAIN}" {
    type master;
    file "/etc/bind/zones/db.${LOCAL_DOMAIN}";
    allow-query { trusted; };
};

// Reverse zone — PTR records
zone "${REVERSE_ZONE}" {
    type master;
    file "/etc/bind/zones/db.${REVERSE_ZONE}";
    allow-query { trusted; };
};
EOF
info "named.conf.local written."

# ── Zone files ────────────────────────────────────────────────────────────────
step "7. Creating zone files"
mkdir -p /etc/bind/zones

SERIAL=$(date +%Y%m%d%H)

# ── Forward zone ──────────────────────────────────────────────────────────────
cat > "/etc/bind/zones/db.${LOCAL_DOMAIN}" << EOF
\$TTL    604800
@   IN  SOA ns1.${LOCAL_DOMAIN}. admin.${LOCAL_DOMAIN}. (
                ${SERIAL}   ; Serial
                3600        ; Refresh
                1800        ; Retry
                604800      ; Expire
                86400 )     ; Negative Cache TTL

; Name servers
@       IN  NS  ns1.${LOCAL_DOMAIN}.

; NS A record
ns1     IN  A   ${SERVER_IP}

; A records
EOF

# Add user-defined records
for host in "${!DNS_RECORDS[@]}"; do
  echo "${host}     IN  A   ${DNS_RECORDS[$host]}" >> "/etc/bind/zones/db.${LOCAL_DOMAIN}"
done

info "Forward zone written."

# ── Reverse zone ──────────────────────────────────────────────────────────────
cat > "/etc/bind/zones/db.${REVERSE_ZONE}" << EOF
\$TTL    604800
@   IN  SOA ns1.${LOCAL_DOMAIN}. admin.${LOCAL_DOMAIN}. (
                ${SERIAL}   ; Serial
                3600        ; Refresh
                1800        ; Retry
                604800      ; Expire
                86400 )     ; Negative Cache TTL

; Name servers
@       IN  NS  ns1.${LOCAL_DOMAIN}.

; PTR records
EOF

# Derive last octet of server IP for PTR
SERVER_LAST_OCTET=$(echo "$SERVER_IP" | cut -d'.' -f4)
echo "${SERVER_LAST_OCTET}    IN  PTR ns1.${LOCAL_DOMAIN}." >> "/etc/bind/zones/db.${REVERSE_ZONE}"

for host in "${!DNS_RECORDS[@]}"; do
  ip="${DNS_RECORDS[$host]}"
  # Only add PTR if IP is in same /24
  ip_prefix=$(echo "$ip" | cut -d'.' -f1-3)
  if [ "$ip_prefix" = "$NETWORK_PREFIX" ]; then
    last_octet=$(echo "$ip" | cut -d'.' -f4)
    echo "${last_octet}    IN  PTR ${host}.${LOCAL_DOMAIN}." >> "/etc/bind/zones/db.${REVERSE_ZONE}"
  fi
done

info "Reverse zone written."

# ── File permissions ──────────────────────────────────────────────────────────
step "8. Setting permissions"
chown -R bind:bind /etc/bind/zones
chmod 750 /etc/bind/zones
chmod 640 /etc/bind/zones/*
info "Permissions set."

# ── Validate config ───────────────────────────────────────────────────────────
step "9. Validating configuration"
named-checkconf /etc/bind/named.conf && info "named.conf syntax OK." || error "named.conf has errors — check above output."
named-checkzone "$LOCAL_DOMAIN" "/etc/bind/zones/db.${LOCAL_DOMAIN}" && info "Forward zone OK." || error "Forward zone has errors."
named-checkzone "$REVERSE_ZONE" "/etc/bind/zones/db.${REVERSE_ZONE}" && info "Reverse zone OK." || error "Reverse zone has errors."

# ── Enable and start ──────────────────────────────────────────────────────────
step "10. Starting BIND9"

# Detect correct service name
# bind9.service is often just an alias/symlink for named.service on Ubuntu
# Check if bind9 is an alias — if so, use named directly
if systemctl list-unit-files bind9.service 2>/dev/null | grep -qE "alias|linked"; then
  BIND_SVC="named"
elif systemctl list-unit-files named.service 2>/dev/null | grep -qE "enabled|disabled|static"; then
  BIND_SVC="named"
else
  BIND_SVC="bind9"
fi
info "Using service name: ${BIND_SVC}"

systemctl enable "$BIND_SVC"
systemctl restart "$BIND_SVC"
sleep 2
systemctl is-active "$BIND_SVC" &>/dev/null && info "BIND9 is running." || error "BIND9 failed to start. Check: journalctl -xe -u ${BIND_SVC}"

# ── Test resolution ───────────────────────────────────────────────────────────
step "11. Testing DNS resolution"
info "Testing local resolution (ns1.${LOCAL_DOMAIN})..."
dig @127.0.0.1 "ns1.${LOCAL_DOMAIN}" +short && info "Local resolution working." || warn "Local resolution test failed — check zone files."

info "Testing forwarder (google.com)..."
dig @127.0.0.1 google.com +short | head -1 && info "Forwarder working." || warn "Forwarder test failed — check forwarder IPs and connectivity."

# ── Helper script: add DNS record ─────────────────────────────────────────────
step "12. Installing dns-add helper"
cat > /usr/local/bin/dns-add << HELPER
#!/bin/bash
# dns-add — add an A record and PTR record to BIND9
# Usage: dns-add <hostname> <ip>

set -euo pipefail

LOCAL_DOMAIN="${LOCAL_DOMAIN}"
FORWARD_ZONE="/etc/bind/zones/db.${LOCAL_DOMAIN}"
REVERSE_ZONE_FILE="/etc/bind/zones/db.${REVERSE_ZONE}"
NETWORK_PREFIX="${NETWORK_PREFIX}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

[ "\$EUID" -ne 0 ] && { echo -e "\${RED}[ERROR]\${NC} Run as root."; exit 1; }
[ "\$#" -ne 2 ] && { echo "Usage: dns-add <hostname> <ip>"; exit 1; }

HOST="\$1"
IP="\$2"

if ! [[ "\$IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}\$ ]]; then
  echo -e "\${RED}[ERROR]\${NC} Invalid IP: \$IP"
  exit 1
fi

# Check for duplicate
if grep -q "^\${HOST}[[:space:]]" "\$FORWARD_ZONE"; then
  echo -e "\${YELLOW}[WARN]\${NC}  \$HOST already exists in forward zone."
  exit 1
fi

# Bump serial
SERIAL=\$(date +%Y%m%d%H)
sed -i "s/[0-9]\{10\}.*; Serial/\${SERIAL}        ; Serial/" "\$FORWARD_ZONE"
sed -i "s/[0-9]\{10\}.*; Serial/\${SERIAL}        ; Serial/" "\$REVERSE_ZONE_FILE"

# Add A record
echo "\${HOST}     IN  A   \${IP}" >> "\$FORWARD_ZONE"
echo -e "\${GREEN}[INFO]\${NC}  Added A record: \${HOST}.\${LOCAL_DOMAIN} → \${IP}"

# Add PTR if in same subnet
IP_PREFIX=\$(echo "\$IP" | cut -d'.' -f1-3)
if [ "\$IP_PREFIX" = "\$NETWORK_PREFIX" ]; then
  LAST=\$(echo "\$IP" | cut -d'.' -f4)
  echo "\${LAST}    IN  PTR \${HOST}.\${LOCAL_DOMAIN}." >> "\$REVERSE_ZONE_FILE"
  echo -e "\${GREEN}[INFO]\${NC}  Added PTR record: \${LAST} → \${HOST}.\${LOCAL_DOMAIN}"
fi

# Validate and reload
named-checkzone "\$LOCAL_DOMAIN" "\$FORWARD_ZONE" > /dev/null || { echo -e "\${RED}[ERROR]\${NC} Zone validation failed — changes not applied."; exit 1; }
rndc reload > /dev/null
echo -e "\${GREEN}[INFO]\${NC}  BIND9 reloaded."
HELPER
chmod +x /usr/local/bin/dns-add
info "dns-add helper installed at /usr/local/bin/dns-add"

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║                    Done!                             ║"
echo "╚══════════════════════════════════════════════════════╝"
echo ""
info "BIND9 is running and configured."
echo ""
echo "  Local domain:   ${LOCAL_DOMAIN}"
echo "  Server IP:      ${SERVER_IP}"
echo "  Subnet:         ${LOCAL_SUBNET}"
echo "  Forwarders:     ${FORWARDERS[*]}"
echo ""
info "Point your devices/router DNS to: ${SERVER_IP}"
echo ""
info "Useful commands:"
echo "  Add a record:       dns-add <hostname> <ip>"
echo "  Check BIND status:  systemctl status ${BIND_SVC}"
echo "  Reload after edits: rndc reload"
echo "  Test resolution:    dig @${SERVER_IP} hostname.${LOCAL_DOMAIN}"
echo "  Check config:       named-checkconf && named-checkzone ${LOCAL_DOMAIN} /etc/bind/zones/db.${LOCAL_DOMAIN}"
echo "  View logs:          journalctl -u ${BIND_SVC} -f"
echo ""
info "Zone files:         /etc/bind/zones/"
info "Log saved to:       $LOGFILE"
echo ""