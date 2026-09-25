#!/bin/bash
# dns-common.sh — shared functions for the dns-* management scripts
# Source this from other scripts: source /usr/local/bin/dns-common.sh
#
# ASSUMPTION: named.conf.local zone blocks look like the standard Debian
# bind9 layout:
#
#   zone "talva.is" {
#       type master;
#       file "/etc/bind/zones/db.talva.is";
#   };
#
# If your file differs, adjust zone_file_for() below.

ZONES_DIR="/etc/bind/zones"
NAMED_CONF_LOCAL="/etc/bind/named.conf.local"
REVERSE_MAP="${ZONES_DIR}/reverse-map.conf"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error() { echo -e "${RED}[ERROR]${NC} $*"; }

# List forward (non-reverse) zone names declared in named.conf.local
list_zones() {
  grep -oP 'zone\s+"\K[^"]+' "$NAMED_CONF_LOCAL" 2>/dev/null | grep -v 'in-addr\.arpa$' | sort -u
}

# Resolve which zone to operate on.
# Usage: ZONE=$(select_zone "$MAYBE_ZONE_ARG")
# - If a zone was passed in, use it as-is (no validation of existence here;
#   callers should validate via zone_file_for()).
# - If none was passed and only one zone exists, auto-pick it.
# - Otherwise, prompt interactively.
select_zone() {
  local preselected="$1"
  if [ -n "$preselected" ]; then
    echo "$preselected"
    return 0
  fi

  local zones=()
  while IFS= read -r line; do
    [ -n "$line" ] && zones+=("$line")
  done < <(list_zones)

  if [ "${#zones[@]}" -eq 0 ]; then
    error "No zones found in $NAMED_CONF_LOCAL." >&2
    exit 1
  fi

  if [ "${#zones[@]}" -eq 1 ]; then
    echo "${zones[0]}"
    return 0
  fi

  echo "Which zone?" >&2
  local i=1
  for z in "${zones[@]}"; do
    echo "  $i) $z" >&2
    i=$((i+1))
  done

  local choice
  read -rp "Zone [1-${#zones[@]}]: " choice

  if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt "${#zones[@]}" ]; then
    error "Invalid selection." >&2
    exit 1
  fi

  echo "${zones[$((choice-1))]}"
}

# Given a zone name, print the forward zone file path from named.conf.local
zone_file_for() {
  local zone="$1"
  awk -v z="\"$zone\"" '
    $1=="zone" && $2==z {f=1; next}
    f && $1=="file" {
      gsub(/[";]/,"",$2)
      print $2
      exit
    }
    f && $0 ~ /^[[:space:]]*}/ {f=0}
  ' "$NAMED_CONF_LOCAL"
}

# Given an IP, print the reverse zone file that covers its /24, if registered.
# Looks up $REVERSE_MAP, format one entry per line: <network-prefix>:<file-path>
# e.g. 10.100.53:/etc/bind/zones/db.53.100.10.in-addr.arpa
get_reverse_zone_file_for_ip() {
  local ip="$1"
  local prefix
  prefix=$(echo "$ip" | cut -d'.' -f1-3)
  [ -f "$REVERSE_MAP" ] || return 0
  awk -F: -v p="$prefix" '$1==p {print $2; exit}' "$REVERSE_MAP"
}

# Remove a whole "zone "name" { ... };" block from named.conf.local in place.
# Backs up named.conf.local first (timestamped) and echoes the backup path.
# Assumes no nested braces inside the block (true for standard zone stanzas).
remove_zone_stanza() {
  local zone="$1"
  local backup="${NAMED_CONF_LOCAL}.bak.$(date +%Y%m%d%H%M%S)"
  cp "$NAMED_CONF_LOCAL" "$backup"

  awk -v z="\"$zone\"" '
    $1=="zone" && $2==z { skip=1; next }
    skip {
      if ($0 ~ /^[[:space:]]*};/) { skip=0 }
      next
    }
    { print }
  ' "$NAMED_CONF_LOCAL" > "${NAMED_CONF_LOCAL}.tmp"

  mv "${NAMED_CONF_LOCAL}.tmp" "$NAMED_CONF_LOCAL"
  echo "$backup"
}

