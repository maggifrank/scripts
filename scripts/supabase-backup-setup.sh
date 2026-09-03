#!/bin/bash
# supabase-backup-setup.sh — install the Supabase backup tool and add a project.
#
# Captures a Supabase project nightly into one timestamped tarball: every user
# schema with data and privileges, the auth identity tables, the schema objects
# pg_dump cannot see (triggers on auth.users, storage policies, bucket
# definitions, pg_cron jobs), and every storage object.
#
# Run it again to add another project — one config file and one timer each.

set -euo pipefail

# ── Config ────────────────────────────────────────────────────────────────────
GITHUB_USER="maggifrank"
GITHUB_REPO="scripts"
BRANCH="main"
RAW_BASE="https://raw.githubusercontent.com/${GITHUB_USER}/${GITHUB_REPO}/${BRANCH}/scripts/supabase-backup"

LIB_DIR="/opt/supabase-backup"
CONF_DIR="/etc/supabase-backup"
DATA_DIR="/var/backups/supabase"
UNIT_DIR="/etc/systemd/system"

# ── Colors ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC}  $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }
step()  { echo -e "\n${BLUE}──── $1 ────${NC}"; }

# ── Root check ────────────────────────────────────────────────────────────────
[ "$(id -u)" -eq 0 ] || error "This script must be run as root."

# ── Force interactive terminal (required when piped via curl) ─────────────────
[ ! -t 0 ] && exec < /dev/tty

