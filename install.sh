#!/bin/bash
# install.sh — Magnús's homelab script installer
# One-liner: bash -c "$(curl -fsSL https://raw.githubusercontent.com/maggifrank/scripts/main/install.sh)"

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

info()  { echo -e "${GREEN}[INFO]${NC}  $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# ── Force interactive terminal (required when piped via curl) ─────────────────
[ ! -t 0 ] && exec < /dev/tty

# ── Dependency check ──────────────────────────────────────────────────────────
for cmd in curl bash; do
  command -v "$cmd" &>/dev/null || error "Required command not found: $cmd"
done

# ── Ensure jq is available ────────────────────────────────────────────────────
if ! command -v jq &>/dev/null; then
  info "jq not found — installing..."
  apt-get update -q && apt-get install -y -q jq || error "Failed to install jq. Please install it manually: apt install jq"
fi

# ── Fetch manifest ────────────────────────────────────────────────────────────
MANIFEST=$(curl -fsSL --max-time 10 "$MANIFEST_URL") || error "Could not fetch manifest. Check your internet connection."

# Validate it's valid JSON
echo "$MANIFEST" | jq empty 2>/dev/null || error "Manifest is not valid JSON. Check ${MANIFEST_URL}"

# Count entries
ENTRY_COUNT=$(echo "$MANIFEST" | jq 'length')
[ "$ENTRY_COUNT" -eq 0 ] && error "Manifest is empty."

# ── Parse entries with jq ─────────────────────────────────────────────────────
parse_field() {
  local idx="$1" field="$2"
  echo "$MANIFEST" | jq -r ".[${idx}].${field}"
}

# ── Draw menu ─────────────────────────────────────────────────────────────────
clear
echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║           Homelab Script Installer                   ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════╝${NC}"
echo ""

for ((idx=0; idx<ENTRY_COUNT; idx++)); do
  name=$(parse_field "$idx" "name")
  desc=$(parse_field "$idx" "description")
  root=$(parse_field "$idx" "requires_root")
  num=$((idx + 1))

  root_tag=""
  [ "$root" = "true" ] && root_tag=" ${YELLOW}[root]${NC}"

  echo -e "  ${CYAN}${num})${NC} ${BOLD}${name}${NC}${root_tag}"
  echo -e "     ${desc}"
  echo ""
done

echo -e "  ${CYAN}0)${NC} Exit"
echo ""

# ── Get selection ─────────────────────────────────────────────────────────────
while true; do
  read -rp "Select a script to run [0-${ENTRY_COUNT}]: " CHOICE
  if [[ "$CHOICE" =~ ^[0-9]+$ ]] && [ "$CHOICE" -ge 0 ] && [ "$CHOICE" -le "$ENTRY_COUNT" ]; then
    break
  fi
  warn "Invalid choice. Enter a number between 0 and ${ENTRY_COUNT}."
done

if [ "$CHOICE" -eq 0 ]; then
  echo "Exiting."
  exit 0
fi

# ── Resolve selection (1-indexed → 0-indexed) ─────────────────────────────────
IDX=$((CHOICE - 1))
SELECTED_NAME=$(parse_field "$IDX" "name")
SELECTED_FILE=$(parse_field "$IDX" "file")
SELECTED_ROOT=$(parse_field "$IDX" "requires_root")
SCRIPT_URL="${RAW_BASE}/${SELECTED_FILE}"

echo ""
echo -e "${BLUE}──── Selected: ${SELECTED_NAME} ────${NC}"
echo ""

# ── Root check ────────────────────────────────────────────────────────────────
if [ "$SELECTED_ROOT" = "true" ] && [ "$EUID" -ne 0 ]; then
  warn "This script requires root. Re-launching with sudo..."
  TMPSCRIPT=$(mktemp /tmp/homelab-XXXXXX.sh)
  trap 'shred -u "$TMPSCRIPT" 2>/dev/null || rm -f "$TMPSCRIPT"' EXIT
  curl -fsSL --max-time 30 "$SCRIPT_URL" -o "$TMPSCRIPT" || error "Failed to download script."
  chmod +x "$TMPSCRIPT"
  exec sudo bash "$TMPSCRIPT"
fi

# ── Confirm before running ────────────────────────────────────────────────────
warn "You are about to run:"
echo -e "       ${SCRIPT_URL}"
echo ""
read -rp "Proceed? [y/N]: " CONFIRM
[ "${CONFIRM,,}" = "y" ] || { echo "Aborted."; exit 0; }

# ── Fetch and run ─────────────────────────────────────────────────────────────
echo ""
info "Fetching and running ${SELECTED_NAME}..."
echo ""

TMPSCRIPT=$(mktemp /tmp/homelab-XXXXXX.sh)
trap 'shred -u "$TMPSCRIPT" 2>/dev/null || rm -f "$TMPSCRIPT"' EXIT

curl -fsSL --max-time 30 "$SCRIPT_URL" -o "$TMPSCRIPT" || error "Failed to download script."

chmod +x "$TMPSCRIPT"
bash "$TMPSCRIPT"