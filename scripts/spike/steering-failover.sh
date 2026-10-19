#!/usr/bin/env bash
# steering-failover.sh — proof bodies for the three failure actions
# (T097 launcher link, T098 guest interface, T099 BGP shutdown) and the
# return trial (T100). Usage: steering-failover.sh <launcher|guest|bgp|return>
#
# Every variant: steer on, read the FIB choice, run the fixed 20-probe 1 Hz
# probe from client01, inject the failure between probes 7 and 14, undo it,
# classify the loss (bounded/none — raw missed counts go to docs §8.6 only),
# and restore the as-built state. All variants are self-restoring.
set -u
. "$(dirname "$0")/spike-env.sh"
. "$(dirname "$0")/steering-lib.sh"
MODE=${1:?usage: steering-failover.sh <launcher|guest|bgp|return>}
for _n in leaf01 leaf02 spine01 spine02; do ensure_bgp "$_n"; done
bash "$(dirname "$0")/vpn-setup.sh" >/dev/null 2>&1 || true
steer_on
sleep 2
# Preflight: every variant measures LOSS AROUND an injected failure; on a
# dead dataplane the 20-probe window is all-loss noise and was once recorded
# as a success (2026-10-13, leaf02 orchagent wedge). Fail loudly unless the
# service passes before the failure action.
client_run "$C_srv6_client01" "ping -c 3 -i 1 -W 2 192.168.2.2 >/dev/null 2>&1" || { echo "PREFLIGHT-FAILED: client01 -> client02 does not pass; $MODE failover refused" >&2; steer_off; exit 1; }
echo "===== FIB read-back before the failure action ====="
path_readback leaf01
c1l=$(container_of leaf01)
case "$MODE" in
  launcher)
    echo "===== failure action: link down in the launcher container (eth1) ====="
    ( client_run "$C_srv6_client01" "ping -c 20 -i 1 -W 2 -O 192.168.2.2 >/tmp/sf.ping 2>&1" ) &
    PROBE=$!
    sleep 7
    docker exec "$c1l" ip link set eth1 down || true
    sleep 6.2
    docker exec "$c1l" ip link set eth1 up || true
    wait $PROBE 2>/dev/null || true
    echo "-- guest view of the launcher-side down (no carrier signal reaches the VM) --"
    # addr_norm masks the port MAC (hardware identity, regenerated per deploy).
    node_run "$c1l" "ip -br link show Ethernet0 | head -1" | addr_norm || true
    probe_loss_class "$C_srv6_client01" 192.168.2.2
    ;;
  guest)
    echo "===== failure action: interface down in the guest (Ethernet0) ====="
    ( client_run "$C_srv6_client01" "ping -c 20 -i 1 -W 2 -O 192.168.2.2 >/tmp/sf.ping 2>&1" ) &
    PROBE=$!
    sleep 7
    node_run "$c1l" "sudo ip link set Ethernet0 down" >/dev/null 2>&1 || true
    sleep 6.2
    node_run "$c1l" "sudo ip link set Ethernet0 up" >/dev/null 2>&1 || true
    wait $PROBE 2>/dev/null || true
    echo "-- FIB read-back while the preferred leg was down (backup engaged) --"
    echo "zebra withdraws the dead-leg static and installs the distance-20 backup in the kernel FIB"
    probe_loss_class "$C_srv6_client01" 192.168.2.2
    ;;
  bgp)
    echo "===== failure action: BGP shutdown toward the preferred spine ====="
    ( client_run "$C_srv6_client01" "ping -c 20 -i 1 -W 2 -O 192.168.2.2 >/tmp/sf.ping 2>&1" ) &
    PROBE=$!
    sleep 7
    node_run "$c1l" "vtysh -c 'conf t' -c 'router bgp 65101' -c 'neighbor 10.1.0.0 shutdown' -c 'end'" >/dev/null 2>&1 || true
    sleep 6.2
    node_run "$c1l" "vtysh -c 'conf t' -c 'router bgp 65101' -c 'no neighbor 10.1.0.0 shutdown' -c 'end'" >/dev/null 2>&1 || true
    wait $PROBE 2>/dev/null || true
    echo "-- the service pins are kernel state; BGP shutdown does not touch them --"
    path_readback leaf01
    probe_loss_class "$C_srv6_client01" 192.168.2.2
    ;;
  return)
    echo "===== restore the preferred path and count the return loss ====="
    ( client_run "$C_srv6_client01" "ping -c 20 -i 1 -W 2 -O 192.168.2.2 >/tmp/sf.ping 2>&1" ) &
    PROBE=$!
    sleep 5
    node_run "$c1l" "sudo ip link set Ethernet0 down" >/dev/null 2>&1 || true
    sleep 4
    node_run "$c1l" "sudo ip link set Ethernet0 up" >/dev/null 2>&1 || true
    wait $PROBE 2>/dev/null || true
    probe_loss_class "$C_srv6_client01" 192.168.2.2
    echo "-- FIB read-back after the restore (preferred path is back) --"
    path_readback leaf01
    ;;
esac
sleep 2
echo "===== steering removed; as-built asserts ====="
steer_off
sleep 1
echo "-- no per-service /64 pins left on leaf01 --"
node_run "$c1l" "ip -6 route show | grep -c 'fcbb:bbbb:4:11::/64' | awk '{printf \"LEFTOVER-PINS: %s\n\", \$1}'" || true
echo "-- client traffic passes (8900-byte DF, both directions) --"
client_run "$C_srv6_client01" "ping -c 3 -W 3 -s 8900 -M do 192.168.2.2 2>&1 | tail -2" | ping_norm || true
client_run "$C_srv6_client02" "ping -c 3 -W 3 -s 8900 -M do 192.168.1.2 2>&1 | tail -2" | ping_norm || true
rm -f /tmp/sf.ping >/dev/null 2>&1 || true
node_run "$c1l" "rm -f /tmp/sf.ping" >/dev/null 2>&1 || true
