#!/bin/bash
# supabase-backup-web-setup.sh — install the Supabase backup web console.
#
# A read-mostly view of what supabase-backup has actually produced on this
# host: every project's archives with their manifests, the run history, the
# next scheduled run, and a verify that re-checks an archive against its own
# checksums and its own inventory. It can start a run. It cannot restore.
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
echo ""
echo "  It does not restore. That needs the target project's credentials and"
echo "  carries guards that only hold when a person is answering the prompts."
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
echo "  Logs              journalctl -u supabase-backup-web -n 30"
echo "  Settings          ${WEB_CONF_DIR}/web.env"
echo ""
echo "  After adding a project, re-run this script so its archive directory"
echo "  becomes readable by the console."
echo ""
