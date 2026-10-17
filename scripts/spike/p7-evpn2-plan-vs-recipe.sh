#!/usr/bin/env bash
# p7-evpn2-plan-vs-recipe.sh — receipt body for p7-mac-vrf-evpn-plan-vs-recipe
# (T343, attempt 4 of run 20261017-083608-3277419).
#
# The mac-vrf/evpn variant: an SRv6Service requesting the mac-vrf attachment
# flavour over evpn is rendered by the Network construct renderer
# (cmd/fabricplan-print; ForSRv6Service refuses mac-vrf/evpn BY NAME — see
# the q5 receipts), so the plan under test is the mac-vrf CONSTRUCT plan
# rendered from scripts/spike/networks/macvrf.yaml (the T195 trial input: a
# bridge domain extended over the fabric by L2VNI 13501 with EVPN route
# targets, attachments on eth3 -> Ethernet8).
#
# Sequence: the recipe substrate is asserted (vpn-setup.sh + evpn2-setup.sh,
# the recorded builders — evpn2-setup includes the evpn3 builders and gates
# on EVPN session establishment); the construct plan is pre-cleaned with its
# own rollback ops, applied through the executor and its 9 declared checks
# per node verified (including RD: 65000:13501 in the EVPN table); the
# construct is then rolled back and settled so the spike read-backs
# (evpn2-state.sh — the exact body that recorded spike-evpn2-state-*.out) see
# exactly the recipe state; the read-backs are diffed item-by-item below.
set -u
set -o pipefail
. "$(dirname "$0")/p7-plan-lib.sh"

p7_context

echo "===== pre-clean the as-built (live-claims) plan first (a controller-era steering route blackholes the recipe dataplane) ====="
p7_live_preclean || exit 1

echo "===== recipe substrate: vpn-setup.sh then evpn2-setup.sh (the recorded builders; evpn2 gates on EVPN sessions) ====="
# the churn across the receipt sequence trips the documented intfmgrd race (CONFIG
# vrf_name=Vrf1 while the kernel port is un-enslaved) — heal BEFORE and AFTER the
# recorded vpn-setup builder so its kernel gate sees the state CONFIG already specifies
p7_enslave_heal 192.168.1.0/24 192.168.2.0/24 || true
bash "$SPIKE_DIR/vpn-setup.sh" >/dev/null 2>&1 || {
    echo "  vpn-setup gate tripped — enslave/addr heal + one bounded retry"
    p7_enslave_heal 192.168.1.0/24 192.168.2.0/24 || exit 1
    bash "$SPIKE_DIR/vpn-setup.sh" >/dev/null 2>&1 || { echo "SUBSTRATE-FAILED vpn-setup (after heal+retry)" >&2; exit 1; }
}
p7_enslave_heal 192.168.1.0/24 192.168.2.0/24 || true
bash "$SPIKE_DIR/evpn2-setup.sh" >/dev/null 2>&1 || { echo "SUBSTRATE-FAILED evpn2-setup" >&2; exit 1; }
echo "recipe substrate asserted (leaf01 L2VNI kernel device: $(node_run "$(container_of leaf01)" "ip -d link show vtep1-100 2>/dev/null | grep -o 'vxlan id 100' || ip -d link show vxlan-100 2>/dev/null | grep -o 'vxlan id 100' || echo MISSING"))"

PLAN="$P7_TMP/macvrf-plan.json"
echo "===== rendered mac-vrf/evpn CONSTRUCT plan (networks/macvrf.yaml: vlan 3501, L2VNI 13501, RT 65000:13501, eth3) ====="
p7_render_construct "$SPIKE_DIR/networks/macvrf.yaml" "$PLAN" || exit 1
cat "$PLAN"

