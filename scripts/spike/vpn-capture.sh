#!/usr/bin/env bash
# vpn-capture.sh — spike-vpn-capture proof body (T080).
# Fabric-link capture during the client-to-client ping showing the SRv6
# encapsulation carrying the service SID: tcpdump runs inside the leaf01
# guest on the fabric link toward spine01 (Ethernet0), filtered on the
# remote service SID fcbb:bbbb:4:11:: (the outer destination), while
# srv6-client01 pings srv6-client02. ids/seqs normalized (FR-039).
set -u
. "$(dirname "$0")/spike-env.sh"
bash "$(dirname "$0")/vpn-setup.sh" >/dev/null 2>&1 || true
c1=$(container_of leaf01); cl01=$C_srv6_client01

# Preflight (silent on success): the capture asserts the service SID ON the
# wire; a dead dataplane once recorded an empty capture with exit 0
# (2026-10-13, leaf02 orchagent wedge). Fail loudly instead. If the dataplane
# is down (e.g. replaying right after the group's own rollback record), one
# visible rebuild + re-probe first — the marker lines are part of the record.
client_run "$cl01" "ping -c3 -W2 192.168.2.2 >/dev/null 2>&1" || {
    echo "PREFLIGHT-RETRY: dataplane down at capture start; vpn-setup.sh rebuild"
    bash "$(dirname "$0")/vpn-setup.sh" || { echo "PREFLIGHT-BUILD-FAILED" >&2; exit 1; }
    client_run "$cl01" "ping -c3 -W2 192.168.2.2 >/dev/null 2>&1" || { echo "PREFLIGHT-FAILED: client01 -> client02 does not pass; capture refused" >&2; exit 1; }
}
node_run "$c1" "sudo -n timeout 20 tcpdump -i any -t -l -nn -v 'ip6 host fcbb:bbbb:4:11::' >/tmp/vpn.cap 2>&1 &" || true
sleep 3
client_run "$cl01" "ping -c4 -W2 -s 8900 -M do 192.168.2.2 >/dev/null 2>&1" || true
sleep 6
echo "--- capture on leaf01 fabric link (Ethernet0, outer dst = service SID) ---"
_cap=$(node_run "$c1" "grep -E 'fcbb:bbbb:4:11' /tmp/vpn.cap | sed -E 's/id [0-9]+, seq [0-9]+, //; s/id [0-9]+, //; s/icmp_seq=[0-9]+//; s/length [0-9]+/length L/g; s/^[A-Za-z0-9]+[[:space:]]+(In|Out) IP6/OUT-IP6/' | LC_ALL=C sort -u | head -8" 2>/dev/null || true)
[ -n "$_cap" ] || { echo "CAPTURE-EMPTY: service SID seen nowhere on the wire" >&2; exit 1; }
printf '%s\n' "$_cap"
echo "--- decap witness: srv6local in the kernel route of leaf02's SID ---"
node_run "$(container_of leaf02)" "ip -6 route show | grep 'fcbb:bbbb:4:11'" || true
node_run "$c1" "rm -f /tmp/vpn.cap" >/dev/null 2>&1 || true
echo "--- the service SID carried on the wire: fcbb:bbbb:4:11:: ---"
