#!/usr/bin/env bash
#
# pbs-offsite-provision.sh
#
# Provisions a VM (Debian cloud image + cloud-init) on the local-lvm thin
# pool to serve an NFS export used as a PBS offsite-DR datastore target.
#
# Why a VM and not an LXC CT: nfsd is a kernel-side service, and
# unprivileged LXC containers cannot mount the /proc/fs/nfsd pseudo-fs
# they share the host kernel and are deliberately blocked from it. A
# privileged CT + custom AppArmor profile can work around this but is
# fragile and gives up most of the isolation the CT existed for. A VM
# has its own kernel, so nfsd just works, no workarounds needed.
#
# Why not run nfsd directly on the Proxmox host: keeps the host's own
# package/service footprint untouched - this is meant to be a drop-in,
# disposable box, not something that entangles with the hypervisor OS.
#
# Storage: still comes from the existing local-lvm thin pool (same as
# the CT approach) via a VM virtual disk - no spare/dedicated disk or
# HBA passthrough required, unlike TrueNAS-as-VM.
#
# No ZFS underneath -> relying on PBS verify jobs for integrity
# checking, not local scrub.
#
# Cloud-init gotchas this script works around (learned the hard way):
#   - `qm set --cicustom user=...` REPLACES Proxmox's auto-generated user
#     config entirely - it does not merge with --ciuser/--cipassword. Our
#     custom config goes in as `vendor=...` instead, which merges alongside
#     the auto-generated user data rather than overriding it.
#   - qemu-guest-agent is NOT preinstalled in Debian's cloud images (generic
#     or genericcloud) - `--agent enabled=1` only opens the QEMU-side
#     channel. The agent package has to be installed via cloud-init and
#     explicitly enabled, or `qm agent ping` will just time out forever.
#
# Requirements on the Proxmox host:
#   - Internet access to cloud.debian.org (to fetch the cloud image)
#   - 'local' storage must have the 'snippets' content type enabled
#     (script checks and enables it if missing)
#
# Usage: edit the static config block below if needed, then run as root
# on the target Proxmox host (e.g. b2-pve02). VMID, volume size, and
# network settings are prompted for interactively at runtime.

set -euo pipefail

### --- Static config: edit if it differs per box ------------------------
VMID=                        # leave blank to auto-assign the next available VMID
VM_NAME="pbs-nfs"             # VM name / guest hostname
VM_MEMORY_MB=1024
VM_CORES=1
DISK_STORAGE="local-lvm"
SNIPPET_STORAGE="local"       # must support the 'snippets' content type

DEBIAN_CLOUD_IMG_URL="https://cloud.debian.org/images/cloud/trixie/latest/debian-13-generic-amd64.qcow2"
IMG_CACHE_DIR="/var/lib/vz/template/iso"

DNS_ZONE="talva.is"
DNS_HOSTNAME="pbs-nfs"         # -> pbs-nfs.talva.is, add via dns-add once IP is known

# Restrict the NFS export to the specific offsite Proxmox host that will
# mount it - never export to a whole subnet for a DR datastore.
NFS_CLIENT_IP=                 # e.g. 10.100.53.10 or the Tailscale IP of the mounting host
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
echo "==> Available bridges on this host:"
mapfile -t AVAILABLE_BRIDGES < <(ip -o link show type bridge | awk -F': ' '{print $2}' | sort)
if [ "${#AVAILABLE_BRIDGES[@]}" -eq 0 ]; then
  echo "ERROR: no bridges found via 'ip -o link show type bridge'." >&2
  exit 1
fi
for i in "${!AVAILABLE_BRIDGES[@]}"; do
  printf "  %d) %s\n" "$((i+1))" "${AVAILABLE_BRIDGES[$i]}"
done
BRIDGE_DEFAULT_IDX=0
for i in "${!AVAILABLE_BRIDGES[@]}"; do
  [ "${AVAILABLE_BRIDGES[$i]}" = "vmbr0" ] && BRIDGE_DEFAULT_IDX=$((i+1))