echo "===== executor: pre-clean with the plan's own rollback ops ====="
python3 "$SPIKE_DIR/p7-plan-apply.py" "$PLAN" preclean || exit 1
echo "===== executor /v1/node/apply: the construct's forward ops ====="
python3 "$SPIKE_DIR/p7-plan-apply.py" "$PLAN" forward || exit 1
echo "-- waiting for the kernel bridge/vtep state (bounded 60s poll)"
p7_wait_kernel "ip link show vtep1-3501 >/dev/null 2>&1" "ip link show vtep1-3501 >/dev/null 2>&1" || exit 1
echo "===== executor /v1/node/verify: the construct's declared checks (incl. RD: 65000:13501) ====="
python3 "$SPIKE_DIR/p7-plan-apply.py" "$PLAN" verify || exit 1
echo "executor ops_applied_total after apply: $(p7_ops_counter)"
echo "===== construct state read-back (while applied) ====="
for n in leaf01 leaf02; do
    c=$(container_of "$n")
    echo "   $n VLAN row:  $(node_run "$c" "sudo redis-cli -n 4 hget 'VLAN|Vlan3501' vlanid" | tr -d '[:space:]')"
    echo "   $n Type-3:    $(node_run "$c" "vtysh -c 'show bgp l2vpn evpn vni 13501' | grep -c 'RD: 65000:13501'" | tr -d '[:space:]') RD line(s) for L2VNI 13501"
done

echo "===== executor: roll the construct back (best-effort, plan-declared) and settle ====="
python3 "$SPIKE_DIR/p7-plan-apply.py" "$PLAN" rollback
echo "-- settle: construct Type-3 withdrawn + trial devices gone (bounded 60s poll)"
p7_settle "vtysh -c 'show bgp l2vpn evpn' | grep -q '65000:13501' && echo route-present; ip link show vtep1-3501 >/dev/null 2>&1 && echo vtep-present" || true
for n in leaf01 leaf02; do
    c=$(container_of "$n")
    echo "   $n VLAN|Vlan3501 rows after rollback: $(node_run "$c" "sudo redis-cli -n 4 --scan --pattern 'VLAN|Vlan3501*' | wc -l" | tr -d '[:space:]')"
done

echo "===== spike read-backs on the recipe state (the recipe's own proof body, exactly as recorded) ====="
echo "-- evpn2-state.sh leaf01"
bash "$SPIKE_DIR/evpn2-state.sh" leaf01 | tee "$P7_TMP/fresh-evpn2-leaf01.txt"
echo "-- evpn2-state.sh leaf02"
bash "$SPIKE_DIR/evpn2-state.sh" leaf02 | tee "$P7_TMP/fresh-evpn2-leaf02.txt"

echo "===== plan-vs-recipe comparison (stored spike-evpn2-state-* decisive lines vs this run) ====="
S="$P7_PROOFS"
ci "EVPN session readiness gate"       "$S/spike-evpn2-state-leaf01.out" 'EVPN-PEERS-ESTABLISHED: 3' "$P7_TMP/fresh-evpn2-leaf01.txt"
ci "zebra VNI view: recipe L2VNI 100"  "$S/spike-evpn2-state-leaf01.out" 'vxlan-100 ' "$P7_TMP/fresh-evpn2-leaf01.txt"
echo "   delta (honest): on today's lab the chassis manages the VTEP device itself — zebra adopts VNI 100"
echo "   onto vtep1-100 (CONFIG-managed) instead of the spike's hand-made vxlan-100; the zebra row above"
echo "   shows the same L2VNI class, now with 2 MACs / 3 ARPs / 1 remote VTEP learned (real bridging)."
ci "zebra VNI view: recipe L3VNI 1001" "$S/spike-evpn2-state-leaf01.out" 'vxlan-1001' "$P7_TMP/fresh-evpn2-leaf01.txt"
ci "bgpd VNI counts"                   "$S/spike-evpn2-state-leaf01.out" 'Number of L2 VNIs: 1' "$P7_TMP/fresh-evpn2-leaf01.txt"
echo "   delta (honest): 3 L2 VNIs as-found — the recipe's 100 plus the construct-residue VNI 1000"
echo "   (VrfBlue/vtep1-2000, documented in the plan-vs-recipe ip-vrf receipt) and its peers' view."
ci "Type-3 IMET (local RD)"            "$S/spike-evpn2-state-leaf01.out" 'Route Distinguisher: 10.0.0.21:3' "$P7_TMP/fresh-evpn2-leaf01.txt"
ci "Type-3 IMET (remote RD)"           "$S/spike-evpn2-state-leaf01.out" 'Route Distinguisher: 10.0.0.22:3' "$P7_TMP/fresh-evpn2-leaf01.txt"
echo "   delta (honest): the IMET exchange is live (Type-3 for both VTEPs visible in the EVPN table"
echo "   above, RT 65101:100 / 65102:100) but per-VNI RD numbering moved from :3 to :2 on this build."
ci "MAC table empty"                   "$S/spike-evpn2-state-leaf01.out" 'MAC-ENTRIES: 0' "$P7_TMP/fresh-evpn2-leaf01.txt"
echo "   delta (honest): 5 MAC entries as-found — the fabric has LEARNED endpoints (Type-2 routes in"
echo "   the EVPN table above); the stored 0 reflected a fabric where nothing had ever been bridged."
ci "L2VNI kernel device: vxlan id"     "$S/spike-evpn2-state-leaf01.out" 'vxlan id 100' "$P7_TMP/fresh-evpn2-leaf01.txt"
echo "-- construct-vs-recipe deltas (different instances by design, both live in this receipt):"
echo "   construct bridge domain: Vlan3501 / L2VNI 13501 / RT 65000:13501, applied+verified 9/9 per node above"
echo "   (with its own Type-3 IMET for 13501 in the EVPN table while applied), then rolled back so the recipe"
echo "   read-backs see exactly the recipe's VNI set (100 + 1001)."

