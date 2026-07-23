#!/usr/bin/env bash
# Project Halcyon — full deploy: randomize secrets/paths, boot all VMs
# (Vagrant/VMware Workstation), wait for them to come up, then provision
# with Ansible, then snapshot every VM as the "clean, freshly-armed" state
# that scripts/reset.sh reverts to.
#
# On a Windows host: run this script from a WSL2 (Ubuntu) terminal, not
# PowerShell/cmd. `vagrant` here resolves to the Windows-native vagrant.exe
# via WSL interop (it drives VMware Workstation on the Windows side, which
# is where it must run); `ansible-playbook` resolves to the ansible-core
# install inside WSL2 (Ansible has no supported Windows control node, which
# is also why the Vagrantfile has no built-in ansible provisioner - see its
# header comment). The only requirement linking the two: WSL2 must be able to
# reach all three lab host-only subnets - LAN 10.20.10.0/24, DMZ 172.20.1.0/24,
# WAN 203.0.113.0/24 - over the network, since Ansible manages every guest
# directly on its own segment (not through the firewall). This normally works
# automatically since WSL2 NATs outbound traffic through the Windows host,
# which already has a route to each subnet via its VMware host-only adapter
# (.1 on each). Verify with `ping 10.20.10.10` / `ping 172.20.1.40` /
# `ping 203.0.113.66` after `vagrant up` if the Ansible step can't connect.
set -euo pipefail
cd "$(dirname "$0")/.."

SEED="${HALCYON_SEED:-}"

# Required for the Vagrantfile's `communicator = "none"` (these boxes have
# no VMware Tools, so Vagrant never actually talks to the guest - see
# Vagrantfile header comment).
export VAGRANT_EXPERIMENTAL="${VAGRANT_EXPERIMENTAL:-none_communicator}"

# Prepare the three segmented vmnets (LAN/DMZ/WAN), disable VMware's own DHCP
# so pfSense can own it, and recreate the nat.conf placeholders + firewalld
# trusted-zone entries. Idempotent; safe to run every deploy. Needs sudo
# (it re-execs itself under sudo).
echo "[deploy] preparing host networks (vmnet20/21/22) for the pfSense edge..."
scripts/setup-networks.sh

echo "[deploy] generating per-deploy secrets and live vulnerability paths..."
if [ -n "$SEED" ]; then
  python3 ansible/roles/randomize/files/gen_seed.py --seed "$SEED"
else
  python3 ansible/roles/randomize/files/gen_seed.py
fi

echo "[deploy] booting all VMs (VMware Workstation, via vagrant)..."
# --no-parallel: bringing up all VMs (cloning multi-GB boxes, powering on)
# at once overloads the Vagrant VMware Utility's request handling - it starts
# timing out (Net::ReadTimeout) partway through. Sequential is slower but
# reliable. fw01 (pfSense) is first in the Vagrantfile, so it boots first and
# is up to serve DHCP/gateway before the other guests request leases.
vagrant up --no-parallel

# Guests get their IP + gateway from pfSense's DHCP, so wait for fw01 to
# actually be answering on the LAN before provisioning. IPs are deterministic
# (pfSense static-MAC mappings, already in ansible/inventory.yml) - no lease
# scraping needed anymore.
echo "[deploy] waiting for pfSense (fw01) gateway 10.20.10.254 to come up..."
for i in $(seq 1 60); do
  if ping -c1 -W2 10.20.10.254 >/dev/null 2>&1; then
    echo "[deploy] fw01 is up."
    break
  fi
  [ "$i" -eq 60 ] && echo "[deploy] WARNING: fw01 gateway not reachable after 2min; continuing anyway."
  sleep 2
done
# Give the just-booted guests a moment to DHCP their leases from fw01.
sleep 20

echo "[deploy] provisioning with Ansible (this can take 30-90 minutes)..."
ansible-playbook -i ansible/inventory.yml ansible/site.yml

echo "[deploy] snapshotting all VMs as clean-armed baseline..."
for vm in fw01 dc01 srv01 ws01 ws02 web01 attack; do
  vagrant snapshot save "$vm" clean-armed || \
    echo "[deploy] WARNING: could not snapshot $vm automatically - snapshot it manually (vagrant snapshot save $vm clean-armed)"
done

echo "[deploy] done. Answer key: docs/answer-key.md (do not distribute to students)."
echo "[deploy] student brief: docs/student-brief.md"