done
read -rp "  Select bridge [${BRIDGE_DEFAULT_IDX:-1}]: " bridge_choice
bridge_choice="${bridge_choice:-$BRIDGE_DEFAULT_IDX}"
if ! [[ "$bridge_choice" =~ ^[0-9]+$ ]] || [ "$bridge_choice" -lt 1 ] || [ "$bridge_choice" -gt "${#AVAILABLE_BRIDGES[@]}" ]; then
  echo "ERROR: invalid bridge selection." >&2
  exit 1
fi
BRIDGE="${AVAILABLE_BRIDGES[$((bridge_choice-1))]}"
echo "    Using bridge: $BRIDGE"

echo
echo "==> Network and volume settings for this VM:"
read -rp "  Disk size in GB: " CT_SIZE_GB
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

echo "==> Setting root password (for console/SSH access)..."
while true; do
  read -rsp "  Root password for this VM: " vm_root_pw
  echo
  read -rsp "  Confirm password: " vm_root_pw_confirm
  echo
  if [ -z "$vm_root_pw" ]; then
    echo "  Password cannot be empty."
    continue
  fi
  if [ "$vm_root_pw" != "$vm_root_pw_confirm" ]; then
    echo "  Passwords did not match, try again."
    continue
  fi
  break
done

echo
echo "==> Summary:"
echo "    VMID:          $VMID"
echo "    Name:          $VM_NAME"
echo "    Bridge:        $BRIDGE"
echo "    Disk size:     ${CT_SIZE_GB}G"
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
AVAIL_KIB="$(pvesm status | awk -v s="$DISK_STORAGE" '$1==s {print $5}')"
if [ -n "$AVAIL_KIB" ]; then
  AVAIL_GIB=$((AVAIL_KIB / 1024 / 1024))
  if [ "$CT_SIZE_GB" -gt "$AVAIL_GIB" ]; then
    echo "WARNING: requested ${CT_SIZE_GB}G exceeds the ~${AVAIL_GIB}G currently available on ${DISK_STORAGE}." >&2
    echo "  Thin provisioning allows this, but the pool will report itself oversubscribed" >&2
    echo "  and you risk running it out of real space if usage grows into the overcommitted amount." >&2
  fi
fi
read -rp "Confirm there is enough free space in ${DISK_STORAGE} for ${CT_SIZE_GB}G. Continue? [y/N] " ok
[ "$ok" = "y" ] || { echo "Aborted."; exit 1; }

