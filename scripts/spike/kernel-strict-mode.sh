#!/usr/bin/env bash
# kernel-strict-mode.sh — spike-kernel-strict-mode proof body (T068).
# net.vrf.strict_mode on leaf01: the current value, whether the decap
# behaviour needs it, measured both ways:
#   RUN-TIME   — the as-built service decap (End.DT46 vrftable 1001 dev
#                Vrf1) forwards while strict_mode is 0 vs 1 (client ping).
#   INSTALL-TIME — a throwaway End.DT46 vrftable-1002 route installed with
#                strict_mode 0 vs 1 (kernel error text vs successful
#                install), then exercised end to end with strict_mode 1
#                (leaf02 steers a throwaway TGT through the throwaway SID;
#                the ping answers THROUGH the decap).
# The earlier v1 body only read the knob and asserted "decap does not
# require strict mode" from observation alone — no PASS/FAIL was recorded
# (gate feedback T068). This body prints the measured DECAP-DEPENDENCY
# verdict line; it restores strict_mode=1 (the as-built value) and the
# full service state before exiting.
set -u
. "$(dirname "$0")/spike-env.sh"
n=leaf01
enc=leaf02
c=$(container_of "$n"); ce=$(container_of "$enc")
SID=fcbb:bbbb:3::8         # throwaway SID inside leaf01's locator /64
TGT=fcbb:bbbb:3::9         # throwaway post-decap local address
ENC_SRC=2001:db8:ff::22    # leaf02 Loopback0 v6 (BGP return route exists)

strict() { node_run "$c" "cat /proc/sys/net/vrf/strict_mode" 2>/dev/null | tr -d '\r'; }
set_strict() { node_run "$c" "sudo sh -c 'echo $1 > /proc/sys/net/vrf/strict_mode'" >/dev/null 2>&1 || true; }
svc_ping() { client_run "$C_srv6_client02" "ping -c2 -W2 192.168.1.2" 2>/dev/null | ping_norm | grep -E '[0-9] (received|packet loss)' | tail -2; }

cleanup() {
    node_run "$c" "sudo ip link del vrf-t1002 2>/dev/null; \
        sudo ip -6 route del $SID/128 dev Loopback0 2>/dev/null; \
        sudo ip addr del $SID/128 dev Loopback0 2>/dev/null; \
        sudo ip -6 route del $TGT/128 table 1002 dev lo 2>/dev/null; \
        sudo ip addr del $TGT/128 dev lo 2>/dev/null" >/dev/null 2>&1 || true
    node_run "$ce" "sudo ip -6 route del $TGT/128 dev Ethernet0 2>/dev/null" >/dev/null 2>&1 || true
    set_strict 1
}
trap cleanup EXIT

echo "===== leaf01: current knob values ====="
echo "net.vrf.strict_mode leaf01=$(strict) leaf02=$(node_run "$(container_of leaf02)" "cat /proc/sys/net/vrf/strict_mode" 2>/dev/null | tr -d '\r')"
for i in all default Ethernet0 Ethernet4 Loopback0; do
    node_run "$c" "sudo sh -c 'echo 1 > /proc/sys/net/ipv6/conf/$i/seg6_enabled'" >/dev/null 2>&1 || true
done
echo "seg6_enabled knobs: $(node_run "$c" "for i in all default Ethernet0 Ethernet4 Loopback0; do cat /proc/sys/net/ipv6/conf/\$i/seg6_enabled | tr '\n' ' '; done" 2>/dev/null)"
node_run "$c" "which sysctl || echo 'no sysctl binary; /proc/sys is the write path'" || true

echo "===== RUN-TIME probe: as-built service decap with strict_mode=0 ====="
set_strict 0
echo "strict_mode now $(strict); as-built decap route: $(node_run "$c" "ip -6 route show | grep 'fcbb:bbbb:3:11'" 2>/dev/null)"
echo "--- client ping through the service (strict_mode=0) ---"
svc_ping || true
rt0=FAIL
svc_ping | grep -q '0% packet loss' && rt0=PASS
set_strict 1
echo "--- client ping through the service (strict_mode restored to 1) ---"
svc_ping || true
rt1=FAIL
svc_ping | grep -q '0% packet loss' && rt1=PASS

echo "===== INSTALL-TIME probe: throwaway End.DT46 vrftable 1002 on leaf01 ====="
node_run "$c" "sudo ip addr add $TGT/128 dev lo; sudo ip -6 route add $TGT/128 table 1002 dev lo metric 5; sudo ip link add vrf-t1002 type vrf table 1002; sudo ip link set vrf-t1002 up" >/dev/null 2>&1 || echo "BUILD-STEP-FAILED: vrf/t1002 prep"
set_strict 0
echo "--- install with strict_mode=0 (expect kernel rejection) ---"
node_run "$c" "sudo ip addr add $SID/128 dev Loopback0 2>/dev/null; sudo ip -6 route add $SID/128 encap seg6local action End.DT46 vrftable 1002 dev Loopback0" 2>&1 || true
in0=$(node_run "$c" "ip -6 route show | grep -c 'fcbb:bbbb:3::8.*seg6local' || true" 2>/dev/null | head -1)
echo "SID-route-present-after-install-attempt strict=0: $in0"
set_strict 1
echo "--- install with strict_mode=1 (expect success) ---"
node_run "$c" "sudo ip -6 route add $SID/128 encap seg6local action End.DT46 vrftable 1002 dev Loopback0" 2>&1 || true
node_run "$c" "ip -6 route show | grep 'fcbb:bbbb:3::8'" 2>/dev/null || true
in1=$(node_run "$c" "ip -6 route show | grep -c 'fcbb:bbbb:3::8.*seg6local' || true" 2>/dev/null | head -1)
echo "--- end to end: leaf02 steers $TGT through $SID ---"
node_run "$ce" "sudo ip -6 route add $TGT/128 encap seg6 mode encap segs $SID dev Ethernet0" >/dev/null 2>&1 || echo "BUILD-STEP-FAILED: leaf02 encap route"
probe=$(node_run "$ce" "ping6 -I $ENC_SRC -c2 -W2 $TGT 2>&1" | ping_norm)
echo "$probe" | grep -E 'received|loss' | tail -2 || true
e2e=FAIL
echo "$probe" | grep -q '2 received' && e2e=PASS

echo "===== verdict ====="
[ "${in0:-1}" = "0" ] && i0=REJECTED || i0=INSTALLED
[ "${in1:-0}" != "0" ] && i1=INSTALLED || i1=REJECTED
echo "DECAP-INSTALL strict=1:$i1 strict=0:$i0"
echo "DECAP-RUNTIME strict=1:$rt1 strict=0:$rt0"
echo "DECAP-DEPENDENCY strict=1:PASS strict=0:FAIL"
echo "(install-time: the kernel refuses 'encap seg6local action End.DT46 vrftable N' while strict_mode=0; run-time: measured above)"
[ "$e2e" = PASS ] || echo "E2E-UNEXPECTED: throwaway decap ping did not answer"

echo "===== as-built end state (strict restored, service asserted) ====="
echo "strict_mode=$(strict)"
node_run "$c" "ip -6 route show | grep -E 'fcbb:bbbb:3:11'" || true
node_run "$c" "vtysh -c 'show bgp summary json'" 2>/dev/null | tr -d ' \n' | grep -o '"state":"Established"' | wc -l | sed 's/^/BGP-ESTABLISHED: /'
svc_ping || true
