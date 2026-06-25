# LXC Container Hardening

Lightweight hardening for Ubuntu/Debian LXC containers. Only applies what is relevant inside a container — kernel hardening, firewall rules, and hardware-level settings are handled at the Proxmox host level and are skipped here.

## Prerequisites

- Ubuntu/Debian LXC container
- Root or sudo access
- Container has outbound internet access (for package installs)

## What the Script Asks For

| Prompt | Example | Notes |
|---|---|---|
| Accepts inbound internet connections? | `y` or `n` | Adds fail2ban if yes. Outbound access is always assumed. |
| Harden SSH? | `y` or `n` | Only needed if you SSH directly into this container |
| SSH port | `22` | Only asked if SSH hardening is enabled |
| Sudo username | `magnus` | Non-root user to allow SSH access |
| SSH public key | `ssh-ed25519 AAA...` | Paste your public key. Leave blank to skip |

## What It Does

### Always applied
- Full system update and upgrade
- Installs `unattended-upgrades`, `libpam-pwquality`, `rsyslog`, `logwatch`, `curl`, `wget`
- Automatic security updates enabled
- Password policy enforced (min 14 chars, complexity required, lockout after 5 attempts)
- Unnecessary services disabled (avahi, cups, bluetooth, ModemManager)
- Sensitive file permissions hardened (`/etc/shadow`, `/etc/passwd`, `/tmp`, etc.)
- Logwatch configured for daily digest to root
- MOTD cleaned up

### If internet-facing
- Fail2ban installed and configured (3 failed SSH attempts = 24h ban)

### If SSH hardening enabled
- Key-only authentication (password auth disabled)
- Root login disabled
- Configurable port
- Modern crypto only
- Connection timeouts and max auth tries enforced
- Access restricted to named user if specified
- Warning banner shown on login

## What Is Intentionally Skipped

| Feature | Reason |
|---|---|
| UFW firewall | Use Proxmox firewall rules at the container level instead |
| sysctl kernel hardening | LXC shares the host kernel — settings are ignored or cause errors |
| auditd | Does not work in unprivileged LXC containers |
| USB storage disable | Containers have no direct hardware access |
| AppArmor changes | Managed at the host level, not inside the container |

## Post-Setup Checklist

- [ ] If SSH was hardened, verify login in a new session before closing the current one
- [ ] Add Proxmox firewall rules for this container if needed (Datacenter → pve → VMID → Firewall)

## Useful Commands

```bash
# Check fail2ban status (if internet-facing)
fail2ban-client status sshd

# Check automatic update logs
cat /var/log/unattended-upgrades/unattended-upgrades.log

# Check logwatch output
logwatch --output stdout --range today

# Verify SSH config
sshd -T | grep -E "permitrootlogin|passwordauthentication|port"
```