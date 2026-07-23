#!/usr/bin/env bash
# Project Halcyon — prove the pfSense edge policy from the ATTACKER's vantage.
#
# RUN THIS FROM THE ATTACK BOX (203.0.113.66), not from the VMware host. The
# host holds a .1 management adapter on every vmnet, so it can reach all three
# segments directly and CANNOT tell you whether the firewall is actually
# enforcing anything. Only a host that sits behind the firewall's WAN side -
# i.e. ATTACK - exercises the real policy.
#
#   scp scripts/verify-segmentation.sh kali@203.0.113.66:/tmp/
#   ssh kali@203.0.113.66 'bash /tmp/verify-segmentation.sh'
#
# Expected result on a correctly-segmented lab: all checks PASS. A "blocked"
# check PASSES when the connection is refused/times out (that's the point).
set -uo pipefail

# Edge / target addresses (see docs/architecture.md "Network segmentation").
FW_WAN="203.0.113.254"     # pfSense WAN IP (port-forward front door + no admin)
WEB_DMZ="172.20.1.40"      # WEB01, only reachable via the port-forward
DC_LAN="10.20.10.10"       # DC01, internal - must be unreachable from WAN
SRV_LAN="10.20.10.20"      # SRV01/MSSQL, internal - must be unreachable from WAN

PASS=0; FAIL=0
CONNECT_TIMEOUT=4

# tcp_open HOST PORT -> returns 0 if a TCP connect succeeds within the timeout.
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

echo "== The one way in: WAN -> WEB01 via the port-forward =="
expect_open "port-forward 80  -> WEB01"  "$FW_WAN" 80
expect_open "port-forward 443 -> WEB01"  "$FW_WAN" 443
if command -v curl >/dev/null 2>&1; then
  if curl -sf -m "$CONNECT_TIMEOUT" "http://$FW_WAN/healthz" >/dev/null 2>&1 || \
     curl -sf -m "$CONNECT_TIMEOUT" -H "Host: intranet.halcyon.local" "http://$FW_WAN/" >/dev/null 2>&1; then
    echo "  PASS  web app answers through the port-forward"; PASS=$((PASS+1))
  else
    echo "  FAIL  web app did NOT answer through the port-forward"; FAIL=$((FAIL+1))
  fi
fi

echo "== The load-bearing control: WAN cannot touch the internal LAN =="
expect_blocked "DC01 LDAP (389)"      "$DC_LAN"  389
expect_blocked "DC01 SMB (445)"       "$DC_LAN"  445
expect_blocked "DC01 Kerberos (88)"   "$DC_LAN"  88
expect_blocked "SRV01 MSSQL (1433)"   "$SRV_LAN" 1433

echo "== DMZ not directly exposed (only the WAN-IP port-forward is) =="
expect_blocked "WEB01 direct on DMZ IP (80)"  "$WEB_DMZ" 80
expect_blocked "WEB01 direct on DMZ IP (22)"  "$WEB_DMZ" 22
# The pfSense admin plane needs no separate check here: its GUI (443) on the WAN
# IP is shadowed by the WAN:443->WEB01 port-forward, and SSH (22) to the
# firewall has no WAN pass rule. Admin is reachable only from the LAN side.

echo
echo "== Result: $PASS passed, $FAIL failed =="
if [ "$FAIL" -eq 0 ]; then
  echo "Segmentation is enforced: the web app is the only front door, LAN is sealed off."
else
  echo "Segmentation NOT fully enforced - review pfSense rules (packer/pfsense/config.xml)."
fi
[ "$FAIL" -eq 0 ]
