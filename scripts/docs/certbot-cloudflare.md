# Certbot + Cloudflare DNS

Sets up a Let's Encrypt certificate using the Cloudflare DNS-01 challenge. No inbound ports or open firewall rules required — only outbound internet access.

## Prerequisites

- Debian/Ubuntu system (bare metal, VM, or LXC)
- Outbound internet access
- A domain managed by Cloudflare
- A scoped Cloudflare API token (see below)

## Create a Cloudflare API Token

1. Log in to [Cloudflare Dashboard](https://dash.cloudflare.com)
2. Click your profile icon (top right) → **My Profile**
3. Go to the **API Tokens** tab
4. Click **Create Token**
5. Click **Use template** next to **Edit zone DNS**
6. Under **Zone Resources** → set to **Specific zone** → select your domain
7. Optionally set an expiry date for extra safety
8. Click **Continue to summary → Create Token**
9. Copy the token — it is only shown once

> Use a scoped token, not your Global API Key. The token only needs `Zone → DNS → Edit` on your specific domain.

## What the Script Asks For

| Prompt | Example |
|---|---|
| Domain | `example.com` |
| Wildcard cert | `y` or `n` |
| Email address | `you@example.com` |
| Cloudflare API token | _(typed silently, confirmed twice)_ |

## What It Does

1. Validates the Cloudflare API token before doing anything
2. Installs `certbot` and `python3-certbot-dns-cloudflare`
3. Writes credentials to `/root/.secrets/cloudflare.ini` (chmod 600, dir chmod 700)
4. Requests a certificate (and wildcard if chosen)
5. Runs a renewal dry-run to confirm auto-renewal works
6. Hardens `/etc/letsencrypt` directory permissions

## Certificate Locations

```
/etc/letsencrypt/live/yourdomain.com/fullchain.pem
/etc/letsencrypt/live/yourdomain.com/privkey.pem
```

## Auto-Renewal

Handled automatically by `certbot.timer` (systemd). Falls back to a cron job if the timer is not available. Certificates renew every 60 days.

Check renewal status:
```bash
systemctl status certbot.timer
certbot certificates
```

## Security Notes

- The API token is stored at `/root/.secrets/cloudflare.ini` — readable by root only
- Token is never echoed to the terminal during input
- Token is unset from memory immediately after being written to disk
- Never commit `/root/.secrets/` to version control
