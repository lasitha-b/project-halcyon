#!/usr/bin/env bash
# Project Halcyon — KVM/libvirt host network + storage prep.
#
# Creates the three isolated libvirt networks the lab segments run on (no
# forward/NAT to the real network - pfSense (fw01) is the only router between
# them), plus the storage pool on the supersonic SSD that all VM disks live
# on. Idempotent; safe to re-run.
#
#   lab-wan  192.168.50.0/24  - attacker (Kali) vantage point
#   lab-dmz  172.20.1.0/24    - WEB01 only
#   lab-lan  10.20.10.0/24    - internal AD network (DC01/SRV01/WS01/WS02)
#
# The host holds .1 on each network (management adapter for direct Ansible
# reachability, independent of firewall policy); pfSense owns DHCP on every
# segment via static-MAC mappings in packer/pfsense/config.xml, so none of
# these networks defines a <dhcp> block of its own.
set -euo pipefail

POOL_DIR="/mnt/halcyon-lab/kvm/disks"
POOL_NAME="halcyon-lab"

if [ "$(id -u)" -ne 0 ]; then
  exec sudo "$0" "$@"
fi

define_net() {
  local name="$1" bridge="$2" ip="$3"
  if virsh net-info "$name" >/dev/null 2>&1; then
    echo "[setup-networks] $name already defined"
  else
    tmp="$(mktemp)"
    cat > "$tmp" <<EOF
<network>
  <name>${name}</name>
  <bridge name="${bridge}" stp="on" delay="0"/>
  <ip address="${ip}" netmask="255.255.255.0"></ip>
</network>
EOF
    virsh net-define "$tmp"
    rm -f "$tmp"
  fi
  virsh net-autostart "$name" >/dev/null
  virsh net-info "$name" | grep -q "Active:.*yes" || virsh net-start "$name"
  echo "[setup-networks] $name up (bridge ${bridge}, host ${ip})"
}

echo "[setup-networks] defining isolated lab networks..."
define_net lab-wan virbr-wan 192.168.50.1
define_net lab-dmz virbr-dmz 172.20.1.1
define_net lab-lan virbr-lan 10.20.10.1

echo "[setup-networks] preparing VM disk storage pool on the supersonic SSD..."
mkdir -p "$POOL_DIR"
if virsh pool-info "$POOL_NAME" >/dev/null 2>&1; then
  echo "[setup-networks] pool $POOL_NAME already defined"
else
  virsh pool-define-as "$POOL_NAME" dir --target "$POOL_DIR"
fi
virsh pool-autostart "$POOL_NAME" >/dev/null
virsh pool-info "$POOL_NAME" | grep -q "State:.*running" || virsh pool-start "$POOL_NAME"

echo "[setup-networks] done."
virsh net-list --all
virsh pool-list --all
