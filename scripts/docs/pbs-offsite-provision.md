# Offsite PBS NFS Repo

Provisions an unprivileged LXC container on the local `local-lvm` thin pool and configures it to serve an NFS export, intended as a datastore target for an offsite Proxmox Backup Server (PBS) DR copy.

Used on hosts with no spare/dedicated disk — the export lives on a CT rootfs volume carved out of the existing thin pool, same as any other CT on the box. There's no ZFS underneath, so this relies on PBS verify jobs (rather than a local scrub) to catch corruption.

Run this on the Proxmox host that will hold the offsite repo (not on the primary PBS host).

## What it asks for

- **Mount client IP** — the IP of the host that will mount this NFS share (usually the offsite Proxmox host running PBS, or its Tailscale IP)
- **Bridge** — lists bridges detected on the host (`ip -o link show type bridge`) and lets you pick one; defaults to `vmbr0` if present
- **Volume size (GB)** — rootfs size cap for the CT; size deliberately, since the thin pool is shared with everything else on the host
- **IP address** — CT's static IP, no mask
- **Subnet mask bits** — defaults to `24`
- **Gateway** — defaults to `.254` on the entered subnet
- **Nameserver(s)** — defaults to `10.100.53.34 10.100.53.41`
- **Search domain** — defaults to `talva.is`
- **Root password** — set at the end of provisioning so console (`pct enter`/Proxmox UI console) access works immediately; entered twice, hidden input

VMID is not prompted for — it's auto-assigned via `pvesh get /cluster/nextid` unless hardcoded in the script's config block.

The script prints a summary and asks for confirmation before creating anything, and again after showing thin-pool free space, before allocating the volume.

## What it does

1. Checks `pve-data-tpool` free space and asks you to confirm there's room
2. Downloads the Debian 13 CT template if not already cached
3. Creates the unprivileged CT with the given network settings
4. Starts the CT, then **waits for the gateway to be reachable** (polls for up to 60s) before doing anything else — fails with a clear diagnostic message (wrong bridge, IP/gateway mismatch, etc.) instead of hanging on a DNS timeout inside `apt install`
5. Checks whether DNS resolution actually works inside the CT; warns and asks for confirmation before continuing if not
6. Sets the root password
7. Installs `nfs-kernel-server` inside the CT
8. Creates `/data` as the export directory
9. Writes `/etc/exports`, restricting the export to the single client IP provided (never a whole subnet, for a DR datastore)
10. Applies the export and enables the NFS service

## If Provisioning Fails Partway

The script is **not idempotent** — re-running it after a failure creates a brand new CT (new auto-assigned VMID) rather than resuming the existing one. If it fails after the CT is already created (e.g. wrong bridge selected, gateway unreachable), don't re-run the whole script. Instead:

1. Fix the underlying issue directly, e.g.:
   ```
   pct set <VMID> --net0 name=eth0,bridge=<correct-bridge>,ip=<ip>/<mask>,gw=<gw>
   pct reboot <VMID>
   ```
2. Continue the remaining steps manually against the existing CT (installing `nfs-kernel-server`, writing `/etc/exports`, etc. — see the script body for the exact commands).
3. Clean up any duplicate CT created by an accidental re-run.

## Post-setup steps (manual)

1. Add a DNS record for the CT (`dns-add <hostname> <ip> talva.is`)
2. On the mounting host, mount with `hard,intr` — not `soft` — to avoid corruption on brief link blips:
   ```
   mount -t nfs -o hard,intr <hostname>.talva.is:/data /mnt/pbs-offsite
   ```
   Add to `/etc/fstab` or an automount unit so it survives reboot.
3. In PBS, add the mounted path as a new datastore
4. In PBS, create a sync job from the primary datastore to this one
5. Wire up thin-pool free-space alerting on the host, since the CT's growth shares capacity with everything else there
6. Schedule/confirm a PBS verify job runs against this datastore — this is the integrity check standing in for ZFS scrub