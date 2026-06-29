#!/bin/bash
# ubuntu-server-hardening.sh
# Applies security best practices to a fresh Ubuntu Server install.
# Run once after initial setup.

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
[ "$EUID" -ne 0 ] && error "Please run as root (sudo ./ubuntu-server-hardening.sh)"

# ── Force interactive terminal (required when piped via curl) ─────────────────
[ ! -t 0 ] && exec < /dev/tty

# ── Log everything ────────────────────────────────────────────────────────────
LOGFILE="/var/log/hardening-$(date +%Y%m%d-%H%M%S).log"
exec > >(tee -a "$LOGFILE") 2>&1
info "Logging to $LOGFILE"

echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║          Ubuntu Server Hardening Script              ║"
echo "╚══════════════════════════════════════════════════════╝"
echo ""
warn "This script will make significant changes to your system."
warn "Make sure you have a backup or snapshot before proceeding."
echo ""
read -rp "Proceed? [y/N]: " CONFIRM
[ "${CONFIRM,,}" = "y" ] || { echo "Aborted."; exit 0; }

# ── Gather input ──────────────────────────────────────────────────────────────
step "Configuration"

# SSH port
read -rp "SSH port to use [default: 22]: " SSH_PORT
SSH_PORT=${SSH_PORT:-22}
if ! [[ "$SSH_PORT" =~ ^[0-9]+$ ]] || [ "$SSH_PORT" -lt 1 ] || [ "$SSH_PORT" -gt 65535 ]; then
  error "Invalid port number."
fi

# Non-root sudo user
read -rp "Enter the non-root sudo username to keep (leave blank to skip): " SUDO_USER

# SSH public key
if [ -n "$SUDO_USER" ]; then
  read -rp "Paste your SSH public key for ${SUDO_USER} (leave blank to skip): " SSH_PUBKEY
fi

# Timezone
read -rp "Set timezone (e.g. Atlantic/Reykjavik) [leave blank to skip]: " TIMEZONE

echo ""
info "Starting hardening..."

# ── 1. System update ──────────────────────────────────────────────────────────
step "1. System update"
apt-get update -q
DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -q
DEBIAN_FRONTEND=noninteractive apt-get dist-upgrade -y -q
apt-get autoremove -y -q
info "System updated."

# ── 2. Timezone ───────────────────────────────────────────────────────────────
if [ -n "${TIMEZONE:-}" ]; then
  step "2. Timezone"
  timedatectl set-timezone "$TIMEZONE"
  info "Timezone set to $TIMEZONE"
fi

# ── 3. Install essentials ─────────────────────────────────────────────────────
step "3. Installing security tools"
DEBIAN_FRONTEND=noninteractive apt-get install -y -q \
  ufw \
  fail2ban \
  unattended-upgrades \
  apt-listchanges \
  logwatch \
  auditd \
  audispd-plugins \
  libpam-pwquality \
  acl \
  curl \
  wget \
  git \
  htop \
  net-tools \
  rsyslog
info "Security tools installed."

# ── 4. Non-root sudo user ─────────────────────────────────────────────────────
if [ -n "${SUDO_USER:-}" ]; then
  step "4. User setup"
  if ! id "$SUDO_USER" &>/dev/null; then
    adduser --disabled-password --gecos "" "$SUDO_USER"
    info "User $SUDO_USER created."
  else
    info "User $SUDO_USER already exists."
  fi
  usermod -aG sudo "$SUDO_USER"
  info "Added $SUDO_USER to sudo group."

  # SSH key
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

# ── 5. SSH hardening ──────────────────────────────────────────────────────────
step "5. SSH hardening"
SSHD_CONFIG="/etc/ssh/sshd_config"

# Backup original
cp "$SSHD_CONFIG" "${SSHD_CONFIG}.bak.$(date +%Y%m%d)"
info "Backed up $SSHD_CONFIG"

# Write hardened config
cat > /etc/ssh/sshd_config.d/99-hardening.conf << EOF
# Hardening — applied by ubuntu-server-hardening.sh
Port ${SSH_PORT}

# Auth
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
AuthenticationMethods publickey
PermitEmptyPasswords no
ChallengeResponseAuthentication no
KerberosAuthentication no
GSSAPIAuthentication no
UsePAM yes

# Session
X11Forwarding no
AllowTcpForwarding no
AllowAgentForwarding no
PermitUserEnvironment no
PrintMotd no
Banner /etc/ssh/banner

