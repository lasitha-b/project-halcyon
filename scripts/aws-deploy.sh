#!/usr/bin/env bash
# Project Halcyon — AWS deploy: terraform apply, then open SSM tunnels and
# provision with the SAME Ansible codebase the KVM path uses.
#
# This is the AWS analog of scripts/deploy.sh — same structure/spirit, but:
#   - infra is created by Terraform instead of virt-install
#   - control-node reachability into the VPC goes over SSM Session Manager
#     port-forwarding tunnels (no bastion instance, no inbound network path
#     needed into the VPC at all) instead of a libvirt host-management NIC
#   - ansible/site.yml and gen_seed.py run completely unmodified
#
# Requires: terraform, aws CLI (configured/authenticated), the
# session-manager-plugin for `aws ssm start-session`, ansible.
#
# Costs real money while the instances are up — scripts/aws-destroy.sh when
# you're done. See terraform/budget.tf for the backstop alarm.
set -euo pipefail
cd "$(dirname "$0")/.."

TF_DIR="terraform"
GEN_DIR="ansible/generated"
PORTS_FILE="$GEN_DIR/tunnel_ports.json"
TUNNEL_PIDS=()

cleanup() {
  if [ "${#TUNNEL_PIDS[@]}" -gt 0 ]; then
    echo "[aws-deploy] closing SSM tunnels..."
    kill "${TUNNEL_PIDS[@]}" 2>/dev/null || true
  fi
}
trap cleanup EXIT

echo "[aws-deploy] terraform init..."
terraform -chdir="$TF_DIR" init -input=false

echo "[aws-deploy] terraform apply (review the plan before confirming - this costs money)..."
terraform -chdir="$TF_DIR" apply

mkdir -p "$GEN_DIR"

echo "[aws-deploy] reading terraform outputs..."
TF_JSON="$(terraform -chdir="$TF_DIR" output -json)"

echo "[aws-deploy] waiting for EC2 status checks (2/2) on all instances..."
INSTANCE_IDS="$(echo "$TF_JSON" | python3 -c 'import json,sys; d=json.load(sys.stdin)["hosts"]["value"]; print(" ".join(h["instance_id"] for h in d.values()))')"
aws ec2 wait instance-status-ok --instance-ids $INSTANCE_IDS

echo "[aws-deploy] opening SSM port-forward tunnels..."
declare -A LOCAL_PORT
NEXT_PORT=15985
python3 <<'PYEOF' > /tmp/halcyon-aws-hosts.tsv
import json, subprocess
tf = json.loads(subprocess.check_output(["terraform", "-chdir=terraform", "output", "-json"]))
for name, h in tf["hosts"]["value"].items():
    remote_port = 5985 if h["os"] == "windows" else 22
    print(f'{name}\t{h["instance_id"]}\t{remote_port}\t{h["group"]}')
PYEOF

PORTS_JSON="{"
FIRST=1
while IFS=$'\t' read -r NAME IID REMOTE_PORT GROUP; do
  if [ "$GROUP" = "attacker" ]; then
    continue # attack is never an Ansible target - see ansible/site.yml
  fi
  LOCAL_PORT[$NAME]=$NEXT_PORT
  echo "[aws-deploy]   $NAME ($IID) -> 127.0.0.1:$NEXT_PORT (remote $REMOTE_PORT)"
  aws ssm start-session \
    --target "$IID" \
    --document-name AWS-StartPortForwardingSession \
    --parameters "{\"portNumber\":[\"$REMOTE_PORT\"],\"localPortNumber\":[\"$NEXT_PORT\"]}" \
    >/tmp/halcyon-ssm-"$NAME".log 2>&1 &
  TUNNEL_PIDS+=($!)
  if [ "$FIRST" -eq 1 ]; then FIRST=0; else PORTS_JSON="$PORTS_JSON,"; fi
  PORTS_JSON="$PORTS_JSON\"$NAME\":$NEXT_PORT"
  NEXT_PORT=$((NEXT_PORT + 1))
done < /tmp/halcyon-aws-hosts.tsv
PORTS_JSON="$PORTS_JSON}"
echo "$PORTS_JSON" > "$PORTS_FILE"
rm -f /tmp/halcyon-aws-hosts.tsv

echo "[aws-deploy] waiting for tunnels to establish..."
sleep 10

echo "[aws-deploy] generating per-deploy secrets and live vulnerability paths..."
python3 ansible/roles/randomize/files/gen_seed.py

echo "[aws-deploy] generating Ansible inventory from Terraform outputs..."
python3 scripts/aws-gen-inventory.py

echo "[aws-deploy] provisioning with Ansible (this can take 30-90 minutes)..."
echo "[aws-deploy] NOTE: SSM tunnels idle-timeout by default - if a long play"
echo "[aws-deploy]       (e.g. Install-ADDSForest + reboot) drops a tunnel,"
echo "[aws-deploy]       re-run this script; already-provisioned steps are idempotent."
ansible-playbook -i "$GEN_DIR/inventory_aws.yml" ansible/site.yml

echo "[aws-deploy] done. Answer key: docs/answer-key.md (do not distribute to students)."
echo "[aws-deploy] student brief: docs/student-brief.md"
echo "[aws-deploy] REMEMBER: this lab costs money while running - scripts/aws-destroy.sh when done."
