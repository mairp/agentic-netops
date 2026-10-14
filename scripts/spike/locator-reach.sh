#!/usr/bin/env bash
# locator-reach.sh — spike-locator-reach proof body (T073).
# Every node reaches every other node's locator: 12 of 12 ordered pairs.
# Each pair's probe is a ping from <src> to the test address of <dst>'s
# locator (fcbb:bbbb:<dst>::1, the Loopback0 /128 that carries the /48),
# after asserting the /48 origination on all four nodes (Loopback0 address,
# zebra static for the /48, bgpd network statement — the S5 pattern).
set -u
. "$(dirname "$0")/spike-env.sh"

originate() {
    # locator_of yields the full prefix (fcbb:bbbb:<n>::/48); the route and
    # network statements MUST carry the /48 (a bare fcbb:bbbb:4:: is
    # malformed for FRR and both commands silently fail), only the ping
    # address is the /128 host bit appended.
    local n=$1 addr a
    addr=$(locator_of "$n"); a="${addr%/*}1"
    local c; c=$(container_of "$n")
    node_run "$c" "sudo ip addr replace ${a}/128 dev Loopback0" >/dev/null 2>&1 || true
    node_run "$c" "vtysh -c 'conf t' -c 'ipv6 route ${addr} Loopback0' -c 'end'" >/dev/null 2>&1 || true
    local asn; asn=$(fabric_field "$n" 2)
    node_run "$c" "vtysh -c 'conf t' -c 'router bgp $asn' -c 'address-family ipv6 unicast' -c 'network ${addr}' -c 'end'" >/dev/null 2>&1 || true
}
for n in spine01 spine02 leaf01 leaf02; do originate "$n"; done

# Loop-free spine-locator pinning. Measured: with plain ECMP a leaf holds
# BOTH spine legs for a spine locator /64, and the symmetric kernel flow
# hash can pick the leg the packet just arrived from -> spine02 -> leaf02
# -> spine02 -> ... (captured echo request leaving the ingress port, ping
# ends in time-exceeded, +N errors). Pinning each leaf's route to the two
# spine locators on the OWNER spine's link makes every transit take a
# forward hop (the owner spine delivers locally), which removes the loop
# for every (src, dst) pair deterministically. metric 5 beats the bgp
# proto metric 20 in the kernel FIB without removing it.
pin_spine_locators() {
    local leaf=$1 n1 a1 n2 a2
    n1=spine01; n2=spine02
    a1=$(fabric_field "$leaf" 5 | python3 -c 'import sys; print(sys.stdin.read().strip().split(";")[0].split(",")[5])')
    a2=$(fabric_field "$leaf" 5 | python3 -c 'import sys; print(sys.stdin.read().strip().split(";")[1].split(",")[5])')
    node_run "$(container_of "$leaf")" \
        "sudo ip -6 route replace $(locator_of $n1) via $a1 dev Ethernet0 metric 5; \
         sudo ip -6 route replace $(locator_of $n2) via $a2 dev Ethernet4 metric 5" >/dev/null 2>&1 || true
}
pin_spine_locators leaf01
pin_spine_locators leaf02
sleep 8

echo "===== 12 ordered pairs: ping <src> -> <dst> locator test address ====="
pass=0; fail=0
for s in spine01 spine02 leaf01 leaf02; do
    for d in spine01 spine02 leaf01 leaf02; do
        [ "$s" = "$d" ] && continue
        addr=$(locator_of "$d"); a="${addr%/*}1"
        out=$(node_run "$(container_of "$s")" "ping6 -c2 -W2 $a 2>&1 | tail -2" | ping_norm)
        if echo "$out" | grep -q '2 received'; then r=PASS; pass=$((pass+1)); else r=FAIL; fail=$((fail+1)); fi
        echo "$s -> $d ($a): $r"
    done
done
echo "===== locator reachability: $pass of 12 ordered pairs ====="
[ "$fail" -eq 0 ] || echo "PAIRS-FAILED $fail"
