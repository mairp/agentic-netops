#!/usr/bin/env bash
# evpn3-capture.sh — spike-evpn3-capture proof body (T086).
# Two fabric-window captures on leaf01 (-i any, IP-only, during the
# client01->client02 probe):
#   capture 1 — the EVPN-signalling attempt: steering route away AND the
#     export knobs removed; Vrf1 holds no route toward the peer, so the
#     requests die inside leaf01 and the window must carry ZERO echo
#     replies (no EVPN-derived encap exists to forward anything);
#   capture 2 — control: the §2 steering route restored; the same window
#     then carries the SRv6-encapped echo flow, proving the capture method
#     sees real traffic when it exists (so capture 1's zero is meaningful).
# Self-restoring; never runs destructive (replay re-runs it).
set -u
. "$(dirname "$0")/spike-env.sh"
. "$(dirname "$0")/evpn3-lib.sh"
bash "$(dirname "$0")/evpn3-setup.sh" >/dev/null 2>&1 || true
c1=$(container_of leaf01); c2=$(container_of leaf02)
cl01=$C_srv6_client01; cl02=$C_srv6_client02

echo "===== capture 1: steering away + export knobs removed (EVPN attempt) ====="
node_run "$c1" "sudo ip route del 192.168.2.0/24 vrf Vrf1 2>/dev/null" >/dev/null 2>&1 || true
node_run "$c2" "sudo ip route del 192.168.1.0/24 vrf Vrf1 2>/dev/null" >/dev/null 2>&1 || true
evpn3_leak_off leaf01 65101 192.168.1.0/24
evpn3_leak_off leaf02 65102 192.168.2.0/24
sleep 6
echo "-- witnesses before capture 1 --"
echo "-- leaf01 default table: $(evpn3_leak_state leaf01)"
node_run "$c1" "ip route show vrf Vrf1 | grep '192.168.2.0' >/dev/null && echo 'PEER-ROUTE-IN-VRF1' || echo 'PEER-VRF-ROUTE-ABSENT'" || true
node_run "$c1" "sudo -n timeout 16 tcpdump -i any -t -l -nn 'ip and net 192.168.0.0/16' >/tmp/evpn3a.cap 2>&1 &" || true
sleep 3
client_run "$cl01" "ping -c3 -W2 192.168.2.2 >/dev/null 2>&1" || true
sleep 5
echo "-- ECHO-REPLIES in the window (expect 0: requests die inside leaf01) --"
node_run "$c1" "grep -cE 'ICMP echo reply' /tmp/evpn3a.cap; true" || true
node_run "$c1" "rm -f /tmp/evpn3a.cap" >/dev/null 2>&1 || true

echo "===== capture 2: control — §2 steering route restored ====="
node_run "$c1" "sudo ip route replace 192.168.2.0/24 vrf Vrf1 encap seg6 mode encap segs fcbb:bbbb:4:11:: dev Ethernet0; ip route show vrf Vrf1 | grep '192.168.2.0'" || true
node_run "$c2" "sudo ip route replace 192.168.1.0/24 vrf Vrf1 encap seg6 mode encap segs fcbb:bbbb:3:11:: dev Ethernet0; ip route show vrf Vrf1 | grep '192.168.1.0'" || true
sleep 3
node_run "$c1" "sudo -n timeout 16 tcpdump -i any -t -l -nn 'ip6 and ip6[6]=43' >/tmp/evpn3b.cap 2>&1 &" || true
sleep 3
client_run "$cl01" "ping -c3 -W2 192.168.2.2 >/dev/null 2>&1" || true
sleep 5
echo "-- SRv6-encapped echo flow in the window (expect NONZERO; ipv6-normalized) --"
node_run "$c1" "grep -E 'IP6' /tmp/evpn3b.cap | sed -E 's/^.* IP6 /IP6 /; s/id [0-9]+, //; s/seq [0-9]+/seq N/g; s/length [0-9]+/length L/g' | sort -u | head -4" || true
node_run "$c1" "grep -cE 'ICMP echo reply' /tmp/evpn3b.cap | awk '{printf \"ECHO-REPLIES: %s\n\", (\$1>0)?\"NONZERO\":\"0\"}'" || true
node_run "$c1" "rm -f /tmp/evpn3b.cap" >/dev/null 2>&1 || true

echo "===== restore the export knobs (proof ends in the evpn3 setup state) ====="
evpn3_leak_on leaf01 65101 192.168.1.0/24
evpn3_leak_on leaf02 65102 192.168.2.0/24
sleep 2
evpn3_leak_state leaf01
