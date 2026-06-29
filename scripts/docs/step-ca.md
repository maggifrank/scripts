# step-ca Internal CA

Installs and configures [step-ca](https://smallstep.com/docs/step-ca) as a private Certificate Authority with an ACME provisioner. Services on your network can request and auto-renew TLS certificates just like Let's Encrypt, but fully internal with no internet dependency.

Works on bare metal, VMs, and LXC containers.

## Prerequisites

- Debian/Ubuntu system
- Root or sudo access
- Outbound internet access (to download step-ca binaries)
- A static IP recommended (services need to reach the CA reliably)

## What the Script Asks For

| Prompt | Example | Notes |
|---|---|---|
| CA name | `Homelab CA` | Shown in certificates issued by this CA |
| Server IP | `10.0.0.10` | Auto-detected, shown for confirmation |
| DNS name for CA | `ca.home.lan` | Optional. Recommended if you have local DNS |
| Port | `443` | Default is 443. Ports ≤1024 require capability grant (handled automatically) |
| Provisioner password | — | Silent input, confirmed twice. Protects the CA signing key. Store securely |
| Certificate validity | `2160` | In hours. Default is 2160 = 90 days |

## What It Does

1. Installs `step` CLI and `step-ca` from Smallstep's official releases (latest version, auto-detected)
2. Creates a dedicated `step` system user (no login shell)
3. Initialises the CA with a root and intermediate certificate
4. Configures the ACME provisioner with your chosen certificate validity
5. Grants `step-ca` the ability to bind to port 443 without running as root
6. Creates and enables a hardened systemd service (always-on, restarts on failure)
7. Installs the root CA certificate system-wide via `update-ca-certificates`

## ACME Endpoint

After setup your ACME directory URL will be:

```
https://<CA_IP>:<port>/acme/acme/directory
```

Or if you set a DNS name:
```
https://ca.home.lan:443/acme/acme/directory
```

Use this URL wherever you would normally use Let's Encrypt's ACME endpoint.

## Using with Certbot (internal services)

```bash
certbot certonly \
  --server https://ca.home.lan:443/acme/acme/directory \
  --standalone \
  -d myservice.home.lan
```

## Using with Caddy

```
myservice.home.lan {
  tls {
    ca https://ca.home.lan:443/acme/acme/directory
  }
}
```

## Trusting the Root Certificate

The root cert is installed system-wide on the CA server automatically. For every other device or service that needs to trust certificates issued by this CA, you must install the root cert manually.

**Linux:**
```bash
# Copy from CA server
scp root@<ca-ip>:/etc/step-ca/certs/root_ca.crt /usr/local/share/ca-certificates/step-ca-root.crt
update-ca-certificates
```

**Browser (Chrome/Firefox):**
Import `/etc/step-ca/certs/root_ca.crt` as a trusted CA under Settings → Privacy → Certificates.

**Other LXC containers:**
Run the certbot or ACME client with `--ca-bundle` pointing to the root cert, or install it system-wide as above.

## File Locations

| Path | Purpose |
|---|---|
| `/etc/step-ca/config/ca.json` | Main CA configuration |
| `/etc/step-ca/certs/root_ca.crt` | Root CA certificate (distribute to clients) |
| `/etc/step-ca/certs/intermediate_ca.crt` | Intermediate CA certificate |
| `/etc/step-ca/secrets/` | Encrypted CA keys (never share) |

## Updating

Run the script again on the same system — it will detect the existing installation and run an update instead of a fresh install:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/maggifrank/scripts/main/install.sh)"
```

Select the same script from the menu. No configuration prompts — just updates packages and restarts services.

## Useful Commands

```bash
# Check CA status
systemctl status step-ca

# View logs
journalctl -u step-ca -f

# List provisioners
STEPPATH=/etc/step-ca step ca provisioner list

# Issue a certificate manually
STEPPATH=/etc/step-ca step ca certificate myhost.home.lan cert.pem key.pem

# Inspect a certificate
step certificate inspect cert.pem

# Check CA health
curl -k https://localhost:443/health
```

## Troubleshooting

**step-ca fails to start**
```bash
journalctl -xe -u step-ca
```
Most common cause: port already in use, or wrong file permissions on `/etc/step-ca`.

**Services don't trust certificates**
The root CA certificate must be installed on every client. See "Trusting the Root Certificate" above.

**ACME challenge fails**
Ensure the service requesting a certificate can reach `https://<ca-ip>:<port>` over the network. Check Proxmox firewall rules if traffic is being blocked.

**Renewing the intermediate certificate**
The intermediate cert expires in ~10 years by default. step-ca handles this automatically when running as a service.
