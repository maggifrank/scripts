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

# ── Site defaults ─────────────────────────────────────────────────────────────
IP_PREFIX="10.100.53"          # subnet scanned for a free address
IP_SCAN_START=20               # first host octet to consider
IP_MASK=24                     # default prefix length when none is given
DEFAULT_GATEWAY="10.100.53.254"
DEFAULT_DNS="10.100.53.34 10.100.53.41"
DEFAULT_SEARCHDOMAIN="talva.is"

# ── Prompt helpers ────────────────────────────────────────────────────────────
# Ask for a whole number, re-prompting until it is valid.
# Usage: ask_int <varname> <prompt> <default> <min> <max>
ask_int() {
  local __var="$1" __prompt="$2" __default="$3" __min="$4" __max="$5" __input
  while true; do
    read -rp "${__prompt} [default: ${__default}]: " __input
    __input=${__input:-$__default}
    if [[ "$__input" =~ ^[0-9]+$ ]] && [ "$__input" -ge "$__min" ] && [ "$__input" -le "$__max" ]; then
      printf -v "$__var" '%s' "$__input"
      return 0
    fi
    warn "Enter a whole number between ${__min} and ${__max}."
  done
}

# Numbered menu over MENU_VALUES (what gets used) and MENU_LABELS (what is shown).
# Accepts a list number or an exact value; re-prompts on anything else.
# Usage: MENU_VALUES=(...); MENU_LABELS=(...); choose_from_menu <varname> <prompt> <preferred-default>
choose_from_menu() {
  local __var="$1" __prompt="$2" __preferred="$3" __i __choice __default=1
  for __i in "${!MENU_VALUES[@]}"; do
    [ "${MENU_VALUES[$__i]}" = "$__preferred" ] && __default=$((__i+1))
  done
  for __i in "${!MENU_LABELS[@]}"; do
    echo -e "  ${CYAN}$((__i+1)))${NC} ${MENU_LABELS[$__i]}"
  done
  echo ""
  while true; do
    read -rp "${__prompt} [1-${#MENU_VALUES[@]}, default: ${__default} = ${MENU_VALUES[$((__default-1))]}]: " __choice
    __choice=${__choice:-$__default}
    if [[ "$__choice" =~ ^[0-9]+$ ]] && [ "$__choice" -ge 1 ] && [ "$__choice" -le "${#MENU_VALUES[@]}" ]; then
      printf -v "$__var" '%s' "${MENU_VALUES[$((__choice-1))]}"
      return 0
    fi
    for __i in "${MENU_VALUES[@]}"; do
      if [ "$__choice" = "$__i" ]; then
        printf -v "$__var" '%s' "$__i"
        return 0
      fi
    done
    warn "Invalid selection. Enter a number from the list, or an exact name."
  done
}

# First address at or after ${IP_PREFIX}.${IP_SCAN_START} that is absent from the
# host's neighbour/ARP table, is not a local address or the gateway, and does not
# answer a ping.
# Prints nothing and returns 1 if the range is exhausted.
suggest_next_ip() {
  local used candidate i
  used=$(
    {
      ip -4 neigh show 2>/dev/null | awk '$NF != "FAILED" && $NF != "INCOMPLETE" {print $1}'
      arp -an 2>/dev/null | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}'
      ip -4 -o addr show 2>/dev/null | awk '{print $4}' | cut -d/ -f1
      echo "$DEFAULT_GATEWAY"
    } | sort -u
  )
  for ((i = IP_SCAN_START; i <= 254; i++)); do
    candidate="${IP_PREFIX}.${i}"
    if grep -qxF "$candidate" <<<"$used"; then
      continue
    fi
    if ping -c 1 -W 1 "$candidate" >/dev/null 2>&1; then
      continue
    fi
    printf '%s' "$candidate"
    return 0
  done
  return 1
}

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

# Only list storage that can actually hold a container rootfs
mapfile -t STORAGE_ROWS < <(pvesm status --content rootdir 2>/dev/null | awk 'NR>1 {print $1"|"$2"|"$3}')

