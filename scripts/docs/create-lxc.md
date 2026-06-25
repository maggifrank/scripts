# Create Proxmox LXC

Interactively creates a Proxmox LXC container with sensible defaults. Automatically updates the container and installs `curl` and `wget` after creation so it is immediately ready to use.

> **Must be run on the Proxmox host**, not inside a container.

## Prerequisites

- Proxmox VE host
- Root access on the host
- At least one Ubuntu or Debian template downloaded in local storage

### Downloading a template (if needed)

```bash
pveam update
pveam available --section system | grep ubuntu
pveam download local ubuntu-24.04-standard_24.04-2_amd64.tar.zst
```

## What the Script Asks For

| Prompt | Default | Notes |
|---|---|---|
| Container ID | Next available | Auto-suggested via `pvesh get /cluster/nextid` |
| Hostname | — | Letters, numbers, and hyphens only |
| Template | — | Lists available Ubuntu/Debian templates to pick from |
| Storage pool | `local-lvm` | Where the container disk is stored |
| Disk size | `8GB` | — |
| RAM | `512MB` | — |
| Swap | `512MB` | — |
| CPU cores | `1` | — |
| Network bridge | `vmbr0` | — |
| IP configuration | DHCP | Choose DHCP or static IP with gateway |
| DNS server | `1.1.1.1` | Upstream resolver for the container |
| Container type | Unprivileged | Unprivileged is recommended for security |
| Nesting | No | Enable if running Docker inside the container |
| Root password | — | Silent input, confirmed twice |
| SSH public key | — | Optional. Written to a temp file and passed to `pct create`, then deleted |

## What It Does

1. Suggests the next available VMID
2. Lists available templates to choose from
3. Walks through all configuration options with sensible defaults
4. Shows a full review summary before creating anything
5. Creates the container and starts it
6. Waits for the container to be running
7. Runs `apt update`, `apt upgrade`, and installs `curl` and `wget` inside the container automatically

## After Creation

The container is started automatically and set to start on boot (`--onboot 1`).

```bash
# Open a shell inside the container
pct enter <vmid>

# Check container status
pct status <vmid>

# Stop the container
pct stop <vmid>

# Start the container
pct start <vmid>

# View container config
cat /etc/pve/lxc/<vmid>.conf

# Destroy the container (stop it first)
pct stop <vmid> && pct destroy <vmid>
```

## Network Notes

- **DHCP:** The container will get an IP from your router. Check your router's DHCP leases to find the assigned IP.
- **Static IP:** Use CIDR notation e.g. `10.0.0.50/24` and provide the gateway IP.

## Recommended Next Step

Once the container is running, harden it with the LXC hardening script:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/maggifrank/scripts/main/install.sh)"
# Select: LXC Container Hardening
```