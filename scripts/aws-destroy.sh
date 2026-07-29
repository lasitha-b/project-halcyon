#!/usr/bin/env bash
# Project Halcyon — AWS teardown.
#
# Deliberately does NOT pass -auto-approve: this is a manual, human-
# confirmed teardown. Cost-control automation shouldn't be so automatic
# that an accidental invocation destroys a lab someone's mid-session on -
# terraform will print the full resource list and ask for confirmation.
set -euo pipefail
cd "$(dirname "$0")/.."

echo "[aws-destroy] tearing down all AWS lab resources..."
terraform -chdir=terraform destroy

echo "[aws-destroy] cleaning up generated inventory/tunnel state..."
rm -f ansible/generated/inventory_aws.yml ansible/generated/tunnel_ports.json

echo "[aws-destroy] done. Double-check the AWS console / Cost Explorer for any"
echo "[aws-destroy] leftover Project=halcyon-lab-tagged resources (e.g. an EIP"
echo "[aws-destroy] or EBS volume orphaned by a failed terraform apply)."
