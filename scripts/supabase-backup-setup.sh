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
# Public keys only, and separate from CONF_DIR on purpose: that one holds a
# service key and is readable by root alone, while these are age recipients -
# not secret, and the web console has to read them to show what a project
# encrypts to.
KEYS_DIR="/etc/supabase-backup-keys"
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

# Not in MISSING: a host that never sets a recipient never calls age, so an
# unpackaged one is not a failed install - it only means the offer below is not
# made. Debian 12 and Ubuntu 22.04 both carry it.
if ! command -v age >/dev/null; then
  apt-get install -y -qq age >/dev/null 2>&1 || true
fi
info "pg_dump $(pg_dump --version | awk '{print $3}')"
if command -v age >/dev/null; then
  info "age $(age --version 2>/dev/null | head -1)"
else
  warn "age is not available here - archives can only be written in the clear"
fi

# ── Install the tool ──────────────────────────────────────────────────────────
step "Installing to ${LIB_DIR}"

install -d -m 0755 "$LIB_DIR"
install -d -m 0700 "$CONF_DIR"
install -d -m 0700 "$DATA_DIR"

for f in backup.sh catalog.sql restore upgrade VERSION; do
  curl -fsSL --max-time 30 "${RAW_BASE}/${f}" -o "${LIB_DIR}/${f}" \
    || error "could not download ${f} from ${RAW_BASE}"
done
chmod 0755 "${LIB_DIR}/backup.sh" "${LIB_DIR}/restore" "${LIB_DIR}/upgrade"
chmod 0644 "${LIB_DIR}/catalog.sql" "${LIB_DIR}/VERSION"

# On PATH as supabase-restore and supabase-backup-upgrade. Note that the
# Proxmox LXC console starts bash without /etc/profile, so /usr/local/bin can
# be missing from PATH there even though an SSH login has it.
ln -sf "${LIB_DIR}/restore" /usr/local/bin/supabase-restore
ln -sf "${LIB_DIR}/upgrade" /usr/local/bin/supabase-backup-upgrade

for f in "supabase-backup@.service" "supabase-backup@.timer"; do
  curl -fsSL --max-time 30 "${RAW_BASE}/${f}" -o "${UNIT_DIR}/${f}" \
    || error "could not download ${f}"
  chmod 0644 "${UNIT_DIR}/${f}"
done
systemctl daemon-reload

# Which commit this is, so `supabase-backup-upgrade` can later say whether there
# is a newer one. Written by the one script that knows what a version is here;
# not fatal if GitHub's API cannot be reached, the record simply has no commit
# in it and the check falls back to comparing VERSION strings.
#
# Only when this script installed the whole of what the record would describe.
# On a host that also runs the console, this script refreshes the backup tool
# and leaves server.py and its helpers alone - so recording "this host is at
# commit X" would claim something about files it never touched. A record that
# is one commit behind is harmless: it says an upgrade is available, which is
# true. One that is ahead of the files says the opposite of what is true.
if [ -f "${LIB_DIR}/web/server.py" ]; then
  info "tool and systemd templates installed"
  info "the console is installed here too - run supabase-backup-upgrade to bring all of it current"
else
  INSTALLED="$("${LIB_DIR}/upgrade" --record 2>/dev/null || true)"
  info "tool and systemd templates installed${INSTALLED:+ — ${INSTALLED}}"
fi

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

# ── Encryption ────────────────────────────────────────────────────────────────
# Asked after the connection check, so nobody is invited to think about keys for
# a project that turns out to be unreachable. Asked before the first run, so
# that if the answer is yes there is never an unencrypted archive on disk for
# this project at all.
step "Encryption"

if ! command -v age >/dev/null; then
  warn "age is not installed, so archives will be written in the clear."
  warn "Install it and re-run this script to turn encryption on later."
else
cat <<'EOF'

  Archives can be encrypted to an age public key. The private half never comes
  here: this host gets the key that locks, not the one that opens. A stolen
  disk, a copy taken offsite, or this machine itself in the wrong hands then
  yields nothing readable.

  The other side of that is real. A lost key is a lost archive - there is no
  recovery path, and nobody can add one afterwards.

  It does not protect the project itself. This host has to hold a database
  password and a service key to take a backup at all, and anyone who reaches
  those can read the live project without touching an archive. What encryption
  protects is every archive that outlives this host or leaves it.

  Make the key where you keep secrets - your laptop, a password manager - not
  here:

      age-keygen -o backup.key

  That prints a public key (age1...) to paste in below, and a private key to
  put somewhere you will still have it in two years. A line from an SSH .pub
  file works too, if you already keep one safely.

EOF
  read -rp "Encrypt archives for '${PROJECT}'? [y/N]: " ENC_ANSWER
  if [[ "$ENC_ANSWER" =~ ^[Yy]$ ]]; then
    echo ""
    echo "  Paste one recipient per line. More than one means any of them can"
    echo "  restore, which is how a single lost key stops being fatal."
    echo "  Empty line when done."
    echo ""
    RECIPIENTS=()
    while :; do
      read -rp "  recipient: " LINE
      [ -z "$LINE" ] && break
      RECIPIENTS+=("$LINE")
    done

    if [ ${#RECIPIENTS[@]} -eq 0 ]; then
      warn "no recipients given - archives will be written in the clear"
    else
      install -d -m 0755 "$KEYS_DIR"
      TMP_REC="$(mktemp "${KEYS_DIR}/.${PROJECT}.XXXXXX")"
      {
        printf '# age recipients for supabase-backup project %s\n' "$PROJECT"
        printf '# Written by supabase-backup-setup.sh on %s. Public keys only:\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        printf '# the identity that opens these archives is deliberately not on this host.\n'
        printf '%s\n' "${RECIPIENTS[@]}"
      } > "$TMP_REC"

      # age is the authority on what age accepts. A list this script liked and
      # age does not would be discovered at 03:20, by a backup that does not
      # happen - so it is made to accept them here, while someone is watching.
      if printf '' | age -R "$TMP_REC" >/dev/null 2>&1; then
        chmod 0644 "$TMP_REC"
        mv -f "$TMP_REC" "${KEYS_DIR}/${PROJECT}.recipients"
        info "${#RECIPIENTS[@]} recipient(s) written to ${KEYS_DIR}/${PROJECT}.recipients"
        info "archives for '${PROJECT}' will be written as .tar.gz.age from now on"
        warn "this host cannot read them back - keep the private key safe"
      else
        printf '' | age -R "$TMP_REC" 2>&1 | sed 's/^/  /' || true
        rm -f "$TMP_REC"
        error "age rejected those recipients (see above) - nothing was written"
      fi
    fi
  else
    info "archives will be written in the clear"
  fi
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
  Update            supabase-backup-upgrade

  supabase-restore refuses to write to any project configured here, so it
  cannot overwrite the thing it backs up. Rehearse it against a throwaway
  project before you need it.

  Archives live only on this machine. Back the machine up, or copy them
  elsewhere — a backup that exists in one place is one incident from being
  no backup at all.

  Docs: https://github.com/${GITHUB_USER}/${GITHUB_REPO}/blob/${BRANCH}/scripts/docs/supabase-backup.md

EOF
