#!/bin/bash
# allssh.sh — Install allssh + allssh-add and set up hosts file
# Invoked by install.sh from the homelab script menu

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC}  $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

INSTALL_DIR="/usr/local/bin"
HOSTS_FILE="${HOME}/.allssh_hosts"

# ── Write allssh binary ───────────────────────────────────────────────────────
info "Installing allssh..."
cat > "${INSTALL_DIR}/allssh" << 'EOF'
#!/usr/bin/env bash
# allssh — run a command on multiple servers
# Usage: allssh [-f hosts_file] [-p] [-u user] [-i identity] [-t timeout] <command>

set -uo pipefail

# ── Defaults ────────────────────────────────────────────────────────────────
HOSTS_FILE="${ALLSSH_HOSTS:-$HOME/.allssh_hosts}"
PARALLEL=false
SSH_USER="${ALLSSH_USER:-}"
SSH_IDENTITY="${ALLSSH_IDENTITY:-}"
TIMEOUT=10
COMMAND=""

# ── Colours ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

# ── Help ─────────────────────────────────────────────────────────────────────
usage() {
  cat <<HELP
${BOLD}allssh${RESET} — run a command on multiple servers

${BOLD}Usage:${RESET}
  allssh [options] <command>

${BOLD}Options:${RESET}
  -f <file>       Hosts file (default: ~/.allssh_hosts or \$ALLSSH_HOSTS)
  -p              Parallel execution (default: sequential)
  -u <user>       SSH user (default: current user or \$ALLSSH_USER)
  -i <identity>   SSH identity file (default: \$ALLSSH_IDENTITY)
  -t <seconds>    Connection timeout (default: 10)
  -h              Show this help

${BOLD}Hosts file format:${RESET}
  One host per line. Lines starting with # are ignored.
  Optionally override user per host:  user@hostname
  Example:
    server1.example.com
    admin@server2.example.com
    # this line is ignored
    192.168.1.50

${BOLD}Environment variables:${RESET}
  ALLSSH_HOSTS      Default hosts file path
  ALLSSH_USER       Default SSH user
  ALLSSH_IDENTITY   Default SSH identity file
HELP
  exit 0
}

# ── Argument parsing ──────────────────────────────────────────────────────────
while getopts ":f:pu:i:t:h" opt; do
  case $opt in
    f) HOSTS_FILE="$OPTARG" ;;
    p) PARALLEL=true ;;
    u) SSH_USER="$OPTARG" ;;
    i) SSH_IDENTITY="$OPTARG" ;;
    t) TIMEOUT="$OPTARG" ;;
    h) usage ;;
    :) echo -e "${RED}Error:${RESET} Option -$OPTARG requires an argument." >&2; exit 1 ;;
    \?) echo -e "${RED}Error:${RESET} Unknown option -$OPTARG." >&2; exit 1 ;;
  esac
done
shift $((OPTIND - 1))

COMMAND="$*"

# ── Validation ────────────────────────────────────────────────────────────────
if [[ -z "$COMMAND" ]]; then
  echo -e "${RED}Error:${RESET} No command specified." >&2
  echo "Run 'allssh -h' for usage." >&2
  exit 1
fi

if [[ ! -f "$HOSTS_FILE" ]]; then
  echo -e "${RED}Error:${RESET} Hosts file not found: $HOSTS_FILE" >&2
  echo "Create it or specify one with -f." >&2
  exit 1
fi

# Read hosts (strip comments and blank lines)
mapfile -t HOSTS < <(grep -v '^\s*#' "$HOSTS_FILE" | grep -v '^\s*$' | sed 's/\s*#.*//')

