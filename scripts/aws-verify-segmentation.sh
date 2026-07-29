#!/usr/bin/env bash
# Project Halcyon — AWS analog of scripts/verify-segmentation.sh.
#
# RUN THIS FROM THE ATTACK INSTANCE, not from the operator's own machine -
# the operator's machine reaches everything over SSM tunnels (out-of-band,
# same as the KVM host's .1 management adapters) and so CANNOT tell you
# whether the Security Group boundary is actually enforcing anything. Only a
# host that sits in subnet_wan without SG exceptions into subnet_lan - i.e.
# attack - exercises the real policy.
#
# From the operator's machine:
#   TF_JSON="$(terraform -chdir=terraform output -json)"
#   ATTACK_IP="$(aws ec2 describe-instances --instance-ids \
#     $(echo "$TF_JSON" | python3 -c 'import json,sys;print(json.load(sys.stdin)["hosts"]["value"]["attack"]["instance_id"])') \
#     --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)"
#   scp scripts/aws-verify-segmentation.sh kali@$ATTACK_IP:/tmp/
#   ssh kali@$ATTACK_IP 'DC_LAN=<dc01-private-ip> SRV_LAN=<srv01-private-ip> WEB_PUBLIC=<web01-public-ip> bash /tmp/aws-verify-segmentation.sh'
#
# (Private IPs come from `terraform output hosts`; the web01 public IP from
# `terraform output` / EC2 console. This script deliberately takes them as
# env vars rather than hardcoding, since they're only known post-apply.)
#
# Expected result on a correctly-segmented lab: all checks PASS. A "blocked"
# check PASSES when the connection is refused/times out (that's the point).
set -uo pipefail

WEB_PUBLIC="${WEB_PUBLIC:?set WEB_PUBLIC to web01 public IP (terraform output)}"
DC_LAN="${DC_LAN:?set DC_LAN to dc01 private IP (terraform output hosts.dc01.private_ip)}"
SRV_LAN="${SRV_LAN:?set SRV_LAN to srv01 private IP (terraform output hosts.srv01.private_ip)}"

PASS=0; FAIL=0
CONNECT_TIMEOUT=4

tcp_open() {
  timeout "$CONNECT_TIMEOUT" bash -c "exec 3<>/dev/tcp/$1/$2" 2>/dev/null
}

expect_open() {  # desc host port
  local desc="$1" host="$2" port="$3"
  if tcp_open "$host" "$port"; then
    echo "  PASS  $desc  ($host:$port reachable)"; PASS=$((PASS+1))
  else
    echo "  FAIL  $desc  ($host:$port should be reachable but was NOT)"; FAIL=$((FAIL+1))
  fi
}

expect_blocked() {  # desc host port
  local desc="$1" host="$2" port="$3"
  if tcp_open "$host" "$port"; then
    echo "  FAIL  $desc  ($host:$port is reachable but should be BLOCKED)"; FAIL=$((FAIL+1))
  else
    echo "  PASS  $desc  ($host:$port blocked, as intended)"; PASS=$((PASS+1))
  fi
}

echo "== The one way in: WAN -> web01 =="
expect_open "web01 HTTP"  "$WEB_PUBLIC" 80
expect_open "web01 HTTPS" "$WEB_PUBLIC" 443
if command -v curl >/dev/null 2>&1; then
  if curl -sf -m "$CONNECT_TIMEOUT" "http://$WEB_PUBLIC/healthz" >/dev/null 2>&1; then
    echo "  PASS  web app answers"; PASS=$((PASS+1))
  else
    echo "  FAIL  web app did NOT answer"; FAIL=$((FAIL+1))
  fi
fi

echo "== The load-bearing control: attack (WAN) cannot touch the internal LAN =="
expect_blocked "dc01 LDAP (389)"    "$DC_LAN"  389
expect_blocked "dc01 SMB (445)"     "$DC_LAN"  445
expect_blocked "dc01 Kerberos (88)" "$DC_LAN"  88
expect_blocked "srv01 MSSQL (1433)" "$SRV_LAN" 1433

echo
echo "== Result: $PASS passed, $FAIL failed =="
if [ "$FAIL" -eq 0 ]; then
  echo "Segmentation is enforced: web01 is the only front door, LAN is sealed off from attack."
else
  echo "Segmentation NOT fully enforced - review terraform/security_groups.tf (sg-lan-internal should only allow self + sg-wan-web01)."
fi
[ "$FAIL" -eq 0 ]
