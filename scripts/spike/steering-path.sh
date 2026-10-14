#!/usr/bin/env bash
# steering-path.sh — spike-steering-path proof body (T096).
# Trial of the per-service preferred-spine mechanism: /64 pins to the peer's
# End.DT46 function space, preferred (metric 5) via the node's spine01 leg and
# backed (metric 20) via the spine02 leg on BOTH leaves. Read-back shows the
# kernel FIB choice; parallel SRH captures on the launcher-side uplinks show
# the service traffic on the preferred spine's link and NOT on the alternate's.
set -u
. "$(dirname "$0")/spike-env.sh"
. "$(dirname "$0")/steering-lib.sh"
for _n in leaf01 leaf02 spine01 spine02; do ensure_bgp "$_n"; done
bash "$(dirname "$0")/vpn-setup.sh" >/dev/null 2>&1 || true
steer_on
sleep 2
# Preflight: the capture asserts the service rides the preferred leg; on a
# dead dataplane this once recorded 0/0 SRH packets with exit 0 (2026-10-13,
# leaf02 orchagent wedge). Fail loudly instead of recording a dead path.
client_run "$C_srv6_client01" "ping -c 3 -i 1 -W 2 192.168.2.2 >/dev/null 2>&1" || { echo "PREFLIGHT-FAILED: client01 -> client02 does not pass; steering capture refused" >&2; steer_off; exit 1; }
echo "===== kernel FIB read-back (leaf01 -> leaf02 function space) ====="
path_readback leaf01
echo "===== kernel FIB read-back (leaf02 -> leaf01 function space) ====="
path_readback leaf02
echo "===== SRH capture window on both leaf01 uplinks while the client probes ====="
l1=$(container_of leaf01)
docker exec "$l1" sh -c "timeout 12 tcpdump -i eth1 -t -l -nn 'ip6 and ip6[6]=43' >/tmp/p1 2>/dev/null" >/dev/null 2>&1 &
CAP1=$!
docker exec "$l1" sh -c "timeout 12 tcpdump -i eth2 -t -l -nn 'ip6 and ip6[6]=43' >/tmp/p2 2>/dev/null" >/dev/null 2>&1 &
CAP2=$!
sleep 2
client_run "$C_srv6_client01" "ping -c 5 -i 1 -W 2 192.168.2.2 >/dev/null 2>&1" || true
wait $CAP1 2>/dev/null || true
wait $CAP2 2>/dev/null || true
echo "-- preferred spine01 leg (launcher eth1): SRH packets --"
n1=$(docker exec "$l1" sh -c "grep -c . /tmp/p1 2>/dev/null || echo 0" 2>/dev/null || echo 0)
echo "ETH1-SRH-PACKETS: $([ "${n1:-0}" -gt 0 ] 2>/dev/null && echo NONZERO || echo 0)"
echo "-- alternate spine02 leg (launcher eth2): SRH packets --"
n2=$(docker exec "$l1" sh -c "grep -c . /tmp/p2 2>/dev/null || echo 0" 2>/dev/null || echo 0)
echo "ETH2-SRH-PACKETS: $([ "${n2:-0}" -gt 0 ] 2>/dev/null && echo NONZERO || echo 0)"
docker exec "$l1" sh -c "rm -f /tmp/p1 /tmp/p2" >/dev/null 2>&1 || true
steer_off