if [ "${#STORAGE_ROWS[@]}" -eq 0 ]; then
  warn "No storage pools reporting support for container disks (content type: rootdir)."
  read -rp "Storage pool for container disk [default: local-lvm]: " STORAGE
  STORAGE=${STORAGE:-local-lvm}
else
  MENU_VALUES=()
  MENU_LABELS=()
  for row in "${STORAGE_ROWS[@]}"; do
    sname="${row%%|*}"
    srest="${row#*|}"
    MENU_VALUES+=("$sname")
    MENU_LABELS+=("${sname} (${srest%%|*}, ${srest#*|})")
  done
  info "Available storage pools:"
  choose_from_menu STORAGE "Select storage" "local-lvm"
fi
info "Storage: $STORAGE"

# ── Step 5: Resources ─────────────────────────────────────────────────────────
step "5. Resources"
HOST_CORES=$(nproc 2>/dev/null || echo 128)
ask_int DISK  "Disk size in GB" 8 1 65536
ask_int RAM   "RAM in MB" 512 16 1048576
ask_int SWAP  "Swap in MB" 512 0 1048576
ask_int CORES "CPU cores" 1 1 "$HOST_CORES"

# ── Step 6: Network ───────────────────────────────────────────────────────────
step "6. Network"

# Linux bridges expose /sys/class/net/<if>/bridge; OVS bridges do not
mapfile -t BRIDGES < <(
  {
    for d in /sys/class/net/*; do
      if [ -d "$d/bridge" ]; then
        basename "$d"
      fi
    done
    if command -v ovs-vsctl >/dev/null 2>&1; then
      ovs-vsctl list-br 2>/dev/null || true
    fi
  } | sort -u
)

if [ "${#BRIDGES[@]}" -eq 0 ]; then
  warn "No network bridges detected on this host."
  read -rp "Network bridge [default: vmbr0]: " BRIDGE
  BRIDGE=${BRIDGE:-vmbr0}
else
  MENU_VALUES=("${BRIDGES[@]}")
  MENU_LABELS=("${BRIDGES[@]}")
  info "Available network bridges:"
  choose_from_menu BRIDGE "Select bridge" "vmbr0"
fi
info "Bridge: $BRIDGE"

echo ""
echo -e "  ${CYAN}1)${NC} DHCP"
echo -e "  ${CYAN}2)${NC} Static IP"
echo ""
read -rp "IP configuration [1-2, default: 1]: " IPCHOICE
IPCHOICE=${IPCHOICE:-1}

if [ "$IPCHOICE" = "2" ]; then
  info "Looking for a free address in ${IP_PREFIX}.0/${IP_MASK} from .${IP_SCAN_START} up..."
  SUGGESTED_IP=$(suggest_next_ip || true)
  if [ -n "$SUGGESTED_IP" ]; then
    info "Next free address: ${SUGGESTED_IP}"
  else
    warn "No free address found — enter one manually."
  fi

  while true; do
    if [ -n "$SUGGESTED_IP" ]; then
      read -rp "IP address [default: ${SUGGESTED_IP}/${IP_MASK}]: " STATIC_IP
      STATIC_IP=${STATIC_IP:-${SUGGESTED_IP}/${IP_MASK}}
    else
      read -rp "IP address (e.g. ${IP_PREFIX}.50/${IP_MASK}): " STATIC_IP
    fi
    # A bare address gets the default prefix length
    if [[ "$STATIC_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
      STATIC_IP="${STATIC_IP}/${IP_MASK}"
    fi
    [[ "$STATIC_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]] && break
    warn "Invalid format. Use ${IP_PREFIX}.50 or ${IP_PREFIX}.50/${IP_MASK}"
  done

  while true; do
    read -rp "Gateway [default: ${DEFAULT_GATEWAY}]: " GATEWAY
    GATEWAY=${GATEWAY:-$DEFAULT_GATEWAY}
    [[ "$GATEWAY" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] && break
    warn "Invalid IP address."
  done
  NET_CONFIG="ip=${STATIC_IP},gw=${GATEWAY}"
else
  NET_CONFIG="ip=dhcp"
fi

while true; do
  read -rp "DNS servers, space separated [default: ${DEFAULT_DNS}]: " DNS
  DNS=${DNS:-$DEFAULT_DNS}
  IFS=' ' read -ra DNS_LIST <<<"$DNS"
  DNS_OK=1
  for d in "${DNS_LIST[@]}"; do
    [[ "$d" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || DNS_OK=0
  done
  [ "$DNS_OK" = "1" ] && [ "${#DNS_LIST[@]}" -ge 1 ] && break
  warn "Enter one or more IPv4 addresses separated by spaces."
done

read -rp "Search domain [default: ${DEFAULT_SEARCHDOMAIN}, '-' for none]: " SEARCHDOMAIN
SEARCHDOMAIN=${SEARCHDOMAIN:-$DEFAULT_SEARCHDOMAIN}
[ "$SEARCHDOMAIN" = "-" ] && SEARCHDOMAIN=""

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
echo "  Search dom.: ${SEARCHDOMAIN:-(none)}"
echo "  Unprivileged: $( [ "$UNPRIVILEGED" = "1" ] && echo "yes" || echo "no")"
echo "  Nesting:     $( [ "$NESTING_FLAG" = "1" ] && echo "yes" || echo "no")"
echo ""
read -rp "Create container? [y/N]: " FINAL_CONFIRM
[ "${FINAL_CONFIRM,,}" = "y" ] || { echo "Aborted."; exit 0; }

# ── Create container ──────────────────────────────────────────────────────────
step "Creating container"

# Write SSH key to temp file if provided. The trap covers an early exit from a
# failed pct create, which would otherwise leave the file behind.
TMPKEY=""
cleanup() {
  [ -n "${TMPKEY:-}" ] && rm -f "$TMPKEY"
  return 0
}
trap cleanup EXIT

if [ -n "${SSH_PUBKEY:-}" ]; then
  TMPKEY=$(mktemp /tmp/lxc-pubkey-XXXXXX)
  chmod 600 "$TMPKEY"
  echo "$SSH_PUBKEY" > "$TMPKEY"
fi

# Note: --password is deliberately not used. It would put the root password in
# the process table for anyone running ps. It is set over stdin after boot.
PCT_ARGS=(
  "$VMID" "$TEMPLATE"
  --hostname "$HOSTNAME"
  --storage "$STORAGE"
  --rootfs "${STORAGE}:${DISK}"
  --memory "$RAM"
  --swap "$SWAP"
  --cores "$CORES"
  --net0 "name=eth0,bridge=${BRIDGE},${NET_CONFIG}"
  --nameserver "$DNS"
  --unprivileged "$UNPRIVILEGED"
  --features "nesting=${NESTING_FLAG}"
  --start 1
  --onboot 1
)
if [ -n "$SEARCHDOMAIN" ]; then
  PCT_ARGS+=(--searchdomain "$SEARCHDOMAIN")
fi
if [ -n "$TMPKEY" ]; then
  PCT_ARGS+=(--ssh-public-keys "$TMPKEY")
fi

pct create "${PCT_ARGS[@]}"

cleanup
TMPKEY=""

info "Container $VMID created."

# ── Wait for container to start ───────────────────────────────────────────────
info "Waiting for container to start..."
sleep 3
CT_RUNNING=0
for i in {1..10}; do
  if pct status "$VMID" | grep -q "running"; then
    CT_RUNNING=1
    break
  fi
  sleep 2
done
if [ "$CT_RUNNING" = "1" ]; then
  info "Container is running."
else
  warn "Container may not have started — check: pct status $VMID"
fi

# ── Set root password ─────────────────────────────────────────────────────────
# Fed to chpasswd on stdin: printf is a builtin, so the password never reaches
# another process's argv and is never written to disk.
step "Setting root password"
PW_SET=0
if [ "$CT_RUNNING" = "1" ]; then
  for i in {1..5}; do
    if printf 'root:%s\n' "$ROOT_PASS" | pct exec "$VMID" -- chpasswd 2>/dev/null; then
      PW_SET=1
      break
    fi
    sleep 2
  done
fi
unset ROOT_PASS
if [ "$PW_SET" = "1" ]; then
  info "Root password set."
else
  warn "Could not set the root password — set it manually: pct exec $VMID -- passwd root"
fi


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