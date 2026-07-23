#!/usr/bin/env bash
# Revert all VMs to the clean-armed snapshot taken at the end of deploy.sh.
# Fast re-arm without a full re-provision. On Windows, run from WSL2 - see
# deploy.sh's header comment for why (`vagrant` resolves to vagrant.exe via
# WSL interop, no Ansible involved here).
set -euo pipefail
cd "$(dirname "$0")/.."

# fw01 first so the gateway/DHCP is back before the guests it serves.
for vm in fw01 dc01 srv01 ws01 ws02 web01 attack; do
  echo "[reset] reverting $vm to clean-armed..."
  vagrant snapshot restore "$vm" clean-armed
done

echo "[reset] done. Lab is back to its freshly-armed state (same seed/secrets as last deploy)."
