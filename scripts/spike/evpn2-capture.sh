#!/usr/bin/env bash
# evpn2-capture.sh — spike-evpn2-capture proof body (T094).
# The bridged variant must show NO VXLAN overlay traffic between the leaves:
# with no remote VTEP ever learnt (bgpd has 0 VNIs), the fabric window during
# the client probe carries zero UDP/4789 packets. Self-restoring.
set -u
. "$(dirname "$0")/spike-env.sh"
bash "$(dirname "$0")/evpn2-setup.sh" >/dev/null 2>&1 || true
c1=$(container_of leaf01)
cl01=$C_srv6_client01; cl02=$C_srv6_client02
echo "===== witnesses before the window ====="
node_run "$c1" "vtysh -c 'show bgp l2vpn evpn vni'" 2>/dev/null | grep -E 'Number of L2 VNIs' || true
node_run "$c1" "vtysh -c 'show evpn vni'" 2>/dev/null | grep -E '^100' || true
echo "===== fabric window: VXLAN overlay traffic during the client probe ====="
node_run "$c1" "sudo -n timeout 16 tcpdump -i any -t -l -nn 'udp port 4789' >/tmp/evpn2.cap 2>&1 &" || true
sleep 3
client_run "$cl01" "ping -c3 -W2 192.168.2.2 >/dev/null 2>&1" || true
sleep 5
echo "-- VXLAN packets in the window (expect 0) --"
node_run "$c1" "grep -cE '4789' /tmp/evpn2.cap; true" || true
node_run "$c1" "rm -f /tmp/evpn2.cap" >/dev/null 2>&1 || true
