#!/usr/bin/env bash
# Project Halcyon — AWS analog of scripts/health.sh.
#
# Sanity-checks EC2 instance status plus web01's public-facing service
# (reachable directly, since it sits in the public subnet). Internal
# service checks (DC01 LDAP/Kerberos, SRV01 MSSQL) run via SSM Run Command
# ON the host itself (localhost), since the operator's machine has no direct
# network path into subnet_lan by design (see docs/architecture-aws.md) -
# this proves the SERVICE is up, not that segmentation holds. For the
# segmentation-aware view (does WAN reach LAN?), use
# scripts/aws-verify-segmentation.sh from the attack instance instead.
set -uo pipefail
cd "$(dirname "$0")/.."

PASS=0
FAIL=0

check() {
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then
    echo "  OK    $desc"
    PASS=$((PASS+1))
  else
    echo "  FAIL  $desc"
    FAIL=$((FAIL+1))
  fi
}

TF_JSON="$(terraform -chdir=terraform output -json)"
HOSTS_TSV="$(echo "$TF_JSON" | python3 -c '
import json, sys
d = json.load(sys.stdin)["hosts"]["value"]
for name, h in d.items():
    print(f"{name}\t{h[\"instance_id\"]}\t{h[\"private_ip\"]}")
')"
DC01_ID="$(echo "$HOSTS_TSV" | awk -F'\t' '$1=="dc01"{print $2}')"
SRV01_ID="$(echo "$HOSTS_TSV" | awk -F'\t' '$1=="srv01"{print $2}')"
WEB01_PUBLIC_IP="$(aws ec2 describe-instances --instance-ids "$(echo "$HOSTS_TSV" | awk -F'\t' '$1=="web01"{print $2}')" --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)"

echo "== EC2 instance status =="
while IFS=$'\t' read -r NAME IID _; do
  check "$NAME ($IID) status ok" bash -c "aws ec2 describe-instance-status --instance-ids '$IID' --query 'InstanceStatuses[0].InstanceStatus.Status' --output text | grep -q ok"
done <<< "$HOSTS_TSV"

echo "== web01 public service =="
check "web01 app /healthz (public: $WEB01_PUBLIC_IP)" curl -sf "http://$WEB01_PUBLIC_IP/healthz"

echo "== Internal services (checked in-host via SSM Run Command) =="
check "dc01 LDAP (389) listening" bash -c "
  aws ssm send-command --instance-ids '$DC01_ID' --document-name 'AWS-RunPowerShellScript' \
    --parameters 'commands=[\"Test-NetConnection -ComputerName localhost -Port 389 | Select -ExpandProperty TcpTestSucceeded\"]' \
    --query 'Command.CommandId' --output text | xargs -I{} sh -c 'sleep 5; aws ssm get-command-invocation --command-id {} --instance-id $DC01_ID --query StandardOutputContent --output text' | grep -qi True
"
check "srv01 MSSQL (1433) listening" bash -c "
  aws ssm send-command --instance-ids '$SRV01_ID' --document-name 'AWS-RunPowerShellScript' \
    --parameters 'commands=[\"Test-NetConnection -ComputerName localhost -Port 1433 | Select -ExpandProperty TcpTestSucceeded\"]' \
    --query 'Command.CommandId' --output text | xargs -I{} sh -c 'sleep 5; aws ssm get-command-invocation --command-id {} --instance-id $SRV01_ID --query StandardOutputContent --output text' | grep -qi True
"

echo
echo "== Result: $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
