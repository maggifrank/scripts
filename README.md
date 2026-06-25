# 🖥️ Homelab Scripts

A collection of setup and maintenance scripts for self-hosted infrastructure.

## Usage

Run the interactive installer with a single command:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/maggifrank/scripts/main/install.sh)"
```

A menu will appear listing all available scripts. Select a number to run it.

> **Note:** Some scripts require root. The installer will prompt for sudo automatically if needed.

---

## Available Scripts

| Script | Description | Requires Root |
|---|---|---|
| Certbot + Cloudflare DNS | Set up Let's Encrypt certificates via Cloudflare DNS-01. No inbound ports required. | Yes |

---

## Adding a New Script

### 1. Create the script

Add your script to the `scripts/` folder:

```
scripts/my-new-script.sh
```

Make sure it:
- Has a shebang line: `#!/bin/bash`
- Handles its own dependencies and error checking
- Does not assume any prior state

### 2. Register it in `manifest.json`

Add an entry to `manifest.json` at the root of the repo:

```json
[
  {
    "name": "My New Script",
    "file": "my-new-script.sh",
    "description": "Short description shown in the menu.",
    "requires_root": true
  }
]
```

| Field | Description |
|---|---|
| `name` | Display name shown in the menu |
| `file` | Filename inside the `scripts/` folder |
| `description` | One-line description shown under the name |
| `requires_root` | `true` or `false` — installer will auto-escalate if needed |

### 3. Push to GitHub

```bash
git add scripts/my-new-script.sh manifest.json
git commit -m "Add my-new-script"
git push
```

The menu picks it up automatically — no changes to `install.sh` needed.

---

## Repo Structure

```
scripts/
├── install.sh                      # Entrypoint — the one-liner target
├── manifest.json                   # Registry of available scripts
├── README.md                       # This file
└── scripts/
    ├── certbot-cloudflare-setup.sh
    └── ...
```

---

## Security

- The installer shows the full script URL and asks for confirmation before running anything
- Scripts are downloaded to a temp file, executed, then shredded on exit
- No secrets are stored in this repo — scripts prompt for sensitive input at runtime
- API tokens and credentials are never echoed to the terminal