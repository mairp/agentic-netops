#!/usr/bin/env bash
# evpn3-ping.sh — spike-evpn3-ping proof body (T085).
# The dataplane bar for the routed EVPN variant, applied in three phases so
# the result says exactly what forwarded:
#   A. steering route away, export knobs on: the ping FAILS. The knobs do
#      leak the client subnets into the default tables and announce them to
#      the spines over plain eBGP (isolation defect, witnessed below), but
#      the VRF-to-VRF import stays RT-gated (65101:100 vs 65102:100), so
#      Vrf1 holds no route toward the peer and nothing forwards;
#   B. export knobs removed (the honest EVPN-signalling attempt): the ping
#      FAILS — no EVPN-derived forwarding state exists;
#   C. steering route back (the §2 as-built service): the ping PASSES.
# Self-restoring; never runs destructive (replay re-runs it).
set -u
. "$(dirname "$0")/spike-env.sh"
. "$(dirname "$0")/evpn3-lib.sh"
bash "$(dirname "$0")/evpn3-setup.sh" >/dev/null 2>&1 || true
c1=$(container_of leaf01); c2=$(container_of leaf02)
cl01=$C_srv6_client01; cl02=$C_srv6_client02

echo "===== pre-check: EVPN table on leaf01 (no EVPN-derived forwarding state) ====="
node_run "$c1" "vtysh -c 'show bgp l2vpn evpn'" 2>/dev/null | tail -1 || true

echo "===== A: remove the §2 steering route on both leaves ====="
node_run "$c1" "sudo ip route del 192.168.2.0/24 vrf Vrf1 2>/dev/null; ip route show vrf Vrf1 | grep '192.168.2.0' || echo 'STEERING-ROUTE-ABSENT'" || true
node_run "$c2" "sudo ip route del 192.168.1.0/24 vrf Vrf1 2>/dev/null; ip route show vrf Vrf1 | grep '192.168.1.0' || echo 'STEERING-ROUTE-ABSENT'" || true
echo "-- leak witness: client subnets in the DEFAULT tables --"
echo "-- leaf01: $(evpn3_leak_state leaf01)" || true
echo "-- spine01: $(node_run "$(container_of spine01)" "ip route show | grep -q '192.168' && echo CLIENT-ROUTES-PRESENT || echo CLEAN" 2>/dev/null)" || true
echo "-- witness: Vrf1 holds no route toward the peer (VPN import is RT-gated) --"
sleep 3
node_run "$c1" "ip route show vrf Vrf1 | grep '192.168.2.0' >/dev/null && echo 'PEER-ROUTE-IN-VRF1' || echo 'PEER-VRF-ROUTE-ABSENT'" || true

echo "===== A: client01 -> client02 (default size) with only the leaked default-table state ====="
client_run "$cl01" "ping -c3 -W3 192.168.2.2 2>&1 | tail -2" | ping_norm || true

echo "===== B: remove the per-VRF export knobs (honest EVPN-signalling attempt) ====="
evpn3_leak_off leaf01 65101 192.168.1.0/24
evpn3_leak_off leaf02 65102 192.168.2.0/24
sleep 4
echo "-- leak witness after knob removal --"
echo "-- leaf01: $(evpn3_leak_state leaf01)" || true
echo "-- leaf02: $(evpn3_leak_state leaf02)" || true

echo "===== B: client01 -> client02 with ONLY EVPN signalling standing ====="
client_run "$cl01" "ping -c3 -W3 192.168.2.2 2>&1 | tail -2" | ping_norm || true
echo "===== B: client02 -> client01 with ONLY EVPN signalling standing ====="
client_run "$cl02" "ping -c3 -W3 192.168.1.2 2>&1 | tail -2" | ping_norm || true

echo "===== C: restore knobs and the §2 steering route ====="
evpn3_leak_on leaf01 65101 192.168.1.0/24
evpn3_leak_on leaf02 65102 192.168.2.0/24
node_run "$c1" "sudo ip route replace 192.168.2.0/24 vrf Vrf1 encap seg6 mode encap segs fcbb:bbbb:4:11:: dev Ethernet0; ip route show vrf Vrf1 | grep '192.168.2.0'" || true
node_run "$c2" "sudo ip route replace 192.168.1.0/24 vrf Vrf1 encap seg6 mode encap segs fcbb:bbbb:3:11:: dev Ethernet0; ip route show vrf Vrf1 | grep '192.168.1.0'" || true

echo "===== C: client01 -> client02 after restore (8900-byte payload DF) ====="
client_run "$cl01" "ping -c3 -W3 -s 8900 -M do 192.168.2.2 2>&1 | tail -2" | ping_norm || true
echo "===== C: client02 -> client01 after restore (8900-byte payload DF) ====="
client_run "$cl02" "ping -c3 -W3 -s 8900 -M do 192.168.1.2 2>&1 | tail -2" | ping_norm || true
echo "===== verdict material: EVPN-signalled dataplane absent; only the §2 static encap forwards; the export knobs leak client subnets into the default table ====="