if [[ ${#HOSTS[@]} -eq 0 ]]; then
  echo -e "${YELLOW}Warning:${RESET} No hosts found in $HOSTS_FILE" >&2
  exit 0
fi

# ── SSH options ───────────────────────────────────────────────────────────────
SSH_OPTS=(
  -o "ConnectTimeout=$TIMEOUT"
  -o "BatchMode=no"
  -o "StrictHostKeyChecking=accept-new"
  -o "PasswordAuthentication=yes"
)
[[ -n "$SSH_IDENTITY" ]] && SSH_OPTS+=(-i "$SSH_IDENTITY")

# Build target: prepend user@ if -u was given and host doesn't already have one
build_target() {
  local host="$1"
  if [[ -n "$SSH_USER" && "$host" != *@* ]]; then
    echo "${SSH_USER}@${host}"
  else
    echo "$host"
  fi
}

# ── Run on one host ───────────────────────────────────────────────────────────
run_on_host() {
  local host="$1"
  local target
  target=$(build_target "$host")
  local output exit_code

  output=$(ssh "${SSH_OPTS[@]}" "$target" "$COMMAND" 2>&1)
  exit_code=$?

  if [[ $exit_code -eq 0 ]]; then
    echo -e "${GREEN}✔ ${BOLD}${host}${RESET}"
  else
    echo -e "${RED}✘ ${BOLD}${host}${RESET} (exit $exit_code)"
  fi

  while IFS= read -r line; do
    echo -e "  ${CYAN}│${RESET} $line"
  done <<< "$output"
  echo ""

  return $exit_code
}

# ── Summary tracking ──────────────────────────────────────────────────────────
TOTAL=${#HOSTS[@]}
SUCCESS=0
FAILED=0
declare -a FAILED_HOSTS=()

# ── Execute ───────────────────────────────────────────────────────────────────
mode_label="sequential"
$PARALLEL && mode_label="parallel"

echo -e "${BOLD}Running on $TOTAL host(s) [$mode_label]:${RESET} $COMMAND"
echo -e "${BOLD}Hosts file:${RESET} $HOSTS_FILE"
echo ""

if $PARALLEL; then
  tmpdir=$(mktemp -d)
  trap 'rm -rf "$tmpdir"' EXIT

  for host in "${HOSTS[@]}"; do
    (
      run_on_host "$host"
      rc=$?
      echo $rc > "$tmpdir/${host//\//_}.exit"
    ) &
  done
  wait

  for host in "${HOSTS[@]}"; do
    code_file="$tmpdir/${host//\//_}.exit"
    if [[ -f "$code_file" ]]; then
      code=$(<"$code_file")
      if [[ "$code" -eq 0 ]]; then
        ((SUCCESS++))
      else
        ((FAILED++))
        FAILED_HOSTS+=("$host")
      fi
    else
      ((FAILED++))
      FAILED_HOSTS+=("$host")
    fi
  done

else
  for host in "${HOSTS[@]}"; do
    if run_on_host "$host"; then
      ((SUCCESS++))
    else
      ((FAILED++))
      FAILED_HOSTS+=("$host")
    fi
  done
fi

# ── Summary ───────────────────────────────────────────────────────────────────
echo -e "${BOLD}─────────────────────────────────────────${RESET}"
echo -e "${BOLD}Summary:${RESET} $TOTAL hosts — ${GREEN}$SUCCESS succeeded${RESET}, ${RED}$FAILED failed${RESET}"

if [[ ${#FAILED_HOSTS[@]} -gt 0 ]]; then
  echo -e "${RED}Failed hosts:${RESET}"
  for h in "${FAILED_HOSTS[@]}"; do
    echo -e "  • $h"
  done
  exit 1
fi

exit 0
EOF
chmod +x "${INSTALL_DIR}/allssh"
info "Installed ${INSTALL_DIR}/allssh"

# ── Write allssh-add binary ───────────────────────────────────────────────────
info "Installing allssh-add..."
cat > "${INSTALL_DIR}/allssh-add" << 'EOF'
#!/usr/bin/env bash
# allssh-add — add a host to the allssh hosts file
# Usage: allssh-add [user@]hostname

set -uo pipefail

HOSTS_FILE="${ALLSSH_HOSTS:-$HOME/.allssh_hosts}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

usage() {
  cat <<HELP
${BOLD}allssh-add${RESET} — add a host to the allssh hosts file

${BOLD}Usage:${RESET}
  allssh-add [user@]hostname
  allssh-add            (interactive prompt)

${BOLD}Options:${RESET}
  -f <file>   Hosts file (default: ~/.allssh_hosts or \$ALLSSH_HOSTS)
  -h          Show this help
HELP
  exit 0
}

while getopts ":f:h" opt; do
  case $opt in
    f) HOSTS_FILE="$OPTARG" ;;
    h) usage ;;
    :) echo -e "${RED}Error:${RESET} Option -$OPTARG requires an argument." >&2; exit 1 ;;
    \?) echo -e "${RED}Error:${RESET} Unknown option -$OPTARG." >&2; exit 1 ;;
  esac
done
shift $((OPTIND - 1))

if [[ ! -f "$HOSTS_FILE" ]]; then
  mkdir -p "$(dirname "$HOSTS_FILE")"
  touch "$HOSTS_FILE"
  echo -e "${YELLOW}Created hosts file:${RESET} $HOSTS_FILE"
fi

add_host() {
  local host="$1"
  host=$(echo "$host" | xargs)
  [[ -z "$host" ]] && { echo -e "${RED}Error:${RESET} Empty host." >&2; return 1; }

  if grep -qF "$host" "$HOSTS_FILE" 2>/dev/null; then
    echo -e "${YELLOW}Already exists:${RESET} $host"
  else
    echo "$host" >> "$HOSTS_FILE"
    echo -e "${GREEN}✔ Added:${RESET} $host"
  fi
}

if [[ $# -gt 0 ]]; then
  for host in "$@"; do
    add_host "$host"
  done
else
  echo -e "${BOLD}allssh-add${RESET} — hosts file: ${CYAN}${HOSTS_FILE}${RESET}"
  echo -e "Format: ${CYAN}hostname${RESET} or ${CYAN}user@hostname${RESET}"
  echo -e "Leave blank and press Enter when done."
  echo ""
  while true; do
    read -rp "  Host (or blank to finish): " HOST
    [[ -z "$HOST" ]] && break
    add_host "$HOST"
  done
fi

echo ""
echo -e "${BOLD}Current hosts in ${HOSTS_FILE}:${RESET}"
grep -v '^\s*#' "$HOSTS_FILE" | grep -v '^\s*$' | while IFS= read -r line; do
  echo -e "  ${CYAN}•${RESET} $line"
done
EOF
chmod +x "${INSTALL_DIR}/allssh-add"
info "Installed ${INSTALL_DIR}/allssh-add"

# ── SSH key ───────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}── SSH Key ──────────────────────────────────────────────${NC}"

KEY_PATH="${HOME}/.ssh/id_ed25519"
if [[ -f "$KEY_PATH" ]]; then
  info "SSH key already exists at ${KEY_PATH} — skipping generation."
else
  read -rp "Generate a new ed25519 SSH key for allssh? [Y/n]: " GEN_KEY
  if [[ "${GEN_KEY,,}" != "n" ]]; then
    mkdir -p "${HOME}/.ssh"
    chmod 700 "${HOME}/.ssh"
    ssh-keygen -t ed25519 -C "allssh" -f "$KEY_PATH"
    info "Key generated: ${KEY_PATH}"
  else
    warn "Skipping key generation. Make sure your SSH key is configured."
  fi
fi

if [[ -f "${KEY_PATH}.pub" ]]; then
  echo ""
  echo -e "${CYAN}Your public key (copy this to remote servers):${NC}"
  echo ""
  cat "${KEY_PATH}.pub"
  echo ""
fi

# ── Hosts file ────────────────────────────────────────────────────────────────
echo -e "${BOLD}── Hosts File ───────────────────────────────────────────${NC}"

if [[ -f "$HOSTS_FILE" ]]; then
  warn "Hosts file already exists at ${HOSTS_FILE}"
  read -rp "Add more hosts to it? [Y/n]: " ADD_MORE
  if [[ "${ADD_MORE,,}" == "n" ]]; then
    info "Keeping existing hosts file."
  else
    ADD_HOSTS=true
  fi
else
  info "Creating hosts file at ${HOSTS_FILE}"
  touch "$HOSTS_FILE"
  ADD_HOSTS=true
fi

if [[ "${ADD_HOSTS:-false}" == "true" ]]; then
  echo ""
  echo -e "Enter hostnames or IPs to add (one per line)."
  echo -e "Format: ${CYAN}hostname${NC} or ${CYAN}user@hostname${NC}"
  echo -e "Leave blank and press Enter when done."
  echo ""
  while true; do
    read -rp "  Host (or blank to finish): " HOST
    [[ -z "$HOST" ]] && break
    if grep -qF "$HOST" "$HOSTS_FILE" 2>/dev/null; then
      warn "${HOST} is already in the hosts file — skipping."
    else
      echo "$HOST" >> "$HOSTS_FILE"
      info "Added: ${HOST}"
    fi
  done
fi

# ── Default user ──────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}── Default SSH User ─────────────────────────────────────${NC}"
echo ""
read -rp "Set a default SSH user for allssh? (leave blank to skip): " DEFAULT_USER

if [[ -n "$DEFAULT_USER" ]]; then
  PROFILE="${HOME}/.bashrc"
  if grep -q "ALLSSH_USER" "$PROFILE" 2>/dev/null; then
    warn "ALLSSH_USER already set in ${PROFILE} — skipping."
  else
    echo "" >> "$PROFILE"
    echo "# allssh default user" >> "$PROFILE"
    echo "export ALLSSH_USER=\"${DEFAULT_USER}\"" >> "$PROFILE"
    info "Added ALLSSH_USER=${DEFAULT_USER} to ${PROFILE}"
    info "Run 'source ~/.bashrc' or open a new shell to apply."
  fi
fi

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}${BOLD}✔ allssh setup complete!${NC}"
echo ""
echo -e "  Hosts file:  ${CYAN}${HOSTS_FILE}${NC}"
echo -e "  Add hosts:   ${CYAN}allssh-add <host>${NC}"
echo -e "  Run:         ${CYAN}allssh -u root \"uptime\"${NC}"
echo -e "  Parallel:    ${CYAN}allssh -u root -p \"apt-get update -qq && apt-get upgrade -y -qq\"${NC}"
echo ""