echo "==> Ensuring 'snippets' content type is enabled on ${SNIPPET_STORAGE}..."
CURRENT_CONTENT="$(pvesh get /storage/${SNIPPET_STORAGE} --output-format json 2>/dev/null | grep -o '"content":"[^"]*"' | cut -d'"' -f4 || true)"
if [ -n "$CURRENT_CONTENT" ] && ! echo "$CURRENT_CONTENT" | grep -q snippets; then
  pvesm set "$SNIPPET_STORAGE" --content "${CURRENT_CONTENT},snippets"
  echo "    Enabled snippets on ${SNIPPET_STORAGE}."
elif [ -z "$CURRENT_CONTENT" ]; then
  echo "WARNING: could not verify content types on ${SNIPPET_STORAGE} - if VM creation fails on --cicustom, enable 'snippets' manually via Datacenter -> Storage -> ${SNIPPET_STORAGE} -> Edit." >&2
fi

echo "==> Fetching Debian cloud image (if not already cached)..."
mkdir -p "$IMG_CACHE_DIR"
IMG_FILE="${IMG_CACHE_DIR}/debian-13-generic-amd64.qcow2"
if [ ! -f "$IMG_FILE" ]; then
  wget -O "$IMG_FILE" "$DEBIAN_CLOUD_IMG_URL"
else
  echo "    Using cached image: $IMG_FILE"
fi

echo "==> Writing cloud-init vendor-data snippet (packages + NFS export config)..."
SNIPPET_DIR="/var/lib/vz/snippets"
mkdir -p "$SNIPPET_DIR"
SNIPPET_FILE="${SNIPPET_DIR}/pbs-nfs-${VMID}.yaml"
cat > "$SNIPPET_FILE" << CIEOF
#cloud-config
package_update: true
packages:
  - nfs-kernel-server
  - qemu-guest-agent
ssh_pwauth: true
write_files:
  - path: /etc/exports
    owner: root:root
    permissions: '0644'
    content: |
      /data ${NFS_CLIENT_IP}(rw,sync,no_subtree_check,no_root_squash)
runcmd:
  - mkdir -p /data
  - chown nobody:nogroup /data
  - exportfs -ra
  - systemctl enable --now nfs-kernel-server
  - systemctl enable --now qemu-guest-agent
CIEOF

echo "==> Creating VM $VMID ($VM_NAME)..."
qm create "$VMID" \
  --name "$VM_NAME" \
  --memory "$VM_MEMORY_MB" \
  --cores "$VM_CORES" \
  --cpu host \
  --ostype l26 \
  --net0 "virtio,bridge=${BRIDGE}" \
  --scsihw virtio-scsi-pci \
  --agent enabled=1

qm importdisk "$VMID" "$IMG_FILE" "$DISK_STORAGE"
qm set "$VMID" --scsi0 "${DISK_STORAGE}:vm-${VMID}-disk-0"
qm set "$VMID" --ide2 "${DISK_STORAGE}:cloudinit"
qm set "$VMID" --boot order=scsi0
qm set "$VMID" --serial0 socket --vga serial0
qm resize "$VMID" scsi0 "${CT_SIZE_GB}G"

qm set "$VMID" --ipconfig0 "ip=${CT_IP},gw=${CT_GW}"
qm set "$VMID" --nameserver "$CT_NS"
qm set "$VMID" --searchdomain "$CT_SEARCHDOMAIN"
qm set "$VMID" --ciuser root
qm set "$VMID" --cipassword "$vm_root_pw"
qm set "$VMID" --cicustom "vendor=${SNIPPET_STORAGE}:snippets/pbs-nfs-${VMID}.yaml"
unset vm_root_pw vm_root_pw_confirm

echo "==> Starting VM..."
qm start "$VMID"

echo "==> Waiting for QEMU guest agent to respond (up to 6 min - it has to be installed by cloud-init first, it's not preinstalled in the base image)..."
AGENT_READY=0
for i in $(seq 1 72); do
  if qm agent "$VMID" ping >/dev/null 2>&1; then
    AGENT_READY=1
    break
  fi
  sleep 5
done

if [ "$AGENT_READY" -ne 1 ]; then
  echo "ERROR: guest agent did not respond within 6 minutes." >&2
  echo "  Check console output for cloud-init/network errors:" >&2
  echo "    qm terminal $VMID" >&2
  echo "  Login is root / the password you set. If login fails there too," >&2
  echo "  cloud-init itself likely failed before it got to setting the" >&2
  echo "  password - check the boot log on the console for errors." >&2
  exit 1
fi
echo "    Guest agent responding."

echo "==> Waiting for cloud-init to finish (package install + NFS export config)..."
qm guest exec "$VMID" -- cloud-init status --wait >/dev/null 2>&1 || true

echo "==> Verifying nfs-kernel-server is active..."
NFS_ACTIVE="$(qm guest exec "$VMID" -- systemctl is-active nfs-kernel-server 2>/dev/null | grep -o 'active' || true)"
if [ "$NFS_ACTIVE" != "active" ]; then
  echo "WARNING: nfs-kernel-server does not report active yet. Check manually:" >&2
  echo "    qm guest exec $VMID -- systemctl status nfs-kernel-server" >&2
  echo "    qm guest exec $VMID -- journalctl -xe" >&2
else
  echo "    nfs-kernel-server is active."
fi

echo
echo "==> VM provisioned. Next steps (manual):"
echo "  1. Add DNS record: dns-add ${DNS_HOSTNAME} ${CT_IPADDR} ${DNS_ZONE}"
echo "  2. On the mounting host (${NFS_CLIENT_IP}), mount with hard,intr:"
echo "       mount -t nfs -o hard,intr ${DNS_HOSTNAME}.${DNS_ZONE}:/data /mnt/pbs-offsite"
echo "     then add to /etc/fstab or an automount unit."
echo "  3. In PBS: add /mnt/pbs-offsite as a new datastore."
echo "  4. In PBS: create a sync job from the primary datastore to this one."
echo "  5. Wire up thin-pool free-space alerting for ${DISK_STORAGE} on this host,"
echo "     since this VM's disk shares capacity with everything else here."
echo "  6. Schedule/confirm a PBS verify job runs against this datastore"
echo "     (no ZFS scrub underneath - verify jobs are the integrity check here)."