# Timeouts
ClientAliveInterval 300
ClientAliveCountMax 2
LoginGraceTime 30
MaxAuthTries 3
MaxSessions 3
MaxStartups 10:30:60

# Crypto — modern only
KexAlgorithms curve25519-sha256,curve25519-sha256@libssh.org,diffie-hellman-group14-sha256,diffie-hellman-group16-sha512,diffie-hellman-group18-sha512
Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes128-gcm@openssh.com
MACs hmac-sha2-256-etm@openssh.com,hmac-sha2-512-etm@openssh.com

# Logging
LogLevel VERBOSE
SyslogFacility AUTH
EOF

# Add user restriction if sudo user specified
if [ -n "${SUDO_USER:-}" ]; then
  echo "AllowUsers ${SUDO_USER}" >> /etc/ssh/sshd_config.d/99-hardening.conf
  info "SSH access restricted to user: $SUDO_USER"
fi

# SSH banner
cat > /etc/ssh/banner << EOF
╔══════════════════════════════════════════════════╗
║  Authorised access only. All activity is logged. ║
╚══════════════════════════════════════════════════╝
EOF

systemctl restart ssh
info "SSH hardened on port $SSH_PORT."
warn "Make sure you can still log in before closing this session!"

# ── 6. Firewall (UFW) ─────────────────────────────────────────────────────────
step "6. Firewall (UFW)"
ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw limit "${SSH_PORT}/tcp" comment "SSH"
ufw --force enable
info "UFW enabled. Only SSH port $SSH_PORT allowed inbound."
info "Add more rules with: ufw allow <port>/tcp"

# ── 7. Fail2ban ───────────────────────────────────────────────────────────────
step "7. Fail2ban"
cat > /etc/fail2ban/jail.local << EOF
[DEFAULT]
bantime  = 1h
findtime = 10m
maxretry = 5
backend  = systemd
banaction = ufw

[sshd]
enabled  = true
port     = ${SSH_PORT}
logpath  = %(sshd_log)s
maxretry = 3
bantime  = 24h
EOF

systemctl enable fail2ban
systemctl restart fail2ban
info "Fail2ban configured — 3 failed SSH attempts = 24h ban."

# ── 8. Automatic security updates ─────────────────────────────────────────────
step "8. Automatic security updates"
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

# ── 9. Kernel hardening (sysctl) ─────────────────────────────────────────────
step "9. Kernel hardening"
cat > /etc/sysctl.d/99-hardening.conf << 'EOF'
# ── Network ──────────────────────────────────────────────────────────────────
# Disable IP forwarding (enable if this is a router)
net.ipv4.ip_forward = 0
net.ipv6.conf.all.forwarding = 0

# Disable source routing
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv6.conf.all.accept_source_route = 0

# Disable ICMP redirects
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0

# Enable SYN flood protection
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_max_syn_backlog = 2048
net.ipv4.tcp_synack_retries = 2
net.ipv4.tcp_syn_retries = 5

# Ignore ping broadcasts
net.ipv4.icmp_echo_ignore_broadcasts = 1

# Ignore bogus ICMP errors
net.ipv4.icmp_ignore_bogus_error_responses = 1

# Log martian packets
net.ipv4.conf.all.log_martians = 1
net.ipv4.conf.default.log_martians = 1

# Reverse path filtering
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1

# Disable IPv6 if not needed
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1

# ── Memory ────────────────────────────────────────────────────────────────────
# Restrict kernel pointer exposure
kernel.kptr_restrict = 2

# Restrict dmesg access
kernel.dmesg_restrict = 1

# Disable magic SysRq
kernel.sysrq = 0

# Restrict ptrace
kernel.yama.ptrace_scope = 1

# Disable core dumps for setuid programs
fs.suid_dumpable = 0

# Randomise memory layout (ASLR)
kernel.randomize_va_space = 2

# Restrict unprivileged BPF
kernel.unprivileged_bpf_disabled = 1

# Restrict perf events
kernel.perf_event_paranoid = 3
EOF

sysctl --system > /dev/null
info "Kernel hardening applied."

# ── 10. Password policy ───────────────────────────────────────────────────────
step "10. Password policy"
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

# Login lockout policy via PAM
cat > /etc/security/faillock.conf << 'EOF'
deny = 5
unlock_time = 900
fail_interval = 900
EOF

info "Password policy enforced (min 14 chars, complexity required)."

