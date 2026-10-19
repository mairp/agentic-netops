#!/usr/bin/env bash
# kernel-seg6.sh — spike-kernel-seg6 proof body (T066).
# Part 1: enable and read the seg6_enabled knobs on leaf02 (all, default,
#         Ethernet0, Ethernet4, Loopback0) from /proc/sys — factory knobs
#         are 0 on this image, and RX SRH processing is gated on them.
#         Also raise net.vrf.strict_mode to 1 via /proc: this kernel REJECTS
#         `encap seg6local action End.DT46 vrftable N` unless strict mode is
#         on (measured: "Strict mode for VRF is disabled").
# Part 2: decap dependency, measured END TO END: leaf02 builds the service
#         side (lo address TGT + table-1002 delivery + seg6local End.DT46
#         SID); leaf01 steers TGT through the SID with an encap seg6 route
#         over the fabric (the spines route the SID via leaf02's locator
#         /64). The ping then answers THROUGH the End.DT46 decap.
#         Flip leaf02's seg6_enabled to 0: the SRH packet is dropped on
#         ingress and the ping stops answering; restore to 1: answers.
#
# Measured device constraints for seg6local routes on this image
# (kernel 6.1.0-29-2-amd64):
#   - `dev lo`        : route installs rc=0 but the encap is SILENTLY
#                       STRIPPED (route shows plain `dev lo`) — same
#                       installs-but-drops behavior pass 2 measured for
#                       encap-mode routes on lo.
#   - `dev <physical>`: RTNETLINK "Invalid argument".
#   - `dev Loopback0` : works — encap visible in `ip -6 route get`.
# End.DT46 with `vrftable N` further REQUIRES an existing VRF device bound
# to table N ("Error: Table has no associated VRF device"). The recipe's
# production form is exactly this with the real per-VRF device (Vrf1,
# table 1001, created by vrf-apply); this proof stands one up as a
# throwaway for table 1002 (vrf-t1002) so the decap is exercisable
# without the full VRF apply.
# The test ping uses leaf01's Loopback0 v6 (2001:db8:ff::21) as source:
# leaf02 has no BGP route back to leaf01's LINK addresses (only loopback
# /128s are carried), so a link-sourced ping dies on the REPLY leg and
# would mask the decap result.
#
# (A purely self-contained loop over `lo` is NOT valid: a local dst
# address is served by the local table before any main-table encap
# route, so the ping would bypass the SRv6 path entirely.)
set -u
. "$(dirname "$0")/spike-env.sh"
dec=leaf02
enc=leaf01
cd_=$(container_of "$dec"); ce=$(container_of "$enc")

# Both test addresses sit INSIDE leaf02's originated locator /64
# (fcbb:bbbb:4::/64, from locator-reach) so the spines route them to
# leaf02. A service-SID-style fcbb:bbbb:4:98::/64 address would need the
# /48 that only vpn-setup originates — do not use one here.
SID=fcbb:bbbb:4::2         # seg6local End.DT46 service SID (throwaway)
TGT=fcbb:bbbb:4::1         # ping target, post-decap local address on leaf02
ENC_SRC=2001:db8:ff::21    # leaf01 Loopback0 v6: has a BGP return route
INGRESS_ALL="Ethernet0 Ethernet4 all"   # leaf02's spine-facing ingress + all

echo "===== $dec: enable seg6_enabled + vrf strict_mode (factory knobs are 0) ====="
for i in all default Ethernet0 Ethernet4 Loopback0; do
    node_run "$cd_" "sudo sh -c 'echo 1 > /proc/sys/net/ipv6/conf/$i/seg6_enabled'" >/dev/null 2>&1 || true
done
node_run "$cd_" "sudo sh -c 'echo 1 > /proc/sys/net/vrf/strict_mode'" >/dev/null 2>&1 || true
echo "===== $dec: seg6_enabled knobs ====="
for i in all default Ethernet0 Ethernet4 Loopback0; do
    v=$(node_run "$cd_" "cat /proc/sys/net/ipv6/conf/$i/seg6_enabled" 2>/dev/null | tr -d '\r')
    echo "$i=$v"
done

cleanup() {
    for i in $INGRESS_ALL; do
        node_run "$cd_" "sudo sh -c 'echo 1 > /proc/sys/net/ipv6/conf/$i/seg6_enabled'" >/dev/null 2>&1 || true
    done
    node_run "$cd_" "sudo ip link del vrf-t1002 2>/dev/null; \
        sudo ip -6 route del $SID/128 dev Loopback0 2>/dev/null; \
        sudo ip addr del $SID/128 dev Loopback0 2>/dev/null; \
        sudo ip -6 route del $TGT/128 table 1002 dev lo 2>/dev/null; \
        sudo ip addr del $TGT/128 dev lo 2>/dev/null" >/dev/null 2>&1 || true
    node_run "$ce" "sudo ip -6 route del $TGT/128 dev Ethernet0 2>/dev/null" >/dev/null 2>&1 || true
}
trap cleanup EXIT
cleanup

probe() {
    local out
    # NOTE: grep the whole normalized output — `tail -1` would keep only the
    # rtt line and never match "2 received" even on a healthy ping.
    out=$(node_run "$ce" "ping6 -I $ENC_SRC -c2 -W2 $TGT 2>&1" | ping_norm)
    if echo "$out" | grep -q '2 received'; then echo PASS; else echo FAIL; fi
}

echo "===== $dec: service side (TGT on lo + table 1002 + End.DT46 SID) ====="
for step in \
    "sudo ip addr add $TGT/128 dev lo" \
    "sudo ip -6 route add $TGT/128 table 1002 dev lo metric 5" \
    "sudo ip link add vrf-t1002 type vrf table 1002" \
    "sudo ip link set vrf-t1002 up" \
    "sudo ip addr add $SID/128 dev Loopback0" \
    "sudo ip -6 route add $SID/128 encap seg6local action End.DT46 vrftable 1002 dev Loopback0"; do
    node_run "$cd_" "$step" >/dev/null 2>&1 || echo "BUILD-STEP-FAILED($dec): $step"
done
node_run "$cd_" "ip -6 route show table 1002 | grep $TGT; ip -6 route get $SID" 2>&1 \
    | grep -E 'fcbb|seg6local' || true

echo "===== $enc: steer TGT through SID over the fabric ====="
node_run "$ce" "sudo ip -6 route add $TGT/128 encap seg6 mode encap segs $SID dev Ethernet0" >/dev/null 2>&1 \
    || echo "BUILD-STEP-FAILED($enc): encap route"
node_run "$ce" "ip -6 route show $TGT/128" 2>&1 | grep -E 'fcbb' || true

echo "===== decap dependency (leaf02 seg6_enabled 1 vs 0) ====="
# The seg6=1 probe retries a few times: the very first encapped packet can
# race the freshly re-added encap route's neighbor resolution on the
# spine-facing leg (measured once in recording). The seg6=0 probe is a
# single shot — a working decap must NOT come back once the RX gate is off.
r1=FAIL
for a in 1 2 3 4; do
    r1=$(probe)
    [[ "$r1" == PASS ]] && break
    sleep 2
done
for i in $INGRESS_ALL; do
    node_run "$cd_" "sudo sh -c 'echo 0 > /proc/sys/net/ipv6/conf/$i/seg6_enabled'" >/dev/null 2>&1 || true
done
r0=$(probe)
echo "DECAP-DEPENDENCY seg6=1:$r1 seg6=0:$r0"
[[ "$r1" == PASS && "$r0" == FAIL ]] || echo "DECAP-UNEXPECTED"
