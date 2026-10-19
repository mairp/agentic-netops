#!/usr/bin/env bash
# evpn2-rollback.sh — spike-evpn2-rollback proof body (T095).
# Remove the L2VNI attempt devices and then the whole EVPN attempt state
# (evpn3-rollback), and assert the node is back to the §2 as-built service:
# client pings pass both directions at 8900 DF, EVPN table empty, L2VNI
# devices gone, locators untouched (FR-006).
set -u
. "$(dirname "$0")/spike-env.sh"
bash "$(dirname "$0")/evpn2-setup.sh" >/dev/null 2>&1 || true
for n in leaf01 leaf02; do
    c=$(container_of "$n")
    node_run "$c" "sudo ip link del vxlan-100 2>/dev/null; sudo ip link del br-vni 2>/dev/null; ip link show vxlan-100 2>&1 | head -1; ip link show br-vni 2>&1 | head -1" || true
done
echo "===== full EVPN teardown (evpn3-rollback) ====="
bash "$(dirname "$0")/evpn3-rollback.sh" 2>&1 | grep -E '^(=====|--|192\.168|fcbb:|  locator|   locator|[0-9]+ packets)' || true
echo "===== assert: EVPN table empty ====="
node_run "$(container_of leaf01)" "vtysh -c 'show bgp l2vpn evpn'" 2>/dev/null | tail -1 || true
echo "===== assert: client traffic passes (8900-byte DF, both directions) ====="
client_run "$C_srv6_client01" "ping -c3 -W3 -s 8900 -M do 192.168.2.2 2>&1 | tail -2" | ping_norm || true
client_run "$C_srv6_client02" "ping -c3 -W3 -s 8900 -M do 192.168.1.2 2>&1 | tail -2" | ping_norm || true