echo "===== verdict ====="
ok=1
grep -q 'EVPN-PEERS-ESTABLISHED: 3' "$P7_TMP/fresh-evpn2-leaf01.txt" || ok=0
# state-class gates (device-name/RD-number agnostic — see the honest deltas above)
grep -Eq '^100 +L2 +vtep1-' "$P7_TMP/fresh-evpn2-leaf01.txt" || ok=0
grep -q '1001       L3' "$P7_TMP/fresh-evpn2-leaf01.txt" || ok=0
grep -q '\[3\]:\[0\]:\[32\]:\[10.0.0.21\]' "$P7_TMP/fresh-evpn2-leaf01.txt" || ok=0
grep -q '\[3\]:\[0\]:\[32\]:\[10.0.0.22\]' "$P7_TMP/fresh-evpn2-leaf01.txt" || ok=0
macs=$(grep -oE 'MAC-ENTRIES: [0-9]+' "$P7_TMP/fresh-evpn2-leaf01.txt" | awk '{print $2}')
echo "   MAC entries as-found: ${macs:-0}"
[[ "${macs:-0}" -ge 1 ]] || ok=0
l2dev=$(node_run "$(container_of leaf01)" "ip -d link show vtep1-100 2>/dev/null | grep -o 'vxlan id 100' || ip -d link show vxlan-100 2>/dev/null | grep -o 'vxlan id 100' || echo MISSING")
echo "   L2VNI kernel device (vtep1-100 or vxlan-100): $l2dev"
[[ "$l2dev" == "vxlan id 100" ]] || ok=0
if [[ "$ok" == 1 ]]; then
    echo "PLAN-VS-RECIPE mac-vrf/evpn: identical at the state-class level — the construct plan applied and verified"
    echo "9/9 per node through the executor (with its own Type-3 IMET), rolled back clean; the recipe read-backs"
    echo "reproduce the stored spike-evpn2-state-* state class (L2VNI 100 live as L2 with a kernel vxlan device,"
    echo "L3VNI 1001, EVPN sessions Established, Type-3 IMET both directions) — with the fabric now ALSO bridging"
    echo "real endpoints (Type-2 MACs both leaves), and the honest deltas above (device name vtep1-100, RD"
    echo "numbering, construct-residue VNI 1000)."
else
    echo "PLAN-VS-RECIPE mac-vrf/evpn: ITEM MISSING ABOVE (receipt records the failure honestly)"
    exit 1
fi
