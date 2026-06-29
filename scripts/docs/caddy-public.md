# Caddy Public Reverse Proxy

Installs Caddy as a public-facing reverse proxy with automatic TLS certificates from Let's Encrypt via HTTP-01 challenge. No Cloudflare or DNS configuration needed — just open ports 80 and 443.

Use this for servers with a public IP and inbound internet access. For internal/homelab use without open ports, use [caddy-setup.sh](caddy.md) instead.

## Prerequisites

- Debian/Ubuntu system (VPS, bare metal, or public-facing VM)
- Root or sudo access
- Ports **80 and 443 open inbound** from the internet
- DNS A records pointing each domain to this server's public IP
- Outbound internet access

## What the Script Asks For

| Prompt | Example | Notes |
|---|---|---|
| Email | `you@example.com` | Used for Let's Encrypt expiry notices |
| Initial services | `mysite.com 10.0.0.20:8080` | Full domain + upstream IP:port. Empty line to finish |

No Cloudflare token needed — Let's Encrypt verifies ownership via HTTP-01 on port 80.

## What It Does

1. Installs Caddy from the official apt repository — no plugin compilation needed
2. Creates a dedicated `caddy` system user (no login shell)
3. Grants Caddy the ability to bind to ports 80 and 443 without root
4. Writes a `Caddyfile` with one block per service — Caddy handles TLS automatically
5. Validates the Caddyfile before starting
6. Creates and enables a hardened systemd service with auto-restart
7. Installs the `caddy-add-service` helper command

## Adding Services After Setup

```bash
caddy-add-service <domain> <ip:port>
```

Example:
```bash
caddy-add-service mysite.com 10.0.0.20:8080
caddy-add-service api.mysite.com 10.0.0.20:3000
```

The certificate is requested automatically on first request to port 80.

## Caddyfile Format

Much simpler than the internal version — no TLS block needed:

```
mysite.com {
    reverse_proxy 10.0.0.20:8080
}
```

Caddy handles everything — HTTP to HTTPS redirect, certificate issuance, and renewal.

## DNS Records

For each service, add an A record pointing to this server's **public IP**:

| Type | Name | Value |
|---|---|---|
| A | mysite.com | `<public IP of this server>` |
| A | api.mysite.com | `<public IP of this server>` |

## Redirects

To redirect one domain to another:

```
www.mysite.com {
    redir https://mysite.com{uri} permanent
}
```

## File Locations

| Path | Purpose |
|---|---|
| `/etc/caddy/Caddyfile` | Main configuration |
| `/var/lib/caddy` | Certificate storage |
| `/var/log/caddy` | Log directory |
| `/usr/local/bin/caddy-add-service` | Helper to add new services |

## Updating

Run the script again — it detects the existing installation and updates only:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/maggifrank/scripts/main/install.sh)"
```

## Useful Commands

```bash
# Check Caddy status
systemctl status caddy

# View live logs
journalctl -u caddy -f

# Reload after editing Caddyfile
systemctl reload caddy

# Validate Caddyfile
caddy validate --config /etc/caddy/Caddyfile

# List current certificates
caddy list-certificates

# Add a new service
caddy-add-service <domain> <ip:port>
```

## Troubleshooting

**Certificate not being issued**
- Confirm port 80 is open inbound: `curl http://yourdomain.com` from an external machine
- Confirm DNS A record points to this server's public IP: `dig yourdomain.com`
- Check Caddy logs: `journalctl -u caddy -f`

**502 Bad Gateway**
- Upstream service is unreachable — check IP and port
- Verify the service is running: `curl http://10.0.0.20:8080`

**Caddy fails to start**
```bash
journalctl -xe -u caddy
caddy validate --config /etc/caddy/Caddyfile
```
