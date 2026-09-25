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
11. Registers the zone it just created with `reverse-map.conf` and `zone-pairs.conf`, so the helper commands below can find it automatically
12. Installs `dns-common.sh` and the `dns-add`, `dns-add-cname`, `dns-add-zone`, `dns-remove`, `dns-remove-zone`, `dns-update`, and `dns-update-cname` helper commands, fetched from this repo (`scripts/bind9-setup/`)

## Managing DNS Records After Setup

Seven helper commands are installed automatically, sharing a common library (`dns-common.sh`). They're zone-aware: pass a zone name as the last argument, or omit it — it's auto-picked if only one zone exists, otherwise you're prompted.

**Add a record:**
```bash
dns-add <hostname> <ip> [zone]
dns-add homeassistant 10.0.0.20
```

**Add a CNAME:**
```bash
dns-add-cname <alias> <target> [zone]
dns-add-cname www homeassistant
```

**Update an existing record:**
```bash
dns-update <hostname> <new-ip> [zone]
dns-update homeassistant 10.0.0.25
```

**Update an existing CNAME's target:**
```bash
dns-update-cname <alias> <new-target> [zone]
dns-update-cname www homeassistant2
```

**Remove a record (A or CNAME):**
```bash
dns-remove <hostname> [zone]
dns-remove homeassistant
```

**Add a new zone** (and its paired reverse zone, if a network prefix is given):
```bash
dns-add-zone <zone> [network-prefix] [-n primary-ns-fqdn] [-e admin-email] [-s secondary-transfer-ip] [-p primary-master-ip] [--secondary-ssh-alias alias] [--no-secondary] [--dry-run]
dns-add-zone lab.talva.is 10.100.54
```

**Remove a zone** (and its paired reverse zone, unless `--forward-only`):
```bash
dns-remove-zone <zone> [network-prefix] [--forward-only] [--keep-files] [--force] [--secondary-ssh-alias alias] [--no-secondary] [--dry-run]
dns-remove-zone lab.talva.is
```

`dns-add-zone`/`dns-remove-zone` default to also replicating the change to a secondary DNS server over SSH (`edge01-ssh` by default, applying it there via a restricted `sudo -n dns-slave-apply` wrapper — see the header comment in `dns-common.sh`). Pass `--no-secondary` to skip that, or review with `--dry-run` first.

All of these bump the affected zone serial(s), validate the zone file, and reload BIND9.

To edit records manually:

```bash
nano /etc/bind/zones/db.yourdomain
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
| `/etc/bind/zones/reverse-map.conf` | `<network-prefix>:<reverse-zone-file>` — lets the helpers find the right reverse zone for a given IP |
| `/etc/bind/zones/zone-pairs.conf` | `<forward-zone>:<reverse-zone>:<network-prefix>` — lets `dns-remove-zone` find a zone's paired reverse zone automatically |
| `/usr/local/bin/dns-common.sh` | Shared library sourced by all the `dns-*` helpers below |
| `/usr/local/bin/dns-add` | Add an A record (+ PTR) |
| `/usr/local/bin/dns-add-cname` | Add a CNAME record |
| `/usr/local/bin/dns-add-zone` | Create a new forward (and optionally reverse) zone |
| `/usr/local/bin/dns-update` | Update an existing A record (+ PTR) |
| `/usr/local/bin/dns-update-cname` | Update an existing CNAME's target |
| `/usr/local/bin/dns-remove` | Remove an A or CNAME record (+ PTR) |
| `/usr/local/bin/dns-remove-zone` | Remove a zone (and its paired reverse zone) |

The source for the `dns-*` helpers lives in this repo at `scripts/bind9-setup/` — the setup script downloads them fresh on every install/update rather than generating them inline.

## Updating

Run the script again on the same system — it will detect the existing installation and run an update instead of a fresh install:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/maggifrank/scripts/main/install.sh)"
```

Select the same script from the menu. No configuration prompts — it updates packages, restarts services, and re-downloads the latest `dns-*` helper scripts.

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
