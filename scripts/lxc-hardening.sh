#!/bin/bash
# lxc-hardening.sh
# Lightweight hardening for Ubuntu/Debian LXC containers.
# Only applies what's relevant inside a container — kernel and hardware-level
# hardening is handled by the Proxmox host.

set -euo pipefail
IFS=$'\n\t'

# ── Colors ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC}  $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }
step()  { echo -e "\n${BLUE}──── $1 ────${NC}"; }

# ── Root check ────────────────────────────────────────────────────────────────
[ "$EUID" -ne 0 ] && error "Please run as root (sudo ./lxc-hardening.sh)"

# ── Log everything ────────────────────────────────────────────────────────────
LOGFILE="/var/log/lxc-hardening-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "$LOGFILE") 2>&1

echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║            LXC Container Hardening                   ║"
echo "╚══════════════════════════════════════════════════════╝"
echo ""
warn "This script applies container-appropriate hardening only."
warn "Kernel and firewall hardening is handled at the Proxmox host level."
echo ""
read -rp "Proceed? [y/N]: " CONFIRM
[ "${CONFIRM,,}" = "y" ] || { echo "Aborted."; exit 0; }

# ── Gather input ──────────────────────────────────────────────────────────────
step "Configuration"

read -rp "Is this container internet-facing? [y/N]: " INTERNET_FACING
INTERNET_FACING=${INTERNET_FACING,,}

read -rp "Harden SSH? (only if you SSH directly into this container) [y/N]: " HARDEN_SSH
HARDEN_SSH=${HARDEN_SSH,,}

if [ "$HARDEN_SSH" = "y" ]; then
  read -rp "SSH port [default: 22]: " SSH_PORT
  SSH_PORT=${SSH_PORT:-22}

  read -rp "Non-root sudo username to allow SSH for (leave blank to skip): " SUDO_USER

  if [ -n "${SUDO_USER:-}" ]; then
    read -rp "Paste SSH public key for ${SUDO_USER} (leave blank to skip): " SSH_PUBKEY
  fi
fi

# ── 1. System update ──────────────────────────────────────────────────────────
step "1. System update"
apt-get update -q
DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -q
apt-get autoremove -y -q
info "System updated."

# ── 2. Install essentials ─────────────────────────────────────────────────────
step "2. Installing security tools"
PACKAGES=(
  unattended-upgrades
  apt-listchanges
  libpam-pwquality
  rsyslog
  logwatch
  curl
  wget
)
[ "$INTERNET_FACING" = "y" ] && PACKAGES+=(fail2ban)

DEBIAN_FRONTEND=noninteractive apt-get install -y -q "${PACKAGES[@]}"
info "Packages installed."

# ── 3. Non-root sudo user ─────────────────────────────────────────────────────
if [ "$HARDEN_SSH" = "y" ] && [ -n "${SUDO_USER:-}" ]; then
  step "3. User setup"
  if ! id "$SUDO_USER" &>/dev/null; then
    adduser --disabled-password --gecos "" "$SUDO_USER"
    info "User $SUDO_USER created."
  else
    info "User $SUDO_USER already exists."
  fi
  usermod -aG sudo "$SUDO_USER"

  if [ -n "${SSH_PUBKEY:-}" ]; then
    SSH_DIR="/home/${SUDO_USER}/.ssh"
    mkdir -p "$SSH_DIR"
    echo "$SSH_PUBKEY" >> "${SSH_DIR}/authorized_keys"
    chown -R "${SUDO_USER}:${SUDO_USER}" "$SSH_DIR"
    chmod 700 "$SSH_DIR"
    chmod 600 "${SSH_DIR}/authorized_keys"
    info "SSH public key added for $SUDO_USER."
  fi
fi

# ── 4. SSH hardening ──────────────────────────────────────────────────────────
if [ "$HARDEN_SSH" = "y" ]; then
  step "4. SSH hardening"
  SSHD_CONFIG="/etc/ssh/sshd_config"
  cp "$SSHD_CONFIG" "${SSHD_CONFIG}.bak.$(date +%Y%m%d)"

  cat > /etc/ssh/sshd_config.d/99-hardening.conf << EOF
Port ${SSH_PORT}
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
AuthenticationMethods publickey
PermitEmptyPasswords no
X11Forwarding no
AllowTcpForwarding no
ClientAliveInterval 300
ClientAliveCountMax 2
LoginGraceTime 30
MaxAuthTries 3
MaxSessions 3
LogLevel VERBOSE
Banner /etc/ssh/banner
KexAlgorithms curve25519-sha256,curve25519-sha256@libssh.org,diffie-hellman-group14-sha256,diffie-hellman-group16-sha512
Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes128-gcm@openssh.com
MACs hmac-sha2-256-etm@openssh.com,hmac-sha2-512-etm@openssh.com
EOF

  [ -n "${SUDO_USER:-}" ] && echo "AllowUsers ${SUDO_USER}" >> /etc/ssh/sshd_config.d/99-hardening.conf

  cat > /etc/ssh/banner << 'EOF'
