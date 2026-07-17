# Offsite PBS NFS Repo

Provisions an unprivileged LXC container on the local `local-lvm` thin pool and configures it to serve an NFS export, intended as a datastore target for an offsite Proxmox Backup Server (PBS) DR copy.

Used on hosts with no spare/dedicated disk — the export lives on a CT rootfs volume carved out of the existing thin pool, same as any other CT on the box. There's no ZFS underneath, so this relies on PBS verify jobs (rather than a local scrub) to catch corruption.

Run this on the Proxmox host that will hold the offsite repo (not on the primary PBS host).

## What it asks for

- **Mount client IP** — the IP of the host that will mount this NFS share (usually the offsite Proxmox host running PBS, or its Tailscale IP)
- **Volume size (GB)** — rootfs size cap for the CT; size deliberately, since the thin pool is shared with everything else on the host
- **IP address** — CT's static IP, no mask
- **Subnet mask bits** — defaults to `24`
- **Gateway** — defaults to `.254` on the entered subnet
- **Nameserver(s)** — defaults to `10.100.53.34 10.100.53.41`
- **Search domain** — defaults to `talva.is`

VMID is not prompted for — it's auto-assigned via `pvesh get /cluster/nextid` unless hardcoded in the script's config block.

The script prints a summary and asks for confirmation before creating anything, and again after showing thin-pool free space, before allocating the volume.

## What it does

1. Checks `pve-data-tpool` free space and asks you to confirm there's room
2. Downloads the Debian 13 CT template if not already cached
3. Creates the unprivileged CT with the given network settings
4. Installs `nfs-kernel-server` inside the CT
5. Creates `/data` as the export directory
6. Writes `/etc/exports`, restricting the export to the single client IP provided (never a whole subnet, for a DR datastore)
7. Applies the export and enables the NFS service

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