#!/bin/bash
# supabase-backup-web-setup.sh — install the Supabase backup web console.
#
# A read-mostly view of what supabase-backup has actually produced on this
# host: every project's archives with their manifests, the run history, the
# next scheduled run, and a verify that re-checks an archive against its own
# checksums and its own inventory. It can start a run, change its own password
# and settings, and - if you say so here - ask the host to restore an archive
# into another project.
#
# Run it again after adding a project, so the new archive directory becomes
# readable by the console.

set -euo pipefail

# ── Config ────────────────────────────────────────────────────────────────────
GITHUB_USER="maggifrank"
GITHUB_REPO="scripts"
BRANCH="main"
RAW_BASE="https://raw.githubusercontent.com/${GITHUB_USER}/${GITHUB_REPO}/${BRANCH}/scripts/supabase-backup"

LIB_DIR="/opt/supabase-backup"
WEB_DIR="${LIB_DIR}/web"
CONF_DIR="/etc/supabase-backup"
WEB_CONF_DIR="/etc/supabase-backup-web"
DATA_DIR="/var/backups/supabase"
UNIT_DIR="/etc/systemd/system"
SVC_USER="supabase-backup-web"

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

[ "$(id -u)" -eq 0 ] || error "This script must be run as root."
[ ! -t 0 ] && exec < /dev/tty