echo ""
echo -e "${BOLD}Supabase backup${NC}"
echo ""
echo "  Nightly capture of a Supabase project into one tarball:"
echo "    · every user schema — structure, data and privileges"
echo "    · auth.users and auth.identities, so restored accounts can sign in"
echo "    · triggers, policies, buckets and cron jobs read from the live catalog"
echo "    · every object in every storage bucket"
echo ""
echo "  Everything is derived from the running database. Restoring never needs"
echo "  a migration file from some application's repository."
echo ""
read -rp "Proceed? [y/N]: " CONFIRM
[[ "$CONFIRM" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }

# ── Dependencies ──────────────────────────────────────────────────────────────
step "Dependencies"

MISSING=()
command -v curl >/dev/null || MISSING+=(curl)
command -v jq   >/dev/null || MISSING+=(jq)
command -v psql >/dev/null || MISSING+=(postgresql-client)

if [ ${#MISSING[@]} -gt 0 ]; then
  info "installing: ${MISSING[*]}"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq "${MISSING[@]}" || error "dependency install failed"
fi
info "pg_dump $(pg_dump --version | awk '{print $3}')"

# ── Install the tool ──────────────────────────────────────────────────────────
step "Installing to ${LIB_DIR}"

install -d -m 0755 "$LIB_DIR"
install -d -m 0700 "$CONF_DIR"
install -d -m 0700 "$DATA_DIR"

for f in backup.sh catalog.sql restore; do
  curl -fsSL --max-time 30 "${RAW_BASE}/${f}" -o "${LIB_DIR}/${f}" \
    || error "could not download ${f} from ${RAW_BASE}"
done
chmod 0755 "${LIB_DIR}/backup.sh" "${LIB_DIR}/restore"
chmod 0644 "${LIB_DIR}/catalog.sql"

# On PATH as supabase-restore. Note that the Proxmox LXC console starts bash
# without /etc/profile, so /usr/local/bin can be missing from PATH there even
# though an SSH login has it.
ln -sf "${LIB_DIR}/restore" /usr/local/bin/supabase-restore

for f in "supabase-backup@.service" "supabase-backup@.timer"; do
  curl -fsSL --max-time 30 "${RAW_BASE}/${f}" -o "${UNIT_DIR}/${f}" \
    || error "could not download ${f}"
  chmod 0644 "${UNIT_DIR}/${f}"
done
systemctl daemon-reload
info "tool and systemd templates installed"

# ── Project details ───────────────────────────────────────────────────────────
step "Add a project"

while :; do
  read -rp "Short name for this project (e.g. 'billing', 'crm'): " PROJECT
  [[ "$PROJECT" =~ ^[a-z0-9][a-z0-9_-]*$ ]] || { warn "lowercase letters, digits, - and _ only"; continue; }
  if [ -f "${CONF_DIR}/${PROJECT}.conf" ]; then
    read -rp "  ${PROJECT} already exists. Overwrite its config? [y/N]: " OW
    [[ "$OW" =~ ^[Yy]$ ]] || continue
  fi
  break
done

echo ""
echo "  From the Supabase dashboard for this project:"
echo "    Connect → Direct tab → Session pooler   (port 5432, NOT 6543)"
echo ""
echo "  Transaction mode (6543) does not hold a session across statements and"
echo "  pg_dump fails partway through. If the password contains @ : / ? # [ ] %"
echo "  it must be percent-encoded, or the URI parses wrong and you get a"
echo "  confusing hostname error instead of an auth error."
echo ""

read -rp  "Session pooler URI: " DATABASE_URL
read -rp  "Project URL (https://<ref>.supabase.co): " SUPABASE_URL
read -rsp "Service key (hidden): " SUPABASE_SERVICE_KEY; echo
read -rp  "Keep archives for how many days? [30]: " KEEP_DAYS
KEEP_DAYS="${KEEP_DAYS:-30}"

[[ "$DATABASE_URL" == *":5432/"* ]] || warn "URI is not on port 5432 — transaction mode will fail partway"

# Both credentials must name the same project. A mismatched pair silently
# dumps one project's Postgres while reading another's storage.
ref_of() { sed -E 's|.*://(postgres\.)?([a-z0-9]+)[.:/].*|\2|' <<<"$1"; }
DB_REF="$(ref_of "$DATABASE_URL")"
URL_REF="$(ref_of "$SUPABASE_URL")"
[ "$DB_REF" = "$URL_REF" ] \
  || error "credentials disagree: the URI names '${DB_REF}' but the project URL names '${URL_REF}'"
info "both credentials name project '${DB_REF}'"

# ── Write config ──────────────────────────────────────────────────────────────
step "Writing ${CONF_DIR}/${PROJECT}.conf"

umask 077
cat > "${CONF_DIR}/${PROJECT}.conf" <<EOF
# supabase-backup config for '${PROJECT}'
# Written by supabase-backup-setup.sh. Contains a service key that bypasses
# RLS and a database password: keep this file 0600 and out of version control.
DATABASE_URL=${DATABASE_URL}
SUPABASE_URL=${SUPABASE_URL}
SUPABASE_SERVICE_KEY=${SUPABASE_SERVICE_KEY}
BACKUP_DIR=${DATA_DIR}/${PROJECT}
KEEP_DAYS=${KEEP_DAYS}
EOF
chmod 0600 "${CONF_DIR}/${PROJECT}.conf"
install -d -m 0700 "${DATA_DIR}/${PROJECT}"
info "config written, mode 0600"

# ── Check reachability and client version ─────────────────────────────────────
step "Checking the connection"

SERVER_VER="$(psql "$DATABASE_URL" -Atc "show server_version_num" 2>&1)" \
  || error "cannot connect: ${SERVER_VER}"
SERVER_MAJOR=$(( SERVER_VER / 10000 ))
CLIENT_MAJOR="$(pg_dump --version | awk '{print $3}' | cut -d. -f1)"
info "server PostgreSQL ${SERVER_MAJOR}, pg_dump ${CLIENT_MAJOR}"

if [ "$CLIENT_MAJOR" -lt "$SERVER_MAJOR" ]; then
  warn "pg_dump ${CLIENT_MAJOR} cannot dump a PostgreSQL ${SERVER_MAJOR} server."
  warn "Install a matching client from the PGDG repository:"
  warn "  https://www.postgresql.org/download/linux/debian/"
  error "refusing to schedule a backup that cannot run"
fi

# ── First run ─────────────────────────────────────────────────────────────────
step "First backup"

echo "  Running once now, so a failure surfaces here rather than at 03:20."
echo ""
if systemctl start "supabase-backup@${PROJECT}.service"; then
  journalctl -u "supabase-backup@${PROJECT}.service" -n 20 --no-pager -o cat | sed 's/^/  /'
  info "first backup succeeded"
else
  journalctl -u "supabase-backup@${PROJECT}.service" -n 30 --no-pager -o cat | sed 's/^/  /'
  error "first backup failed — see the output above. Config: ${CONF_DIR}/${PROJECT}.conf"
fi

# ── Schedule ──────────────────────────────────────────────────────────────────
step "Scheduling"

systemctl enable --now "supabase-backup@${PROJECT}.timer" >/dev/null 2>&1 \
  || error "could not enable the timer"
systemctl list-timers "supabase-backup@${PROJECT}.timer" --no-pager | head -2 | sed 's/^/  /'

# ── Done ──────────────────────────────────────────────────────────────────────
step "Done"

cat <<EOF

  Project '${PROJECT}' is backed up nightly to ${DATA_DIR}/${PROJECT}.

  Run now           systemctl start supabase-backup@${PROJECT}.service
  See what happened journalctl -u supabase-backup@${PROJECT}.service
  Next run          systemctl list-timers supabase-backup@${PROJECT}.timer
  Add another       re-run this script
  Restore           supabase-restore

  supabase-restore refuses to write to any project configured here, so it
  cannot overwrite the thing it backs up. Rehearse it against a throwaway
  project before you need it.

  Archives live only on this machine. Back the machine up, or copy them
  elsewhere — a backup that exists in one place is one incident from being
  no backup at all.

  Docs: https://github.com/${GITHUB_USER}/${GITHUB_REPO}/blob/${BRANCH}/scripts/docs/supabase-backup.md

EOF
