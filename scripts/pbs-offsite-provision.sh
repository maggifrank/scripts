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
echo "    Bridge:        $BRIDGE"
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

echo "==> Waiting for network to come up inside the CT..."
NET_READY=0
for i in $(seq 1 30); do
  if pct exec "$VMID" -- ping -c1 -W2 "$CT_GW" >/dev/null 2>&1; then
    NET_READY=1
    break
  fi
  sleep 2
done

if [ "$NET_READY" -ne 1 ]; then
  echo "ERROR: CT $VMID cannot reach its gateway ($CT_GW) after 60s." >&2
  echo "  This usually means the wrong bridge was selected, or the gateway/IP" >&2
  echo "  don't actually belong to that bridge's network. Check with:" >&2
  echo "    pct exec $VMID -- ip addr" >&2
  echo "    pct exec $VMID -- ip route" >&2
  echo "  Fix networking (pct set $VMID --net0 ...), then re-run this script's" >&2
  echo "  remaining steps manually against CT $VMID rather than re-running the" >&2
  echo "  whole script, which would create a second CT." >&2
  exit 1
fi
echo "    Gateway reachable."

if ! pct exec "$VMID" -- getent hosts deb.debian.org >/dev/null 2>&1; then
  echo "WARNING: gateway is reachable but DNS resolution is failing inside the CT." >&2
  echo "  Check: pct exec $VMID -- cat /etc/resolv.conf" >&2
  echo "  and confirm the nameservers (${CT_NS}) are reachable from this CT's subnet." >&2
  read -rp "Continue anyway and attempt apt install? [y/N] " dns_continue
  [ "$dns_continue" = "y" ] || { echo "Stopped. CT $VMID exists but is not yet configured - fix DNS and re-run remaining steps manually."; exit 1; }
fi

echo "==> Setting root password (needed for console access)..."
while true; do
  read -rsp "  Root password for this CT: " ct_root_pw
  echo
  read -rsp "  Confirm password: " ct_root_pw_confirm
  echo
  if [ -z "$ct_root_pw" ]; then
    echo "  Password cannot be empty."
    continue
  fi
  if [ "$ct_root_pw" != "$ct_root_pw_confirm" ]; then
    echo "  Passwords did not match, try again."
    continue
  fi
  break
done
pct exec "$VMID" -- bash -c "echo 'root:${ct_root_pw}' | chpasswd"
unset ct_root_pw ct_root_pw_confirm

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