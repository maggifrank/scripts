#!/bin/bash
# create-lxc.sh
# Interactive script to create a Proxmox LXC container.
# Must be run on the Proxmox host.

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

# ── Root + Proxmox check ──────────────────────────────────────────────────────
[ "$EUID" -ne 0 ] && error "Please run as root on the Proxmox host."
command -v pct &>/dev/null || error "pct not found — this script must run on the Proxmox host."

echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║              Proxmox LXC Creator                     ║"
echo "╚══════════════════════════════════════════════════════╝"
echo ""

# ── Step 1: Pick next available VMID ─────────────────────────────────────────
step "1. Container ID"
NEXT_ID=$(pvesh get /cluster/nextid)
read -rp "Container ID [default: ${NEXT_ID}]: " VMID
VMID=${VMID:-$NEXT_ID}
if ! [[ "$VMID" =~ ^[0-9]+$ ]] || [ "$VMID" -lt 100 ]; then
  error "Invalid VMID. Must be a number >= 100."
fi
# Check if already in use
pct status "$VMID" &>/dev/null 2>&1 && error "VMID $VMID is already in use."
info "Using VMID: $VMID"

# ── Step 2: Hostname ──────────────────────────────────────────────────────────
step "2. Hostname"
while true; do
  read -rp "Hostname: " HOSTNAME
  if [[ "$HOSTNAME" =~ ^[a-zA-Z0-9]([a-zA-Z0-9\-]{0,61}[a-zA-Z0-9])?$ ]]; then
    break
  fi
  warn "Invalid hostname. Use letters, numbers, and hyphens only."
done

# ── Step 3: Template ──────────────────────────────────────────────────────────
step "3. Template"
info "Available templates:"
pveam list local 2>/dev/null | grep -i "ubuntu\|debian" | awk '{print NR") "$1}' || true

echo ""
info "If your template is not listed, download it first:"
echo "  pveam update && pveam available --section system | grep ubuntu"
echo "  pveam download local ubuntu-24.04-standard_24.04-2_amd64.tar.zst"
echo ""

# List all available templates for selection
mapfile -t TEMPLATES < <(pveam list local 2>/dev/null | grep -i "ubuntu\|debian" | awk '{print $1}')

if [ "${#TEMPLATES[@]}" -eq 0 ]; then
  warn "No Ubuntu/Debian templates found in local storage."
  read -rp "Enter full template path manually (e.g. local:vztmpl/ubuntu-24.04-standard_24.04-2_amd64.tar.zst): " TEMPLATE
else
  for i in "${!TEMPLATES[@]}"; do
    echo -e "  ${CYAN}$((i+1)))${NC} ${TEMPLATES[$i]}"
  done
  echo ""
  while true; do
    read -rp "Select template [1-${#TEMPLATES[@]}] or enter path manually: " TCHOICE
    if [[ "$TCHOICE" =~ ^[0-9]+$ ]] && [ "$TCHOICE" -ge 1 ] && [ "$TCHOICE" -le "${#TEMPLATES[@]}" ]; then
      TEMPLATE="${TEMPLATES[$((TCHOICE-1))]}"
      break
    elif [[ "$TCHOICE" == *"/"* ]]; then
      TEMPLATE="$TCHOICE"
      break
    fi
    warn "Invalid selection."
  done
fi
info "Template: $TEMPLATE"

# ── Step 4: Storage ───────────────────────────────────────────────────────────
step "4. Storage"
info "Available storage pools:"
pvesm status | awk 'NR>1 {print NR-1") "$1" ("$2")"}' || true
echo ""
read -rp "Storage pool for container disk [default: local-lvm]: " STORAGE
STORAGE=${STORAGE:-local-lvm}

# ── Step 5: Resources ─────────────────────────────────────────────────────────
step "5. Resources"
read -rp "Disk size in GB [default: 8]: " DISK
DISK=${DISK:-8}

read -rp "RAM in MB [default: 512]: " RAM
RAM=${RAM:-512}

read -rp "Swap in MB [default: 512]: " SWAP
SWAP=${SWAP:-512}

read -rp "CPU cores [default: 1]: " CORES
CORES=${CORES:-1}

# ── Step 6: Network ───────────────────────────────────────────────────────────
step "6. Network"
read -rp "Network bridge [default: vmbr0]: " BRIDGE
BRIDGE=${BRIDGE:-vmbr0}

echo ""
echo -e "  ${CYAN}1)${NC} DHCP"
echo -e "  ${CYAN}2)${NC} Static IP"
echo ""
read -rp "IP configuration [1-2, default: 1]: " IPCHOICE
IPCHOICE=${IPCHOICE:-1}

