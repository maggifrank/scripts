#!/usr/bin/env bash
#
# pbs-offsite-provision.sh
#
# Provisions an unprivileged LXC CT on the local-lvm thin pool to serve
# an NFS export used as a PBS offsite-DR datastore target.
#
# Pattern: no spare/dedicated disk on the Proxmox host, so the export
# lives on a CT rootfs volume carved out of the existing thin pool
# (same allocation mechanism as any other VM/CT on the host).
# No ZFS underneath -> relying on PBS verify jobs for integrity checking,
# not local scrub.
#
# Usage: edit the static config block below if needed, then run as root
# on the target Proxmox host (e.g. b2-pve02). VMID, volume size, and
# network settings are prompted for interactively at runtime.

set -euo pipefail

### --- Static config: edit if it differs per box ------------------------
VMID=                      # leave blank to auto-assign the next available VMID
HOSTNAME="pbs-nfs"          # CT hostname
BRIDGE="vmbr0"
TEMPLATE_STORAGE="local"
TEMPLATE=                   # leave blank to auto-resolve the current debian-13 template
ROOTFS_STORAGE="local-lvm"

DNS_ZONE="talva.is"
DNS_HOSTNAME="pbs-nfs"       # -> pbs-nfs.talva.is, add via dns-add once IP is known

# Restrict the NFS export to the specific offsite Proxmox host that will
# mount it - never export to a whole subnet for a DR datastore.
NFS_CLIENT_IP=               # e.g. 10.100.53.10 or the Tailscale IP of the mounting host
### -----------------------------------------------------------------------

if [ -z "$NFS_CLIENT_IP" ]; then
  read -rp "IP of the host that will mount this NFS share: " NFS_CLIENT_IP
fi
[ -n "$NFS_CLIENT_IP" ] || { echo "ERROR: NFS_CLIENT_IP is required." >&2; exit 1; }

if [ -z "$VMID" ]; then
  VMID="$(pvesh get /cluster/nextid)"
  echo "==> No VMID set, auto-assigned next available: $VMID"
fi

echo
echo "==> Network and volume settings for this CT:"
read -rp "  Volume size in GB: " CT_SIZE_GB
read -rp "  IP address (no mask): " CT_IPADDR
read -rp "  Subnet mask bits [24]: " CT_MASK
CT_MASK="${CT_MASK:-24}"

CT_GW_DEFAULT="$(echo "$CT_IPADDR" | awk -F. '{print $1"."$2"."$3".254"}')"
read -rp "  Gateway [${CT_GW_DEFAULT}]: " CT_GW
CT_GW="${CT_GW:-$CT_GW_DEFAULT}"

read -rp "  Nameserver(s) [10.100.53.34 10.100.53.41]: " CT_NS
CT_NS="${CT_NS:-10.100.53.34 10.100.53.41}"

read -rp "  Search domain [${DNS_ZONE}]: " CT_SEARCHDOMAIN
CT_SEARCHDOMAIN="${CT_SEARCHDOMAIN:-$DNS_ZONE}"

for var in CT_SIZE_GB CT_IPADDR; do
  if [ -z "${!var}" ]; then
    echo "ERROR: $var cannot be empty." >&2
    exit 1
  fi
done

CT_IP="${CT_IPADDR}/${CT_MASK}"

echo
echo "==> Summary:"
echo "    VMID:          $VMID"
echo "    Hostname:      $HOSTNAME"
echo "    Volume size:   ${CT_SIZE_GB}G"
echo "    IP/mask:       $CT_IP"
echo "    Gateway:       $CT_GW"
echo "    Nameserver:    $CT_NS"
echo "    Search domain: $CT_SEARCHDOMAIN"
echo "    NFS client:    $NFS_CLIENT_IP"
read -rp "Proceed with these settings? [y/N] " confirm_settings
[ "$confirm_settings" = "y" ] || { echo "Aborted."; exit 1; }

echo "==> Checking thin pool headroom before allocating..."
pvesm status
lvs -a | grep pve-data || true
echo
read -rp "Confirm there is enough free space in pve-data-tpool for ${CT_SIZE_GB}G. Continue? [y/N] " ok
[ "$ok" = "y" ] || { echo "Aborted."; exit 1; }

echo "==> Resolving current debian-13 template..."
pveam update >/dev/null

if [ -z "$TEMPLATE" ]; then
  TEMPLATE="$(pveam available --section system | awk '{print $2}' | grep '^debian-13-standard_' | sort -V | tail -1)"
  if [ -z "$TEMPLATE" ]; then
    echo "ERROR: could not find a debian-13-standard template in 'pveam available'." >&2
    exit 1
  fi
  echo "    Using: $TEMPLATE"
fi

echo "==> Downloading template (if not already cached)..."
if ! pveam list "$TEMPLATE_STORAGE" | grep -q "$TEMPLATE"; then
  pveam download "$TEMPLATE_STORAGE" "$TEMPLATE"
fi

if ! pveam list "$TEMPLATE_STORAGE" | grep -q "$TEMPLATE"; then
  echo "ERROR: template $TEMPLATE is not present on $TEMPLATE_STORAGE after download attempt." >&2
  exit 1
fi

echo "==> Creating CT $VMID ($HOSTNAME)..."
pct create "$VMID" "${TEMPLATE_STORAGE}:vztmpl/${TEMPLATE}" \
  --hostname "$HOSTNAME" \
  --storage "$ROOTFS_STORAGE" \
  --rootfs "${ROOTFS_STORAGE}:${CT_SIZE_GB}" \
  --unprivileged 1 \
  --features nesting=0 \
  --nameserver "$CT_NS" \
  --searchdomain "$CT_SEARCHDOMAIN" \
  --net0 "name=eth0,bridge=${BRIDGE},ip=${CT_IP},gw=${CT_GW}"

echo "==> Starting CT..."
pct start "$VMID"
sleep 5

echo "==> Installing nfs-kernel-server inside CT..."
pct exec "$VMID" -- bash -c "apt update && apt install -y nfs-kernel-server"

echo "==> Creating export directory..."
pct exec "$VMID" -- bash -c "mkdir -p /data && chown nobody:nogroup /data"

echo "==> Writing /etc/exports (restricted to ${NFS_CLIENT_IP})..."
pct exec "$VMID" -- bash -c "echo '/data ${NFS_CLIENT_IP}(rw,sync,no_subtree_check,no_root_squash)' > /etc/exports"
pct exec "$VMID" -- bash -c "exportfs -ra && systemctl restart nfs-kernel-server && systemctl enable nfs-kernel-server"

echo
echo "==> CT provisioned. Next steps (manual):"
echo "  1. Add DNS record: dns-add ${DNS_HOSTNAME} ${CT_IPADDR} ${DNS_ZONE}"
echo "  2. On the mounting host (${NFS_CLIENT_IP}), mount with hard,intr:"
echo "       mount -t nfs -o hard,intr ${DNS_HOSTNAME}.${DNS_ZONE}:/data /mnt/pbs-offsite"
echo "     then add to /etc/fstab or an automount unit."
echo "  3. In PBS: add /mnt/pbs-offsite as a new datastore."
echo "  4. In PBS: create a sync job from the primary datastore to this one."
echo "  5. Wire up thin-pool free-space alerting for pve-data-tpool on this host,"
echo "     since this CT's growth shares capacity with everything else here."
echo "  6. Schedule/confirm a PBS verify job runs against this datastore"
echo "     (no ZFS scrub underneath - verify jobs are the integrity check here)."