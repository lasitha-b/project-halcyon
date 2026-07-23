#!/usr/bin/env bash
# Project Halcyon — prepare the three segmented host-only vmnets for the pfSense
# edge firewall. Run once (and again after any `vmware-networks` reset, which
# tends to wipe custom vmnet config - same reason deploy.sh recreates nat.conf).
#
#   vmnet20  LAN  10.20.10.0/24    (already exists in most setups)
#   vmnet21  DMZ  172.20.1.0/24    (created here)
#   vmnet22  WAN  203.0.113.0/24   (created here)
#
# On all three we DISABLE VMware's own dhcpd: pfSense (fw01) owns DHCP for the
# lab so it can hand out itself as the default gateway plus deterministic
# static-MAC IP mappings. The host keeps its .1 virtual adapter on each vmnet
# (VIRTUAL_ADAPTER yes) for out-of-band Ansible management, independent of the
# firewall.
#
# Must run with sudo (edits /etc/vmware and restarts vmware-networks).
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "[setup-networks] re-exec under sudo..." >&2
  exec sudo -E bash "$0" "$@"
fi

NETWORKING="/etc/vmware/networking"

# vnet number -> "SUBNET" mapping for the segments we manage. All host-only
# (NAT no), all with VMware DHCP off (DHCP no), all with a host virtual adapter.
declare -A SUBNET=(
  [20]="10.20.10.0"
  [21]="172.20.1.0"
  [22]="203.0.113.0"
)

echo "[setup-networks] rewriting $NETWORKING entries for vmnet20/21/22..."
if [ ! -f "$NETWORKING" ]; then
  printf 'VERSION=1,0\n' > "$NETWORKING"
fi

# Strip any existing answers for the vnets we own, then re-append canonical
# ones. Leaves VNET_1 / VNET_8 (and anything else) untouched.
tmp="$(mktemp)"
grep -vE '^answer VNET_(20|21|22)_' "$NETWORKING" > "$tmp" || true
for n in 20 21 22; do
  {
    echo "answer VNET_${n}_DHCP no"
    echo "answer VNET_${n}_HOSTONLY_NETMASK 255.255.255.0"
    echo "answer VNET_${n}_HOSTONLY_SUBNET ${SUBNET[$n]}"
    echo "answer VNET_${n}_NAT no"
    echo "answer VNET_${n}_VIRTUAL_ADAPTER yes"
  } >> "$tmp"
done
cat "$tmp" > "$NETWORKING"
rm -f "$tmp"

echo "[setup-networks] restarting vmware-networks (applies vmnet changes)..."
vmware-networks --stop  >/dev/null 2>&1 || true
vmware-networks --start >/dev/null 2>&1

# vagrant-vmware-desktop expects a nat.conf for every vmnet it uses as a
# nat_device, even though these nets deliberately have no NAT service. Without
# it, `vagrant up`/`destroy` errors while pruning port forwards. Harmless
# placeholder - NAT stays off. (Host adapter takes .1 on each segment.)
for n in 20 21 22; do
  host_ip="${SUBNET[$n]%.0}.1"
  conf="/etc/vmware/vmnet${n}/nat/nat.conf"
  if [ ! -f "$conf" ]; then
    echo "[setup-networks] recreating $conf (placeholder, NAT stays off)..."
    mkdir -p "$(dirname "$conf")"
    cat > "$conf" <<EOF
[host]
device = /dev/vmnet${n}
hostIp = ${host_ip}

[incomingtcp]

[incomingudp]
EOF
  fi
done

# firewalld blocks the host's own vmnet adapters by default, which breaks
# host<->guest management traffic (and Packer's build-time HTTP server on
# vmnet8). Put every lab vmnet in the trusted zone. No-op if firewalld isn't
# running.
if command -v firewall-cmd >/dev/null 2>&1 && firewall-cmd --state >/dev/null 2>&1; then
  for iface in vmnet20 vmnet21 vmnet22; do
    firewall-cmd --permanent --zone=trusted --change-interface="$iface" >/dev/null 2>&1 || \
      firewall-cmd --permanent --zone=trusted --add-interface="$iface" >/dev/null 2>&1 || true
  done
  firewall-cmd --reload >/dev/null 2>&1 || true
  echo "[setup-networks] vmnet20/21/22 added to firewalld trusted zone."
fi

echo "[setup-networks] done. Host adapters: 10.20.10.1 (LAN), 172.20.1.1 (DMZ), 203.0.113.1 (WAN)."
echo "[setup-networks] pfSense (fw01) will own .254 + DHCP on each once booted."