echo ""
echo -e "${BOLD}Supabase backup — web console${NC}"
echo ""
echo "  A browser view of what the nightly timers have produced:"
echo "    · every project on this host, with its archives and manifests"
echo "    · run history, read from the journal"
echo "    · verify an archive against its own checksums and inventory"
echo "    · start a run"
echo "    · change its own password and settings, applied by a root helper"
echo "    · set who each project's archives are encrypted to"
echo "    · say what version this host runs, and upgrade it"
echo ""
echo "  Restoring is asked about below. It is off unless you turn it on, and"
echo "  even then the console only asks: restore does the work on this host, as"
echo "  root, refusing any project this host backs up."
echo ""
[ -x "${LIB_DIR}/backup.sh" ] || error "supabase-backup is not installed - run supabase-backup-setup.sh first"
read -rp "Proceed? [y/N]: " CONFIRM
[[ "$CONFIRM" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }

# ── Dependencies ──────────────────────────────────────────────────────────────
step "Dependencies"
MISSING=()
command -v python3 >/dev/null || MISSING+=(python3)
# The run button starts a unit as an unprivileged user. polkit lets that go
# over D-Bus, so nothing has to be setuid and the console keeps
# NoNewPrivileges=true.
command -v pkaction >/dev/null || MISSING+=(polkitd)
if [ ${#MISSING[@]} -gt 0 ]; then
  info "installing: ${MISSING[*]}"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq "${MISSING[@]}" || error "dependency install failed"
fi
info "python $(python3 -V 2>&1 | awk '{print $2}')"

# age encrypts the archives, when a project has recipients. Not fatal if it is
# not packaged here: a host that never sets a recipient never calls it, and the
# console says so rather than pretending encryption is on.
if ! command -v age >/dev/null; then
  apt-get install -y -qq age >/dev/null 2>&1 || true
fi
if command -v age >/dev/null; then
  info "age $(age --version 2>/dev/null | head -1)"
else
  warn "age is not installed - archive encryption will not be available"
fi

# ── Service user ──────────────────────────────────────────────────────────────
step "Service user"
if ! id "$SVC_USER" >/dev/null 2>&1; then
  adduser --system --group --no-create-home --shell /usr/sbin/nologin "$SVC_USER" >/dev/null
fi
info "$(id "$SVC_USER")"

# ── Install the console ───────────────────────────────────────────────────────
step "Installing to ${WEB_DIR}"
install -d -m 0755 "$WEB_DIR" "${WEB_DIR}/static"
curl -fsSL --max-time 30 "${RAW_BASE}/web/server.py" -o "${WEB_DIR}/server.py" \
  || error "could not download server.py from ${RAW_BASE}/web"
for f in index.html app.js style.css favicon.svg; do
  curl -fsSL --max-time 30 "${RAW_BASE}/web/static/${f}" -o "${WEB_DIR}/static/${f}" \
    || error "could not download static/${f}"
done
chmod 0755 "${WEB_DIR}/server.py"
chmod 0644 "${WEB_DIR}"/static/*
info "console installed"

# ── The privileged half ───────────────────────────────────────────────────────
# Registering a project writes a root-owned config holding a service key and
# enables a timer. The console cannot do any of that: it drops a request in a
# spool directory it owns, and this oneshot - triggered by a .path unit, never
# reachable over the network - validates and applies it.
step "Registration helper"
curl -fsSL --max-time 30 "${RAW_BASE}/register" -o "${LIB_DIR}/register" \
  || error "could not download the registration helper"
chmod 0755 "${LIB_DIR}/register"

curl -fsSL --max-time 30 "${RAW_BASE}/supabase-backup-web.tmpfiles" \
  -o /etc/tmpfiles.d/supabase-backup-web.conf || error "could not download the tmpfiles config"
chmod 0644 /etc/tmpfiles.d/supabase-backup-web.conf
systemd-tmpfiles --create /etc/tmpfiles.d/supabase-backup-web.conf \
  || error "could not create the spool directories"

for f in supabase-backup-register.path supabase-backup-register.service; do
  curl -fsSL --max-time 30 "${RAW_BASE}/${f}" -o "${UNIT_DIR}/${f}" \
    || error "could not download ${f}"
  chmod 0644 "${UNIT_DIR}/${f}"
done
systemctl daemon-reload
systemctl enable --now supabase-backup-register.path >/dev/null 2>&1 \
  || error "could not enable supabase-backup-register.path"
info "registration helper installed and watching the spool"

# ── The settings helper ───────────────────────────────────────────────────────
# The console's Settings panel changes web.env - its password above all - and
# the console can do neither: it cannot write the file that configures it and
# cannot restart itself. Same shape as registration, one more spool.
step "Settings helper"
curl -fsSL --max-time 30 "${RAW_BASE}/reconfigure" -o "${LIB_DIR}/reconfigure" \
  || error "could not download the settings helper"
chmod 0755 "${LIB_DIR}/reconfigure"

for f in supabase-backup-reconfigure.path supabase-backup-reconfigure.service; do
  curl -fsSL --max-time 30 "${RAW_BASE}/${f}" -o "${UNIT_DIR}/${f}" \
    || error "could not download ${f}"
  chmod 0644 "${UNIT_DIR}/${f}"
done
systemctl daemon-reload
systemctl enable --now supabase-backup-reconfigure.path >/dev/null 2>&1 \
  || error "could not enable supabase-backup-reconfigure.path"
info "settings helper installed and watching the spool"

# ── The encryption helper ─────────────────────────────────────────────────────
# Who an archive is encrypted to is a public key, so nothing here is secret -
# but it decides who can read every archive written from then on, and it lives
# in a root-owned directory. Same shape again: the console asks, root writes.
step "Encryption helper"
curl -fsSL --max-time 30 "${RAW_BASE}/keys" -o "${LIB_DIR}/keys" \
  || error "could not download the encryption helper"
chmod 0755 "${LIB_DIR}/keys"

# Before the unit, not by it. supabase-backup-keys.service runs under
# ProtectSystem=strict with this path in ReadWritePaths=, and systemd refuses
# to start a unit whose ReadWritePaths= names a directory that does not exist -
# it fails at namespace setup, before ExecStart, so the helper never runs to
# create the directory itself. The console is left polling a result that will
# never be written.
#
# 0755: these are public keys. The console has to read them to show what a
# project encrypts to, and it runs as another user.
install -d -m 0755 /etc/supabase-backup-keys

for f in supabase-backup-keys.path supabase-backup-keys.service; do
  curl -fsSL --max-time 30 "${RAW_BASE}/${f}" -o "${UNIT_DIR}/${f}" \
    || error "could not download ${f}"
  chmod 0644 "${UNIT_DIR}/${f}"
done
systemctl daemon-reload
systemctl enable --now supabase-backup-keys.path >/dev/null 2>&1 \
  || error "could not enable supabase-backup-keys.path"
info "encryption helper installed and watching the spool"

# ── The rotation helper ───────────────────────────────────────────────────────
# A project's database password and service key live in a root-owned 0600 file
# the console cannot read. Rotating them meant an SSH session and an editor,
# which is why it did not happen - and an un-rotated credential has been exposed
# since the day it was made. Same shape as the rest: the console carries the new
# ones as far as a spool, root proves they work and only then replaces the old.
step "Rotation helper"
curl -fsSL --max-time 30 "${RAW_BASE}/credentials" -o "${LIB_DIR}/credentials" \
  || error "could not download the rotation helper"
chmod 0755 "${LIB_DIR}/credentials"

for f in supabase-backup-credentials.path supabase-backup-credentials.service; do
  curl -fsSL --max-time 30 "${RAW_BASE}/${f}" -o "${UNIT_DIR}/${f}" \
    || error "could not download ${f}"
  chmod 0644 "${UNIT_DIR}/${f}"
done
systemctl daemon-reload
systemctl enable --now supabase-backup-credentials.path >/dev/null 2>&1 \
  || error "could not enable supabase-backup-credentials.path"
info "rotation helper installed and watching the spool"

# ── The upgrade helper ────────────────────────────────────────────────────────
# The console's version panel says what this host is running and what GitHub
# publishes. Acting on the difference means writing /opt/supabase-backup and
# /etc/systemd/system, which the console cannot do and should not be able to.
# Same shape as the others: it asks, root installs - and root takes nothing
# from the request but a verb, because every URL is fixed in the script.
step "Upgrade helper"
# backup.sh, catalog.sql and the two template units belong to the other setup
# script, and this one has never refreshed them - so a host kept current by
# re-running *this* script has been carrying an old backup.sh all along. They
# are here now, because the version recorded at the end of this script names a
# commit, and that has to be true of the whole installation rather than of the
# half this script used to touch.
for f in backup.sh catalog.sql upgrade VERSION; do
  curl -fsSL --max-time 30 "${RAW_BASE}/${f}" -o "${LIB_DIR}/${f}" \
    || error "could not download ${f}"
done
chmod 0755 "${LIB_DIR}/backup.sh" "${LIB_DIR}/upgrade"
chmod 0644 "${LIB_DIR}/catalog.sql" "${LIB_DIR}/VERSION"
for f in "supabase-backup@.service" "supabase-backup@.timer" \
         supabase-backup-upgrade-scheduled.service supabase-backup-upgrade-scheduled.timer; do
  curl -fsSL --max-time 30 "${RAW_BASE}/${f}" -o "${UNIT_DIR}/${f}" \
    || error "could not download ${f}"
  chmod 0644 "${UNIT_DIR}/${f}"
done

# The directory the console's Automatic switch writes into. Its helper is
# sandboxed out of the rest of /etc and cannot create this itself, so it is
# made here - and left saying "off", which is what it means to not have asked.
install -d -m 0755 /etc/supabase-backup-upgrade
[ -f /etc/supabase-backup-upgrade/upgrade.env ] || "${LIB_DIR}/upgrade" --auto off >/dev/null 2>&1 || true
# An installation from before supabase-backup-setup.sh knew about any of this
# has no upgrade command on PATH. It does now.
ln -sf "${LIB_DIR}/upgrade" /usr/local/bin/supabase-backup-upgrade

for f in supabase-backup-upgrade.path supabase-backup-upgrade.service; do
  curl -fsSL --max-time 30 "${RAW_BASE}/${f}" -o "${UNIT_DIR}/${f}" \
    || error "could not download ${f}"
  chmod 0644 "${UNIT_DIR}/${f}"
done
systemctl daemon-reload
systemctl enable --now supabase-backup-upgrade.path >/dev/null 2>&1 \
  || error "could not enable supabase-backup-upgrade.path"
systemctl enable --now supabase-backup-upgrade-scheduled.timer >/dev/null 2>&1 \
  || error "could not enable supabase-backup-upgrade-scheduled.timer"
info "upgrade helper installed and watching the spool"
info "checking for new versions at 00:00 and 12:00; installing nothing unless asked"

# ── The restore helper ────────────────────────────────────────────────────────
# The same restore an operator runs by hand, reading its answers from a request
# instead of from a terminal. Two switches, and they are not the same question:
# WEB_ALLOW_RESTORE decides whether the console offers it, and this .path unit
# decides whether the host acts on one at all. Leaving the unit disabled means
# a request could be written and would simply never be read.
step "Restore helper"
curl -fsSL --max-time 30 "${RAW_BASE}/restore" -o "${LIB_DIR}/restore" \
  || error "could not download restore"
chmod 0755 "${LIB_DIR}/restore"
for f in supabase-backup-restore.path supabase-backup-restore.service; do
  curl -fsSL --max-time 30 "${RAW_BASE}/${f}" -o "${UNIT_DIR}/${f}" \
    || error "could not download ${f}"
  chmod 0644 "${UNIT_DIR}/${f}"
done
systemctl daemon-reload

echo ""
echo "  Allow restores to be started from the console?"
echo ""
echo "    A restore writes an archive into another Supabase project and cannot"
echo "    be undone. The console never does it itself: it asks, and restore"
echo "    carries it out here as root, with every guard it has at a terminal -"
echo "    it refuses any project this host backs up, refuses credentials that"
echo "    name two different projects, and will not write until whoever asked"
echo "    has typed the target project's ref in full."
echo ""
echo "    Answering no installs the helper and leaves it disabled, so a request"
echo "    would never be read. You can turn it on later."
echo ""
read -rp "  Allow restores? [y/N]: " ALLOW_RESTORE_ANSWER
if [[ "$ALLOW_RESTORE_ANSWER" =~ ^[Yy]$ ]]; then
  RESTORE_ENABLED=1
  systemctl enable --now supabase-backup-restore.path >/dev/null 2>&1 \
    || error "could not enable supabase-backup-restore.path"
  info "restore helper installed and watching the spool"
else
  RESTORE_ENABLED=0
  systemctl disable --now supabase-backup-restore.path >/dev/null 2>&1 || true
  info "restore helper installed, not enabled"
fi

# ── Let it read the archives ──────────────────────────────────────────────────
# The archive tree is 0700 root. The console needs to read it and nothing else,
# so it gets group access - the per-project .conf files, which hold the service
# keys, stay 0600 root and out of reach.
step "Archive access"
chgrp "$SVC_USER" "$DATA_DIR"
chmod 0750 "$DATA_DIR"
COUNT=0
for d in "$DATA_DIR"/*/; do
  [ -d "$d" ] || continue
  chgrp -R "$SVC_USER" "$d"
  chmod 0750 "$d"
  COUNT=$((COUNT + 1))
done
info "${COUNT} project director$([ "$COUNT" = 1 ] && echo y || echo ies) readable by ${SVC_USER}"
[ "$COUNT" -eq 0 ] && warn "no projects yet - add one with supabase-backup-setup.sh, then re-run this script"

# ── Configuration ─────────────────────────────────────────────────────────────
step "Configuration"
install -d -m 0750 -g "$SVC_USER" "$WEB_CONF_DIR"
if [ -f "${WEB_CONF_DIR}/web.env" ]; then
  info "keeping existing ${WEB_CONF_DIR}/web.env"
else
  curl -fsSL --max-time 30 "${RAW_BASE}/web/web.env.example" -o "${WEB_CONF_DIR}/web.env" \
    || error "could not download web.env.example"
  chown root:"$SVC_USER" "${WEB_CONF_DIR}/web.env"
  chmod 0640 "${WEB_CONF_DIR}/web.env"

  echo ""
  echo "  The console will not start without a password. An archive holds every"
  echo "  auth password hash and every storage object, so this is not something"
  echo "  to leave open."
  echo ""
  read -rp "  Username [admin]: " WEB_USER
  WEB_USER="${WEB_USER:-admin}"
  sed -i "s|^WEB_USER=.*|WEB_USER=${WEB_USER}|" "${WEB_CONF_DIR}/web.env"

  # --hash prompts on the terminal and prints only the digest line; the
  # password itself is never an argument, never in the environment, and never
  # written anywhere.
  HASH_LINE="$("${WEB_DIR}/server.py" --hash | tail -1)" \
    || error "could not generate a password hash"
  sed -i "/^WEB_PASSWORD_HASH=/d" "${WEB_CONF_DIR}/web.env"
  printf '%s\n' "$HASH_LINE" >> "${WEB_CONF_DIR}/web.env"
  info "password set for ${WEB_USER}"
  info "change it later from the console's gear icon, or here in web.env"

  echo ""
  echo "  Where should the console listen?"
  echo "    1) 127.0.0.1  — reach it over an SSH tunnel (default, nothing new on the LAN)"
  echo "    2) 0.0.0.0    — browse it directly on the LAN (password crosses the wire in clear)"
  read -rp "  Choice [1]: " BIND_CHOICE
  if [ "${BIND_CHOICE:-1}" = "2" ]; then
    sed -i "s|^WEB_BIND=.*|WEB_BIND=0.0.0.0:8787|" "${WEB_CONF_DIR}/web.env"
    warn "listening on all interfaces - Basic auth over plain HTTP"
    warn "registering a project will be refused on that connection: it carries a"
    warn "service key. Use a TLS proxy on this host, or an SSH tunnel, for that."
  fi
fi

# A web.env written before this switch existed has no line for it, and the
# console defaults it on - so the file and the behaviour would disagree, and
# the Settings panel would show a box whose state is not in the file it edits.
if ! grep -q '^WEB_ALLOW_UPGRADE=' "${WEB_CONF_DIR}/web.env"; then
  printf '\n# Allow upgrading supabase-backup from the console.\nWEB_ALLOW_UPGRADE=1\n' \
    >> "${WEB_CONF_DIR}/web.env"
fi

# Written whether the file is new or was kept: the question was just asked, so
# the answer is what should be in there. An older web.env predating the switch
# has no line to replace, and gets one.
if grep -q '^WEB_ALLOW_RESTORE=' "${WEB_CONF_DIR}/web.env"; then
  sed -i "s|^WEB_ALLOW_RESTORE=.*|WEB_ALLOW_RESTORE=${RESTORE_ENABLED}|" "${WEB_CONF_DIR}/web.env"
else
  printf 'WEB_ALLOW_RESTORE=%s\n' "$RESTORE_ENABLED" >> "${WEB_CONF_DIR}/web.env"
fi
info "restores from the console: $([ "$RESTORE_ENABLED" = 1 ] && echo enabled || echo disabled)"

# ── polkit: let the console start a backup ────────────────────────────────────
step "Run permission"
install -d -m 0755 /etc/polkit-1/rules.d
cat > /etc/polkit-1/rules.d/50-supabase-backup-web.rules <<RULE
// Let the console start a backup - that one template, that one verb, that one
// user. Stopping, restarting, the timers and every other unit stay out of reach.
polkit.addRule(function(action, subject) {
  if (action.id == "org.freedesktop.systemd1.manage-units" &&
      action.lookup("verb") == "start" &&
      /^supabase-backup@.+\.service$/.test(action.lookup("unit") || "") &&
      subject.user == "${SVC_USER}") {
    return polkit.Result.YES;
  }
});
RULE
chmod 0644 /etc/polkit-1/rules.d/50-supabase-backup-web.rules
systemctl restart polkit 2>/dev/null || true
info "polkit rule installed"

# ── Unit ──────────────────────────────────────────────────────────────────────
step "Service"
curl -fsSL --max-time 30 "${RAW_BASE}/supabase-backup-web.service" \
  -o "${UNIT_DIR}/supabase-backup-web.service" || error "could not download the unit"
chmod 0644 "${UNIT_DIR}/supabase-backup-web.service"
systemctl daemon-reload
systemctl enable supabase-backup-web.service >/dev/null 2>&1
systemctl restart supabase-backup-web.service || error "the console failed to start - journalctl -u supabase-backup-web -n 30"
sleep 1
systemctl is-active --quiet supabase-backup-web.service \
  || error "the console is not running - journalctl -u supabase-backup-web -n 30"

# Which commit all of this is, so the console's version panel has something to
# compare against. Not fatal if GitHub's API cannot be reached: the record just
# has no commit in it, and the check falls back to comparing VERSION strings.
INSTALLED="$("${LIB_DIR}/upgrade" --record 2>/dev/null || true)"
info "running ${INSTALLED:-an unrecorded version}"

BIND="$(grep '^WEB_BIND=' "${WEB_CONF_DIR}/web.env" | cut -d= -f2-)"
PORT="${BIND##*:}"
HOSTIP="$(hostname -I 2>/dev/null | awk '{print $1}')"

echo ""
echo -e "${BOLD}Done.${NC}"
echo ""
if [[ "$BIND" == 0.0.0.0:* ]]; then
  echo "  Console           http://${HOSTIP}:${PORT}"
else
  echo "  Console           http://127.0.0.1:${PORT}  (bound to localhost)"
  echo "  Reach it with     ssh -N -L ${PORT}:127.0.0.1:${PORT} root@${HOSTIP}"
fi
echo "  Status            systemctl status supabase-backup-web"
echo "  Registrations     journalctl -u supabase-backup-register -n 30"
echo "  Settings changes  journalctl -u supabase-backup-reconfigure -n 30"
echo "  Encryption keys   journalctl -u supabase-backup-keys -n 30"
echo "  Upgrades          journalctl -u supabase-backup-upgrade -n 50"
echo "  Version checks    journalctl -u supabase-backup-upgrade-scheduled -n 50"
echo "  Restores          journalctl -u supabase-backup-restore -n 50"
echo "  Logs              journalctl -u supabase-backup-web -n 30"
echo "  Settings          ${WEB_CONF_DIR}/web.env"
echo ""
echo "  After adding a project, re-run this script so its archive directory"
echo "  becomes readable by the console."
echo ""
echo "  To update the code from now on, use the console's gear icon or run"
echo "  supabase-backup-upgrade here - it replaces code only, and asks none of"
echo "  the questions this script just asked."
echo ""
