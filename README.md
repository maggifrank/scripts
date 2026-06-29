# Homelab Scripts

A collection of setup and maintenance scripts for self-hosted infrastructure. Run any script via the interactive installer with a single command.

## Quick Start

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/maggifrank/scripts/main/install.sh)"
```

A menu will appear — select a number to run a script. That's it.

> Some scripts require root. The installer will escalate automatically if needed.

---

## Available Scripts

| Script | Description | Docs |
|---|---|---|
| Certbot + Cloudflare DNS | Let's Encrypt certificates via Cloudflare DNS-01 | [docs](scripts/docs/certbot-cloudflare.md) |
| Ubuntu Server Hardening | Security best practices for fresh Ubuntu installs (VM or bare metal) | [docs](scripts/docs/ubuntu-hardening.md) |
| LXC Container Hardening | Lightweight hardening for LXC containers | [docs](scripts/docs/lxc-hardening.md) |
| BIND9 Local DNS | Local DNS server with forwarder and split-horizon | [docs](scripts/docs/bind9.md) |
| Create Proxmox LXC | Interactively create a Proxmox LXC container (run on Proxmox host) | [docs](scripts/docs/create-lxc.md) |
| step-ca Internal CA | Internal CA with ACME support for automatic TLS certificates | [docs](scripts/docs/step-ca.md) |
| Caddy Reverse Proxy | Reverse proxy with automatic Let's Encrypt TLS via Cloudflare DNS-01 | [docs](scripts/docs/caddy.md) |

---

## Adding a New Script

### 1. Create the script

Add your script to `scripts/`:

```
scripts/my-new-script.sh
```

Make sure it:
- Has a shebang: `#!/bin/bash`
- Handles its own dependencies and errors
- Does not assume prior state

### 2. Add a doc file

Create `scripts/docs/my-new-script.md` describing what it does, what it asks for, and any post-setup steps. Use the existing docs as a template.

### 3. Register it in `manifest.json`

```json
{
  "name": "My New Script",
  "file": "my-new-script.sh",
  "description": "One-line description shown in the menu.",
  "requires_root": true
}
```

| Field | Type | Description |
|---|---|---|
| `name` | string | Display name in the menu |
| `file` | string | Filename inside `scripts/` |
| `description` | string | One-line description |
| `requires_root` | bool | Auto-escalates to sudo if true |

### 4. Push to GitHub

```bash
git add scripts/my-new-script.sh scripts/docs/my-new-script.md manifest.json
git commit -m "Add my-new-script"
git push
```

The menu picks it up automatically.

---

## Repository Structure

```
scripts/
├── install.sh          # Entrypoint — the one-liner target
├── manifest.json       # Script registry
├── README.md           # This file
└── scripts/
    ├── certbot-cloudflare-setup.sh
    ├── ubuntu-server-hardening.sh
    ├── lxc-hardening.sh
    ├── bind9-setup.sh
    ├── create-lxc.sh
    ├── step-ca-setup.sh
    ├── caddy-setup.sh
    └── docs/
        ├── certbot-cloudflare.md
        ├── ubuntu-hardening.md
        ├── lxc-hardening.md
        ├── bind9.md
        ├── create-lxc.md
        ├── step-ca.md
        └── caddy.md
```

---

## Security

- Scripts are downloaded to a temp file, executed, then shredded on exit
- The full script URL is shown and confirmed before anything runs
- No secrets are stored in this repo — scripts prompt for sensitive input at runtime
- API tokens and passwords are never echoed to the terminal

---

## License

MIT