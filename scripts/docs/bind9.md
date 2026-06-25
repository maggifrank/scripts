# BIND9 Local DNS + Forwarder

Installs and configures BIND9 as a local DNS server with split-horizon. Internal hostnames resolve to local IPs; everything else forwards to upstream resolvers. Works on bare metal, VMs, and LXC containers.

## Prerequisites

- Debian/Ubuntu system
- Root or sudo access
- A static IP on this machine
- LXC only: **Nesting** enabled in Proxmox (Features → tick Nesting)

## What the Script Asks For

| Prompt | Example | Notes |
|---|---|---|
| Local domain | `talva.lan`, `talva.is`, `home.talva.is` | Any valid domain format. Used for all internal records |
| Server IP | `10.0.0.53` | Auto-detected. If one IP found, shown for confirmation. If multiple, shown as a numbered list to pick from. Manual entry always available |
| Local subnet | `10.0.0.0/24` | Auto-detected from server IP. Shown for confirmation, can be overridden |
| Forwarder IPs | `1.1.1.1`, `8.8.8.8` | Upstream DNS for unknown names. Defaults to Cloudflare + Google if left blank |
| Initial A records | `proxmox 10.0.0.10` | hostname + IP pairs, one per line. Empty line to finish |

## What It Does

1. Installs `bind9`, `bind9utils`, `dnsutils`
2. Installs `haveged` to ensure sufficient entropy (important for LXC containers)
3. Disables the AppArmor BIND9 profile if present (prevents LXC confinement conflicts)
4. Backs up any existing BIND9 config
5. Writes `named.conf.options` with ACL, forwarders, and security settings
6. Writes `named.conf.local` with forward and reverse zone definitions
7. Creates zone files with all A records and PTR records you entered
8. Validates config with `named-checkconf` and `named-checkzone`
9. Starts and enables BIND9
10. Tests local resolution and forwarder connectivity
11. Installs the `dns-add` helper command

## Adding DNS Records After Setup

Use the included helper:

```bash
dns-add <hostname> <ip>
```

Example:
```bash
dns-add homeassistant 10.0.0.20
```

This adds both the A record and PTR record, bumps the zone serial, and reloads BIND9 automatically.

To remove or edit records manually, edit the zone files directly:

```bash
nano /etc/bind/zones/db.yourdomain
# make changes, then:
rndc reload
```

## Pointing Devices to This DNS Server

**Router (recommended):** Set the DNS server in your router's DHCP settings to the IP of this machine. All devices on the network will use it automatically.

**Individual device:** Set DNS manually to the server IP in network settings.

**Test it:**
```bash
dig @<server-ip> hostname.yourdomain
dig @<server-ip> google.com
```

## File Locations

| File | Purpose |
|---|---|
| `/etc/bind/named.conf.options` | ACL, forwarders, global options |
| `/etc/bind/named.conf.local` | Zone definitions |
| `/etc/bind/zones/db.<domain>` | Forward zone records |
| `/etc/bind/zones/db.<reverse>` | Reverse zone PTR records |
| `/usr/local/bin/dns-add` | Helper to add records |

## Useful Commands

```bash
# Check BIND9 status
systemctl status bind9

# Reload after manual zone edits
rndc reload

# Check config syntax
named-checkconf
named-checkzone yourdomain /etc/bind/zones/db.yourdomain

# Test resolution
dig @127.0.0.1 hostname.yourdomain
dig @127.0.0.1 google.com

# View BIND9 logs
journalctl -u bind9 -f
```

## Troubleshooting

**BIND9 fails to start — service name mismatch**
On some Ubuntu versions the service is called `named` rather than `bind9`. The script detects this automatically, but if you're running commands manually check which one applies:
```bash
systemctl status named   # try this first
systemctl status bind9   # or this
```

**BIND9 fails to start on LXC**
Check AppArmor — the script handles this automatically, but if it persists:
```bash
journalctl -xe -u bind9
aa-status | grep named
```

**Queries not resolving from other devices**
- Confirm UFW allows port 53: `ufw allow 53/tcp && ufw allow 53/udp`
- Confirm the querying device is in the allowed subnet
- Test from the server itself first: `dig @127.0.0.1 hostname.yourdomain`

**Forwarder not working**
- Check outbound connectivity: `curl -s https://1.1.1.1`
- Verify forwarder IPs in `/etc/bind/named.conf.options`