╔══════════════════════════════════════════════════╗
║  Authorised access only. All activity is logged. ║
╚══════════════════════════════════════════════════╝
EOF

  systemctl restart ssh
  info "SSH hardened on port $SSH_PORT."
  warn "Verify you can log in via a new SSH session before closing this one."
fi

# ── 5. Fail2ban (internet-facing only) ───────────────────────────────────────
if [ "$INTERNET_FACING" = "y" ]; then
  step "5. Fail2ban"
  SSH_PORT_FOR_F2B=${SSH_PORT:-22}
  cat > /etc/fail2ban/jail.local << EOF
[DEFAULT]
bantime  = 1h
findtime = 10m
maxretry = 5
backend  = systemd

[sshd]
enabled  = true
port     = ${SSH_PORT_FOR_F2B}
logpath  = %(sshd_log)s
maxretry = 3
bantime  = 24h
EOF
  systemctl enable fail2ban
  systemctl restart fail2ban
  info "Fail2ban configured — 3 failed SSH attempts = 24h ban."
fi

# ── 6. Automatic security updates ─────────────────────────────────────────────
step "6. Automatic security updates"
cat > /etc/apt/apt.conf.d/50unattended-upgrades << 'EOF'
Unattended-Upgrade::Allowed-Origins {
  "${distro_id}:${distro_codename}-security";
};
Unattended-Upgrade::AutoFixInterruptedDpkg "true";
Unattended-Upgrade::MinimalSteps "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "false";
Unattended-Upgrade::Mail "root";
EOF

cat > /etc/apt/apt.conf.d/20auto-upgrades << 'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF

systemctl enable unattended-upgrades
systemctl restart unattended-upgrades
info "Automatic security updates enabled."

# ── 7. Password policy ────────────────────────────────────────────────────────
step "7. Password policy"
cat > /etc/security/pwquality.conf << 'EOF'
minlen = 14
minclass = 3
maxrepeat = 3
maxsequence = 4
dcredit = -1
ucredit = -1
lcredit = -1
ocredit = -1
reject_username = 1
EOF

cat > /etc/security/faillock.conf << 'EOF'
deny = 5
unlock_time = 900
fail_interval = 900
EOF
info "Password policy enforced."

# ── 8. Disable unnecessary services ──────────────────────────────────────────
step "8. Disabling unnecessary services"
SERVICES=(avahi-daemon cups cups-browsed bluetooth ModemManager)
for svc in "${SERVICES[@]}"; do
  if systemctl is-enabled "$svc" &>/dev/null 2>&1; then
    systemctl disable --now "$svc" 2>/dev/null || true
    info "Disabled: $svc"
  fi
done

# ── 9. File permissions ───────────────────────────────────────────────────────
step "9. Sensitive file permissions"
chmod 600 /etc/shadow
chmod 600 /etc/gshadow
chmod 644 /etc/passwd
chmod 644 /etc/group
chmod 700 /root
chmod 1777 /tmp
info "File permissions set."

# ── 10. Logwatch ──────────────────────────────────────────────────────────────
step "10. Logwatch"
cat > /etc/logwatch/conf/logwatch.conf << 'EOF'
Output = mail
Format = html
MailTo = root
MailFrom = logwatch
Detail = Med
Service = All
Range = yesterday
EOF
info "Logwatch configured."

# ── 11. MOTD ──────────────────────────────────────────────────────────────────
step "11. Cleaning up MOTD"
chmod -x /etc/update-motd.d/* 2>/dev/null || true
cat > /etc/motd << 'EOF'

  Authorised access only.
  All activity is monitored and logged.

EOF
info "MOTD cleaned up."

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║              Hardening Complete!                     ║"
echo "╚══════════════════════════════════════════════════════╝"
echo ""
info "Summary:"
echo "  ✔  System updated"
echo "  ✔  Automatic security updates enabled"
echo "  ✔  Password policy enforced"
echo "  ✔  Unnecessary services disabled"
echo "  ✔  File permissions hardened"
echo "  ✔  Logwatch configured"
[ "$HARDEN_SSH" = "y" ]       && echo "  ✔  SSH hardened on port $SSH_PORT"
[ "$INTERNET_FACING" = "y" ]  && echo "  ✔  Fail2ban active"
echo ""
info "Log saved to: $LOGFILE"
echo ""