# ── 11. Disable unused services ───────────────────────────────────────────────
step "11. Disabling unnecessary services"
SERVICES_TO_DISABLE=(
  avahi-daemon
  cups
  cups-browsed
  bluetooth
  ModemManager
)
for svc in "${SERVICES_TO_DISABLE[@]}"; do
  if systemctl is-enabled "$svc" &>/dev/null 2>&1; then
    systemctl disable --now "$svc" 2>/dev/null || true
    info "Disabled: $svc"
  fi
done

# ── 12. File permissions ──────────────────────────────────────────────────────
step "12. Sensitive file permissions"
chmod 600 /etc/shadow
chmod 600 /etc/gshadow
chmod 644 /etc/passwd
chmod 644 /etc/group
chmod 700 /root
chmod 1777 /tmp
info "Sensitive file permissions set."

# ── 13. Audit daemon ──────────────────────────────────────────────────────────
step "13. Audit daemon (auditd)"
cat > /etc/audit/rules.d/99-hardening.rules << 'EOF'
# Delete all existing rules
-D

# Buffer size
-b 8192

# Failure mode — 1 = log, 2 = panic
-f 1

# Monitor auth log
-w /var/log/auth.log -p wa -k auth

# Monitor passwd and shadow changes
-w /etc/passwd -p wa -k identity
-w /etc/shadow -p wa -k identity
-w /etc/group -p wa -k identity
-w /etc/gshadow -p wa -k identity

# Monitor sudoers
-w /etc/sudoers -p wa -k sudoers
-w /etc/sudoers.d/ -p wa -k sudoers

# Monitor SSH config
-w /etc/ssh/sshd_config -p wa -k sshd
-w /etc/ssh/sshd_config.d/ -p wa -k sshd

# Monitor cron
-w /etc/crontab -p wa -k cron
-w /etc/cron.d/ -p wa -k cron
-w /var/spool/cron/ -p wa -k cron

# Monitor login/logout
-w /var/log/faillog -p wa -k logins
-w /var/log/lastlog -p wa -k logins

# Privilege escalation
-a always,exit -F arch=b64 -S setuid -k privilege_escalation
-a always,exit -F arch=b64 -S setgid -k privilege_escalation

# Make rules immutable (requires reboot to change)
-e 2
EOF

systemctl enable auditd
systemctl restart auditd
info "Audit daemon configured and running."

# ── 14. Disable USB storage (optional) ───────────────────────────────────────
step "14. Disable USB storage"
echo "install usb-storage /bin/true" > /etc/modprobe.d/disable-usb-storage.conf
info "USB storage disabled. Remove /etc/modprobe.d/disable-usb-storage.conf to re-enable."

# ── 15. MOTD ──────────────────────────────────────────────────────────────────
step "15. Cleaning up MOTD"
# Disable the noisy Ubuntu MOTD scripts
chmod -x /etc/update-motd.d/* 2>/dev/null || true
cat > /etc/motd << 'EOF'

  Authorised access only.
  All activity is monitored and logged.

EOF
info "MOTD cleaned up."

# ── 16. Logwatch ─────────────────────────────────────────────────────────────
step "16. Logwatch"
cat > /etc/logwatch/conf/logwatch.conf << 'EOF'
Output = mail
Format = html
MailTo = root
MailFrom = logwatch
Detail = Med
Service = All
Range = yesterday
EOF
info "Logwatch configured — daily digest sent to root."

# ── Done ──────────────────────────────────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║              Hardening Complete!                     ║"
echo "╚══════════════════════════════════════════════════════╝"
echo ""
info "Summary of changes:"
echo "  ✔  System updated"
echo "  ✔  SSH hardened on port $SSH_PORT (key-only auth, root login disabled)"
echo "  ✔  UFW firewall enabled (SSH only)"
echo "  ✔  Fail2ban active (3 attempts = 24h ban)"
echo "  ✔  Automatic security updates enabled"
echo "  ✔  Kernel hardened via sysctl"
echo "  ✔  Password policy enforced"
echo "  ✔  Unnecessary services disabled"
echo "  ✔  Audit daemon running"
echo "  ✔  USB storage disabled"
echo "  ✔  Logwatch configured"
echo ""
warn "IMPORTANT — before logging out:"
echo "  1. Open a NEW SSH session on port $SSH_PORT and verify you can log in"
echo "  2. If locked out, use Proxmox console to fix /etc/ssh/sshd_config.d/99-hardening.conf"
echo ""
info "Log saved to: $LOGFILE"
echo ""
warn "A reboot is recommended to apply all kernel changes:"
read -rp "Reboot now? [y/N]: " REBOOT
[ "${REBOOT,,}" = "y" ] && reboot