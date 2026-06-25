#!/bin/bash
# install.sh — Magnús's homelab script installer
# One-liner: bash -c "$(curl -fsSL https://raw.githubusercontent.com/YOURUSERNAME/YOURREPO/main/install.sh)"

set -euo pipefail

# ── Config ────────────────────────────────────────────────────────────────────
GITHUB_USER="maggifrank"
GITHUB_REPO="scripts"
BRANCH="main"
RAW_BASE="https://raw.githubusercontent.com/${GITHUB_USER}/${GITHUB_REPO}/${BRANCH}/scripts"
MANIFEST_URL="https://raw.githubusercontent.com/${GITHUB_USER}/${GITHUB_REPO}/${BRANCH}/manifest.json"

# ── Colors ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ── Dependency check ──────────────────────────────────────────────────────────
for cmd in curl bash; do
  command -v "$cmd" &>/dev/null || { echo -e "${RED}[ERROR]${NC} Required command not found: $cmd"; exit 1; }
done

# ── Fetch manifest ────────────────────────────────────────────────────────────
MANIFEST=$(curl -fsSL --max-time 10 "$MANIFEST_URL") || {
  echo -e "${RED}[ERROR]${NC} Could not fetch script manifest. Check your internet connection."
  exit 1
}

# Parse manifest with pure bash (no jq dependency)
# Manifest format: [{"name":"...","file":"...","description":"...","requires_root":true}, ...]
parse_field() {
  local json="$1" field="$2"
  echo "$json" | grep -o "\"${field}\":\"[^\"]*\"" | head -1 | cut -d'"' -f4
}

parse_bool() {
  local json="$1" field="$2"
  echo "$json" | grep -o "\"${field}\":[a-z]*" | head -1 | cut -d':' -f2
}

# Split manifest into individual entries
mapfile -t ENTRIES < <(echo "$MANIFEST" | grep -o '{[^}]*}')

if [ "${#ENTRIES[@]}" -eq 0 ]; then
  echo -e "${RED}[ERROR]${NC} Manifest is empty or malformed."
  exit 1
fi

# ── Draw menu ─────────────────────────────────────────────────────────────────
clear
echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║           Homelab Script Installer                   ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════╝${NC}"
echo ""

declare -a SCRIPT_FILES
declare -a SCRIPT_NAMES
declare -a SCRIPT_ROOTS

i=1
for entry in "${ENTRIES[@]}"; do
  name=$(parse_field "$entry" "name")
  file=$(parse_field "$entry" "file")
  desc=$(parse_field "$entry" "description")
  root=$(parse_bool  "$entry" "requires_root")

  SCRIPT_FILES+=("$file")
  SCRIPT_NAMES+=("$name")
  SCRIPT_ROOTS+=("$root")

  root_tag=""
  [ "$root" = "true" ] && root_tag=" ${YELLOW}[root]${NC}"

  echo -e "  ${CYAN}${i})${NC} ${BOLD}${name}${NC}${root_tag}"
  echo -e "     ${desc}"
  echo ""
  ((i++))
done

echo -e "  ${CYAN}0)${NC} Exit"
echo ""

# ── Get selection ─────────────────────────────────────────────────────────────
while true; do
  read -rp "Select a script to run [0-$((i-1))]: " CHOICE
  if [[ "$CHOICE" =~ ^[0-9]+$ ]] && [ "$CHOICE" -ge 0 ] && [ "$CHOICE" -lt "$i" ]; then
    break
  fi
  echo -e "${YELLOW}[WARN]${NC}  Invalid choice. Enter a number between 0 and $((i-1))."
done

if [ "$CHOICE" -eq 0 ]; then
  echo "Exiting."
  exit 0
fi

# ── Resolve selection (1-indexed) ─────────────────────────────────────────────
IDX=$((CHOICE - 1))
SELECTED_FILE="${SCRIPT_FILES[$IDX]}"
SELECTED_NAME="${SCRIPT_NAMES[$IDX]}"
SELECTED_ROOT="${SCRIPT_ROOTS[$IDX]}"
SCRIPT_URL="${RAW_BASE}/${SELECTED_FILE}"

echo ""
echo -e "${BLUE}──── Selected: ${SELECTED_NAME} ────${NC}"
echo ""

# ── Root warning ──────────────────────────────────────────────────────────────
if [ "$SELECTED_ROOT" = "true" ] && [ "$EUID" -ne 0 ]; then
  echo -e "${YELLOW}[WARN]${NC}  This script requires root. Re-launching with sudo..."
  exec sudo bash -c "$(curl -fsSL "$SCRIPT_URL")"
fi

# ── Confirm before running ────────────────────────────────────────────────────
echo -e "${YELLOW}[WARN]${NC}  You are about to run:"
echo -e "       ${SCRIPT_URL}"
echo ""
read -rp "Proceed? [y/N]: " CONFIRM
CONFIRM=${CONFIRM,,}
if [ "$CONFIRM" != "y" ]; then
  echo "Aborted."
  exit 0
fi

# ── Fetch and run ─────────────────────────────────────────────────────────────
echo ""
echo -e "${GREEN}[INFO]${NC}  Fetching and running ${SELECTED_NAME}..."
echo ""

TMPSCRIPT=$(mktemp /tmp/homelab-XXXXXX.sh)
trap 'shred -u "$TMPSCRIPT" 2>/dev/null || rm -f "$TMPSCRIPT"' EXIT

curl -fsSL --max-time 30 "$SCRIPT_URL" -o "$TMPSCRIPT" || {
  echo -e "${RED}[ERROR]${NC} Failed to download script."
  exit 1
}

chmod +x "$TMPSCRIPT"
bash "$TMPSCRIPT"