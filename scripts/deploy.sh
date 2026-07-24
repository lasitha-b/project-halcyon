#!/usr/bin/env bash
# Project Halcyon — KVM/libvirt deploy: randomize secrets/paths, then
# provision the already-built VMs with Ansible.
#
# This is a one-time deployment, not a repeatable pipeline: the seven VMs
# (fw01, dc01, srv01, ws01, ws02, web01, attack) are built once via
# virt-install (see docs/architecture.md and packer/pfsense/README.md for
# fw01's manual install+restore steps) and left running under libvirt -
# there is no `vagrant up`/box-clone step and no snapshot/reset flow.
#
# Run this after scripts/setup-networks.sh and after all seven VMs are up
# and answering WinRM/SSH (fw01's DHCP hands out the deterministic IPs in
# ansible/inventory.yml by fixed MAC - see packer/pfsense/config.xml).
set -euo pipefail
cd "$(dirname "$0")/.."

SEED="${HALCYON_SEED:-}"

echo "[deploy] preparing host networks + storage pool (idempotent)..."
scripts/setup-networks.sh

echo "[deploy] generating per-deploy secrets and live vulnerability paths..."
if [ -n "$SEED" ]; then
  python3 ansible/roles/randomize/files/gen_seed.py --seed "$SEED"
else
  python3 ansible/roles/randomize/files/gen_seed.py
fi

echo "[deploy] waiting for pfSense (fw01) LAN gateway 10.20.10.254..."
for i in $(seq 1 60); do
  if ping -c1 -W2 10.20.10.254 >/dev/null 2>&1; then
    echo "[deploy] fw01 is up."
    break
  fi
  [ "$i" -eq 60 ] && echo "[deploy] WARNING: fw01 gateway not reachable after 2min; continuing anyway."
  sleep 2
done

echo "[deploy] provisioning with Ansible (this can take 30-90 minutes)..."
ansible-playbook -i ansible/inventory.yml ansible/site.yml

echo "[deploy] done. Answer key: docs/answer-key.md (do not distribute to students)."
echo "[deploy] student brief: docs/student-brief.md"
