# Caddy Reverse Proxy

Installs Caddy as a reverse proxy with automatic TLS certificates from Let's Encrypt via Cloudflare DNS-01. No inbound ports required for certificate issuance. Works on bare metal, VMs, and LXC containers.

## Prerequisites

- Debian/Ubuntu system
- Root or sudo access
- A public domain managed by Cloudflare
- A scoped Cloudflare API token (Zone → DNS → Edit for your domain)
- DNS A records pointing subdomains to this server's IP (see Post-Setup)
- Outbound internet access

## What the Script Asks For

| Prompt | Example | Notes |
|---|---|---|
| Public domain | `example.is` | All services will be served under this domain |
| Email | `you@example.com` | Used for Let's Encrypt expiry notices |
| Cloudflare API token | — | Silent input, confirmed twice. Validated before proceeding |
| Initial services | `jellyfin 10.0.0.20:8096` | Subdomain + upstream IP:port. Empty line to finish |

## What It Does

1. Downloads Caddy with the Cloudflare DNS plugin from Caddy's official download API (120s timeout). Falls back to building with `xcaddy` automatically if the download fails or times out.
2. Creates a dedicated `caddy` system user (no login shell)
3. Grants Caddy the ability to bind to ports 80 and 443 without root
4. Stores the Cloudflare API token securely at `/etc/caddy/cloudflare.env` (chmod 600)
5. Writes a `Caddyfile` with per-site `tls { dns cloudflare }` blocks and a reverse proxy directive
6. Validates the Caddyfile before starting
7. Creates and enables a hardened systemd service with auto-restart
8. Installs the `caddy-add-service` helper command

## Adding Services After Setup

Use the helper:
```bash
caddy-add-service <subdomain> <ip:port>
```

Example:
```bash
caddy-add-service jellyfin 10.0.0.20:8096
caddy-add-service proxmox 10.0.0.1:8006
caddy-add-service homeassistant 10.0.0.30:8123
```

This appends the service to the Caddyfile, validates it, and reloads Caddy. The certificate is requested automatically.

Or edit the Caddyfile directly:
```bash
nano /etc/caddy/Caddyfile
systemctl reload caddy
```

## Caddyfile Format

Each service is a block with a `tls` directive for Cloudflare DNS-01:

```
jellyfin.example.is {
    tls {
        dns cloudflare {env.CLOUDFLARE_API_TOKEN}
    }
    reverse_proxy 10.0.0.20:8096
}
```

Caddy requests and renews the certificate automatically — no manual cert management needed.

## Post-Setup — DNS Records

For each service, add an A record in Cloudflare:

| Type | Name | Value | Proxy |
|---|---|---|---|
| A | jellyfin | `<caddy server IP>` | DNS only (grey cloud) |
| A | proxmox | `<caddy server IP>` | DNS only (grey cloud) |

> Set to **DNS only** (not proxied through Cloudflare) — Caddy handles TLS itself and doesn't need Cloudflare's proxy.

## File Locations

| Path | Purpose |
|---|---|
| `/etc/caddy/Caddyfile` | Main configuration — add services here |
| `/etc/caddy/cloudflare.env` | Cloudflare API token (root readable only) |
| `/var/lib/caddy` | Caddy data directory (certificates stored here) |
| `/var/log/caddy` | Log directory |
| `/usr/local/bin/caddy-add-service` | Helper to add new services |

## Useful Commands

```bash
# Check Caddy status
systemctl status caddy

# View live logs
journalctl -u caddy -f

# Reload after editing Caddyfile
systemctl reload caddy

# Validate Caddyfile without restarting
caddy validate --config /etc/caddy/Caddyfile

# List current certificates
caddy list-certificates

# Add a new service
caddy-add-service <subdomain> <ip:port>
```

## Troubleshooting

**Certificate not being issued**
- Check DNS record exists and points to this server: `dig subdomain.yourdomain.is`
- Make sure the Cloudflare token has DNS Edit permission for the zone
- Check Caddy logs: `journalctl -u caddy -f`

**502 Bad Gateway**
- The upstream service is unreachable — check the IP and port are correct
- Verify the service is running: `curl http://10.0.0.20:8096`

**Caddy fails to start**
```bash
journalctl -xe -u caddy
caddy validate --config /etc/caddy/Caddyfile
```

**Proxmox WebUI behind Caddy**
Proxmox uses a self-signed cert on port 8006. Tell Caddy to skip upstream TLS verification:
```
proxmox.example.is {
    reverse_proxy 10.0.0.1:8006 {
        transport http {
            tls_insecure_skip_verify
        }
    }
}
```