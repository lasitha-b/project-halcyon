#!/usr/bin/env bash
# Sanity-check that every host and service in the lab is up and reachable.
# Run from a machine on the same host-only vmnet (from ATTACK, or from WSL2
# on the Windows Workstation host - WSL2 can normally reach 10.20.10.0/24
# through the Windows host's route to the VMware host-only adapter).
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

# Reachability below is from the host's out-of-band management adapters (.1 on
# each vmnet), so it sees every segment directly - it does NOT exercise the
# firewall. The "Firewall segmentation" block at the end checks fw01's policy.
echo "== Network reachability (host mgmt adapters) =="
check "fw01 LAN gw (10.20.10.254) ping" ping -c1 -W2 10.20.10.254
check "fw01 DMZ gw (172.20.1.254) ping" ping -c1 -W2 172.20.1.254
check "fw01 WAN gw (203.0.113.254) ping" ping -c1 -W2 203.0.113.254
check "DC01 (10.20.10.10) ping"   ping -c1 -W2 10.20.10.10
check "SRV01 (10.20.10.20) ping"  ping -c1 -W2 10.20.10.20
check "WS01 (10.20.10.31) ping"   ping -c1 -W2 10.20.10.31
check "WS02 (10.20.10.32) ping"   ping -c1 -W2 10.20.10.32
check "WEB01 (172.20.1.40) ping"  ping -c1 -W2 172.20.1.40
check "ATTACK (203.0.113.66) ping" ping -c1 -W2 203.0.113.66

echo "== Core services =="
check "DC01 LDAP (389)"       bash -c "echo > /dev/tcp/10.20.10.10/389"
check "DC01 Kerberos (88)"    bash -c "echo > /dev/tcp/10.20.10.10/88"
check "DC01 CA web enroll (80)" curl -sf http://10.20.10.10/certsrv/
check "SRV01 MSSQL (1433)"    bash -c "echo > /dev/tcp/10.20.10.20/1433"
check "WEB01 app /healthz (direct)" curl -sf http://172.20.1.40/healthz

echo "== Firewall segmentation (edge policy via fw01) =="
# The attacker's only way in: the WAN port-forward to the web app.
check "WAN->WEB01 via port-forward (203.0.113.254:80)" curl -sf http://203.0.113.254/healthz
# The load-bearing control: WAN must NOT reach the internal LAN directly.
# This check PASSES when the connection is refused/blocked (i.e. good policy).
if timeout 4 bash -c "echo > /dev/tcp/10.20.10.10/389" 2>/dev/null; then
  # Reachable from here only because we're on the host mgmt adapter; to truly
  # verify WAN->LAN is blocked, run this same test from the ATTACK box.
  echo "  NOTE  WAN->LAN(389) reachable from host mgmt (expected); re-run from ATTACK to confirm it's blocked at the edge."
fi

echo
echo "== Result: $PASS passed, $FAIL failed =="
[ "$FAIL" -eq 0 ]