if [ "$IPCHOICE" = "2" ]; then
  while true; do
    read -rp "IP address with CIDR (e.g. 10.0.0.50/24): " STATIC_IP
    [[ "$STATIC_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]] && break
    warn "Invalid format. Use CIDR notation e.g. 10.0.0.50/24"
  done
  while true; do
    read -rp "Gateway (e.g. 10.0.0.1): " GATEWAY
    [[ "$GATEWAY" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] && break
    warn "Invalid IP address."
  done
  NET_CONFIG="ip=${STATIC_IP},gw=${GATEWAY}"
else
  NET_CONFIG="ip=dhcp"
fi

read -rp "DNS server [default: 10.100.53.73]: " DNS
DNS=${DNS:-10.100.53.73}

# ── Step 7: Security ──────────────────────────────────────────────────────────
step "7. Security"
echo -e "  ${CYAN}1)${NC} Unprivileged (recommended)"
echo -e "  ${CYAN}2)${NC} Privileged"
echo ""
read -rp "Container type [1-2, default: 1]: " PRIVMODE
PRIVMODE=${PRIVMODE:-1}
[ "$PRIVMODE" = "2" ] && UNPRIVILEGED=0 || UNPRIVILEGED=1

read -rp "Enable nesting? Required for Docker inside LXC [y/N]: " NESTING
NESTING=${NESTING,,}
[ "$NESTING" = "y" ] && NESTING_FLAG=1 || NESTING_FLAG=0

# ── Step 8: Password ──────────────────────────────────────────────────────────
step "8. Root password"
warn "This is the root password for the container console."

# Force interactive terminal — required when script is piped via curl
if [ ! -t 0 ]; then
  exec < /dev/tty
fi

while true; do
  read -rsp "Root password: " ROOT_PASS
  echo ""
  read -rsp "Confirm password: " ROOT_PASS_CONFIRM
  echo ""
  [ "$ROOT_PASS" = "$ROOT_PASS_CONFIRM" ] && break
  warn "Passwords do not match. Try again."
done
unset ROOT_PASS_CONFIRM

[ -z "${ROOT_PASS:-}" ] && error "Password cannot be empty."

# ── Step 9: SSH key (optional) ────────────────────────────────────────────────
step "9. SSH public key (optional)"
read -rp "Paste SSH public key for root (leave blank to skip): " SSH_PUBKEY

# ── Confirm ───────────────────────────────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║                  Review & Confirm                    ║"
echo "╚══════════════════════════════════════════════════════╝"
echo ""
echo "  VMID:        $VMID"
echo "  Hostname:    $HOSTNAME"
echo "  Template:    $TEMPLATE"
echo "  Storage:     $STORAGE"
echo "  Disk:        ${DISK}GB"
echo "  RAM:         ${RAM}MB"
echo "  Swap:        ${SWAP}MB"
echo "  Cores:       $CORES"
echo "  Bridge:      $BRIDGE"
echo "  Network:     $NET_CONFIG"
echo "  DNS:         $DNS"
echo "  Unprivileged: $( [ "$UNPRIVILEGED" = "1" ] && echo "yes" || echo "no")"
echo "  Nesting:     $( [ "$NESTING_FLAG" = "1" ] && echo "yes" || echo "no")"
echo ""
read -rp "Create container? [y/N]: " FINAL_CONFIRM
[ "${FINAL_CONFIRM,,}" = "y" ] || { echo "Aborted."; exit 0; }

# ── Create container ──────────────────────────────────────────────────────────
step "Creating container"

# Write SSH key to temp file if provided
TMPKEY=""
if [ -n "${SSH_PUBKEY:-}" ]; then
  TMPKEY=$(mktemp /tmp/lxc-pubkey-XXXXXX)
  echo "$SSH_PUBKEY" > "$TMPKEY"
fi

# Build and run pct create directly
if [ -n "$TMPKEY" ]; then
  pct create "$VMID" "$TEMPLATE" \
    --hostname "$HOSTNAME" \
    --storage "$STORAGE" \
    --rootfs "${STORAGE}:${DISK}" \
    --memory "$RAM" \
    --swap "$SWAP" \
    --cores "$CORES" \
    --net0 "name=eth0,bridge=${BRIDGE},${NET_CONFIG}" \
    --nameserver "$DNS" \
    --unprivileged "$UNPRIVILEGED" \
    --features "nesting=${NESTING_FLAG}" \
    --password "$ROOT_PASS" \
    --ssh-public-keys "$TMPKEY" \
    --start 1 \
    --onboot 1
else
  pct create "$VMID" "$TEMPLATE" \
    --hostname "$HOSTNAME" \
    --storage "$STORAGE" \
    --rootfs "${STORAGE}:${DISK}" \
    --memory "$RAM" \
    --swap "$SWAP" \
    --cores "$CORES" \
    --net0 "name=eth0,bridge=${BRIDGE},${NET_CONFIG}" \
    --nameserver "$DNS" \
    --unprivileged "$UNPRIVILEGED" \
    --features "nesting=${NESTING_FLAG}" \
    --password "$ROOT_PASS" \
    --start 1 \
    --onboot 1
fi

unset ROOT_PASS
[ -n "$TMPKEY" ] && rm -f "$TMPKEY"

info "Container $VMID created."

# ── Wait for container to start ───────────────────────────────────────────────
info "Waiting for container to start..."
sleep 3
for i in {1..10}; do
  pct status "$VMID" | grep -q "running" && break
  sleep 2
done
pct status "$VMID" | grep -q "running" && info "Container is running." || warn "Container may not have started — check: pct status $VMID"


# ── Bootstrap container ──────────────────────────────────────────────────────────────────────────────
step "Bootstrapping container"
info "Running apt update and installing curl inside container..."

pct exec "$VMID" -- bash -c "
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -q
  apt-get upgrade -y -q
  apt-get install -y -q curl wget
" && info "Bootstrap complete — container is ready to use." || warn "Bootstrap had errors — check inside: pct enter $VMID"

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║                    Done!                             ║"
echo "╚══════════════════════════════════════════════════════╝"
echo ""
info "Container $VMID ($HOSTNAME) is ready."
echo ""
info "Useful commands:"
echo "  Open console:   pct enter $VMID"
echo "  Stop:           pct stop $VMID"
echo "  Start:          pct start $VMID"
echo "  Destroy:        pct destroy $VMID"
echo "  Config:         cat /etc/pve/lxc/${VMID}.conf"
echo ""
if [ "$IPCHOICE" = "1" ]; then
  warn "Container is using DHCP — check your router for the assigned IP."
else
  info "Container IP: $(echo "$STATIC_IP" | cut -d'/' -f1)"
fi
echo ""