# Ubuntu Server Hardening

Applies security best practices to a fresh Ubuntu Server install. Safe to run on bare metal, VMs, and LXC containers.

## Prerequisites

- Ubuntu Server (20.04 LTS or later)
- Root or sudo access
- A snapshot or backup taken before running

## What the Script Asks For

| Prompt | Example | Notes |
|---|---|---|
| SSH port | `22` | Change to reduce noise from bots |
| Sudo username | `magnus` | The non-root user to keep |
| SSH public key | `ssh-ed25519 AAA...` | Paste your public key |
| Timezone | `Atlantic/Reykjavik` | Leave blank to skip |

> **Important:** Verify you can log in via SSH in a new session before closing your current one. The script locks down SSH aggressively.

## What It Does

### System
- Full system update before anything else
- Unnecessary services disabled (avahi, cups, bluetooth, ModemManager)
- Reboot prompt at the end to apply all kernel changes

### SSH
- Key-only authentication (password auth disabled)
- Root login disabled
- Configurable port
- Modern crypto only — legacy ciphers removed
- Connection timeouts, max auth tries, login grace period enforced
- Access restricted to a single named user
- Warning banner shown on login

### Firewall (UFW)
- Default deny all inbound
- SSH port allowed and rate-limited
- All outbound allowed

### Fail2ban
- 3 failed SSH attempts = 24 hour ban
- Uses UFW as the ban backend

### Kernel (sysctl)
- SYN flood protection
- ICMP hardening and broadcast ignore
- Martian packet logging
- Reverse path filtering
- ASLR enabled
- ptrace, BPF, perf events restricted
- kptr and dmesg restricted
- SysRq disabled
- Core dumps disabled for setuid programs
- IPv6 disabled

### Automatic Updates
- Security updates applied automatically via `unattended-upgrades`
- Non-security updates left for manual review
- Auto-reboot disabled — you control when to reboot

### Password Policy
- Minimum 14 characters
- Requires uppercase, lowercase, numbers, and symbols
- Account lockout after 5 failed attempts (15 minute unlock)

### Audit Daemon (auditd)
Monitors and logs changes to:
- `/etc/passwd`, `/etc/shadow`, `/etc/group`
- `/etc/sudoers`
- SSH config
- Cron jobs
- Login and logout events
- Privilege escalation calls

Rules are made immutable — require a reboot to change.

### Other
- Sensitive file permissions enforced (`/etc/shadow`, `/etc/passwd`, etc.)
- USB storage disabled
- MOTD cleaned up
- Logwatch configured for daily digest to root
- Full log of the hardening run saved to `/var/log/hardening-<timestamp>.log`

## Post-Setup Checklist

- [ ] Open a new SSH session and confirm login works before closing the current one
- [ ] Add any additional UFW rules you need: `ufw allow <port>/tcp`
- [ ] Reboot to apply kernel hardening: `reboot`
- [ ] Check Logwatch is sending digests: `logwatch --output stdout --range today`

## Updating

Run the script again on the same system — it will detect the existing installation and run an update instead of a fresh install:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/maggifrank/scripts/main/install.sh)"
```

Select the same script from the menu. No configuration prompts — just updates packages and restarts services.

## Useful Commands

```bash
# Check UFW status
ufw status verbose

# Check fail2ban bans
fail2ban-client status sshd

# Check automatic update logs
cat /var/log/unattended-upgrades/unattended-upgrades.log

# Check audit log
ausearch -k identity
ausearch -k sudoers

# Re-enable USB storage if needed
rm /etc/modprobe.d/disable-usb-storage.conf
```