# --- Forward/reverse zone pairing ------------------------------------------
# dns-add-zone records which reverse zone (and network prefix) goes with a
# forward zone here, so dns-remove-zone can find and remove it automatically
# without the network-prefix being passed again.
ZONE_PAIRS="${ZONES_DIR}/zone-pairs.conf"

# Record a pairing: <forward-zone>:<reverse-zone>:<network-prefix>
record_zone_pair() {
  local zone="$1" reverse_zone="$2" prefix="$3"
  echo "${zone}:${reverse_zone}:${prefix}" >> "$ZONE_PAIRS"
}

# Print "reverse-zone:network-prefix" for a forward zone, if a pairing exists.
zone_pair_for() {
  local zone="$1"
  [ -f "$ZONE_PAIRS" ] || return 0
  awk -F: -v z="$zone" '$1==z {print $2":"$3; exit}' "$ZONE_PAIRS"
}

# Drop a forward zone's pairing entry.
remove_zone_pair() {
  local zone="$1"
  [ -f "$ZONE_PAIRS" ] || return 0
  sed -i "/^${zone}:/d" "$ZONE_PAIRS"
}

# --- Secondary (edge01) replication helpers ---------------------------------
# These SSH out to the secondary DNS server to keep it in sync as a slave.
# We do NOT ssh as root and do NOT grant broad sudo access. Instead, edge01
# runs a small wrapper (dns-slave-apply, deployed there separately) that only
# adds/removes a slave zone stanza, validates, and reloads — and the SSH user
# is granted sudo rights to invoke *only that script*, nothing else:
#
#   # /etc/sudoers.d/dns-slave-apply on edge01
#   magnus ALL=(root) NOPASSWD: /usr/local/bin/dns-slave-apply
#
# Override any of these by exporting the var before calling a script, or via
# each script's own flags where offered.
SECONDARY_SSH_ALIAS="${SECONDARY_SSH_ALIAS:-edge01-ssh}"
SECONDARY_ZONES_DIR="${SECONDARY_ZONES_DIR:-/var/cache/bind}"
SECONDARY_APPLY_CMD="${SECONDARY_APPLY_CMD:-/usr/local/bin/dns-slave-apply}"

secondary_ssh_ok() {
  ssh -o BatchMode=yes -o ConnectTimeout=5 "$SECONDARY_SSH_ALIAS" "true" 2>/dev/null
}

# Print the slave stanza that would be added for a zone (used both to apply
# it remotely and to show it to the user if the SSH push fails).
slave_stanza_for() {
  local zone="$1" file_hint="$2" master_ip="$3"
  echo "zone \"${zone}\" {
    type slave;
    file \"${SECONDARY_ZONES_DIR}/${file_hint}\";
    masters { ${master_ip}; };
};"
}

# Ask edge01 (via sudo -n dns-slave-apply) to add a slave zone and reload.
# Returns 0 on success, 1 if it already exists there (no-op), 2 on failure.
secondary_push_slave_zone() {
  local zone="$1" file_hint="$2" master_ip="$3"
  local out
  out=$(ssh -o BatchMode=yes "$SECONDARY_SSH_ALIAS" \
    "sudo -n ${SECONDARY_APPLY_CMD} add '${zone}' '${file_hint}' '${master_ip}'" 2>&1)
  case "$out" in
    OK) return 0 ;;
    *ALREADY_EXISTS*) return 1 ;;
    *) echo "$out" >&2; return 2 ;;
  esac
}

# Ask edge01 (via sudo -n dns-slave-apply) to remove a slave zone and reload.
# Returns 0 (echoes remote backup path) on success, 1 if not found, 2 on failure.
secondary_remove_slave_zone() {
  local zone="$1"
  local out
  out=$(ssh -o BatchMode=yes "$SECONDARY_SSH_ALIAS" \
    "sudo -n ${SECONDARY_APPLY_CMD} remove '${zone}'" 2>&1)
  case "$out" in
    OK*) echo "${out#OK }"; return 0 ;;
    *NOT_FOUND*) return 1 ;;
    *) echo "$out" >&2; return 2 ;;
  esac
}
