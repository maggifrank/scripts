# Offsite PBS NFS Repo

Provisions a VM (Debian cloud image + cloud-init) on the local `local-lvm` thin pool and configures it to serve an NFS export, intended as a datastore target for an offsite Proxmox Backup Server (PBS) DR copy.

Used on hosts with no spare/dedicated disk — the export lives on a VM virtual disk carved out of the existing thin pool, same allocation mechanism as any other VM on the box. There's no ZFS underneath, so this relies on PBS verify jobs (rather than a local scrub) to catch corruption.

**Why a VM and not an LXC CT:** `nfsd` is a kernel-side service. Unprivileged LXC containers share the host's kernel and are deliberately blocked from mounting the `/proc/fs/nfsd` pseudo-filesystem it needs — this is not a config gap, it's by design. A privileged CT with a custom AppArmor profile can work around it, but is fragile and gives up most of the isolation a CT exists for in the first place. A VM has its own kernel, so `nfsd` just runs, no workarounds needed.

**Why not run `nfsd` directly on the Proxmox host:** keeps the host's own package/service footprint untouched — this is meant to be a disposable, drop-in box, not something entangled with the hypervisor OS.

Run this on the Proxmox host that will hold the offsite repo (not on the primary PBS host).

## Requirements on the host

- Outbound internet access to `cloud.debian.org` (to fetch the cloud image — one-time, cached after)
- `local` storage needs the `snippets` content type enabled — the script checks and enables it automatically if missing

## What it asks for

- **Mount client IP** — the IP of the host that will mount this NFS share (usually the offsite Proxmox host running PBS, or its Tailscale IP)
- **Bridge** — lists bridges detected on the host (`ip -o link show type bridge`) and lets you pick one; defaults to `vmbr0` if present
- **Disk size (GB)** — VM disk size cap; size deliberately, since the thin pool is shared with everything else on the host
- **IP address** — VM's static IP, no mask
- **Subnet mask bits** — defaults to `24`
- **Gateway** — defaults to `.254` on the entered subnet
- **Nameserver(s)** — defaults to `10.100.53.34 10.100.53.41`
- **Search domain** — defaults to `talva.is`
- **Root password** — set via cloud-init, entered twice, hidden input; used for console/SSH access

VMID is not prompted for — it's auto-assigned via `pvesh get /cluster/nextid` unless hardcoded in the script's config block.

The script prints a summary and asks for confirmation before creating anything, and again after showing thin-pool free space, before allocating the disk.

## What it does

1. Checks thin pool free space and asks you to confirm there's room
2. Enables the `snippets` content type on `local` storage if not already enabled
3. Downloads the Debian 13 generic cloud image if not already cached
4. Writes a cloud-init snippet that installs `nfs-kernel-server`, writes `/etc/exports` restricted to the given client IP, and enables the service
5. Creates the VM, imports the cloud image as its disk, attaches the cloud-init drive, resizes the disk to the requested size
6. Starts the VM
7. Waits for the QEMU guest agent to respond (up to 3 minutes) — fails with a clear message if it doesn't (usually a network/bridge misconfiguration or cloud-init failure)
8. Waits for cloud-init to finish (`cloud-init status --wait`)
9. Verifies `nfs-kernel-server` is active via the guest agent; warns if not

## If Provisioning Fails Partway

The script is **not idempotent** — re-running it after a failure creates a brand new VM (new auto-assigned VMID) rather than resuming the existing one. If it fails after the VM is already created:

1. Fix the underlying issue directly (e.g. `qm set <VMID> --net0 ...` for a wrong bridge, then `qm reboot <VMID>`)
2. Check cloud-init's own log for package/config failures: `qm guest exec <VMID> -- cat /var/log/cloud-init-output.log`
3. Clean up any duplicate VM created by an accidental re-run

## Post-setup steps (manual)

1. Add a DNS record for the VM (`dns-add <hostname> <ip> talva.is`)
2. On the mounting host, mount with `hard,intr` — not `soft` — to avoid corruption on brief link blips:
   ```
   mount -t nfs -o hard,intr <hostname>.talva.is:/data /mnt/pbs-offsite
   ```
   Add to `/etc/fstab` or an automount unit so it survives reboot.
3. In PBS, add the mounted path as a new datastore
4. In PBS, create a sync job from the primary datastore to this one
5. Wire up thin-pool free-space alerting on the host, since the VM's disk shares capacity with everything else there
6. Schedule/confirm a PBS verify job runs against this datastore — this is the integrity check standing in for ZFS scrub

## If the NFS Client's IP Changes

The client IP is only enforced in `/etc/exports` inside the VM — not stored anywhere else. To update it:

```
qm guest exec <VMID> -- bash -c "echo '/data <new-ip>(rw,sync,no_subtree_check,no_root_squash)' > /etc/exports"
qm guest exec <VMID> -- bash -c "exportfs -ra"
```

`exportfs -ra` re-applies live — no service restart needed.

- An already-mounted client keeps working until it unmounts/remounts; new mount attempts are checked against the updated IP immediately.
- If the mount is moving to a different host entirely, also update the mount command and `/etc/fstab`/automount entry on the new host, and remove the old entry on whichever host is being replaced.
- Multiple client lines can be added under `/data` if more than one consumer ever needs to mount the same share — one line per client IP with its own options.