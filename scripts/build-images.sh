#!/usr/bin/env bash
# Build the three Packer base images and register them as Vagrant boxes.
# Run once (or whenever you want to refresh base images). Requires:
#   - Windows Server 2022 eval ISO + Windows 11 eval ISO downloaded locally
#   - HALCYON_WIN2022_ISO / HALCYON_WIN11_ISO env vars pointing at them
#   - Real iso_checksum values set in each packer/*/*.pkr.hcl (see packer/README.md)
#
# On Windows: run from WSL2 - `packer` and `vagrant` resolve to their
# Windows-native .exe via WSL interop (both must run on the same OS as
# VMware Workstation). No Ansible is involved in this script.
set -euo pipefail
cd "$(dirname "$0")/.."

: "${HALCYON_WIN2022_ISO:?set to the path of your Windows Server 2022 eval ISO}"
: "${HALCYON_WIN11_ISO:?set to the path of your Windows 11 eval ISO}"
# pfSense CE ISO is optional here: its automated build is best-effort (see
# packer/pfsense/README.md - the reliable path is a one-time manual install +
# config.xml restore). Set HALCYON_PFSENSE_ISO to attempt the automated build.
HALCYON_PFSENSE_ISO="${HALCYON_PFSENSE_ISO:-}"

packer init packer/win2022
packer init packer/win11
packer init packer/ubuntu2204

echo "[build-images] building win2022 (this takes ~45-90 min unattended)..."
packer build -var "iso_url=${HALCYON_WIN2022_ISO}" packer/win2022/win2022.pkr.hcl

echo "[build-images] building win11..."
packer build -var "iso_url=${HALCYON_WIN11_ISO}" packer/win11/win11.pkr.hcl

echo "[build-images] building ubuntu2204..."
packer build packer/ubuntu2204/ubuntu2204.pkr.hcl

if [ -n "$HALCYON_PFSENSE_ISO" ]; then
  echo "[build-images] building pfsense (best-effort automated install)..."
  packer init packer/pfsense
  packer build -var "iso_url=${HALCYON_PFSENSE_ISO}" packer/pfsense/pfsense.pkr.hcl
  vagrant box add halcyon/pfsense /mnt/halcyon-lab/packer-output/boxes/halcyon-pfsense.box --force
else
  echo "[build-images] SKIPPING pfsense build (HALCYON_PFSENSE_ISO not set)."
  echo "[build-images]   Build it via the reliable manual path in packer/pfsense/README.md,"
  echo "[build-images]   then: vagrant box add halcyon/pfsense <box> --force"
fi

echo "[build-images] registering Vagrant boxes..."
vagrant box add halcyon/win2022  /mnt/halcyon-lab/packer-output/boxes/halcyon-win2022.box       --force
vagrant box add halcyon/win11    /mnt/halcyon-lab/packer-output/boxes/halcyon-win11.box           --force
vagrant box add halcyon/ubuntu22 /mnt/halcyon-lab/packer-output/boxes/halcyon-ubuntu2204.box --force

echo "[build-images] done. 'vagrant box list' should now show halcyon/win2022,"
echo "halcyon/win11, halcyon/ubuntu22, halcyon/attack-kali, and (once built) halcyon/pfsense."
