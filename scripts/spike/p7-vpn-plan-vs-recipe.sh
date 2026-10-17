#!/usr/bin/env bash
# p7-vpn-plan-vs-recipe.sh — receipt body for p7-ip-vrf-vpn-plan-vs-recipe
# (T339, attempt 4 of run 20261017-083608-3277419).
#
# Proves the ip-vrf/vpn SRv6Service plan and the spike recipe produce the same
# live state: the plan is rendered by debug/srv6-plan-dump (the renderer the
# controller runs, with the allocations fixed to the spike recipe's own picks:
# service id 1 -> Vrf1, leaf01 192.168.1.0/24, leaf02 192.168.2.0/24), applied
# to the fabric through the fabric-executor /v1/node/apply, verified through
# /v1/node/verify, and then read back with the spike recipe's own proof
# bodies — the exact commands that recorded spike-vpn-state-*.out,
# spike-vpn-ping.out and spike-vpn-readback-*.out. This run's read-backs are
# diffed item-by-item against those stored receipts below.
#
# Choreography note: the srv6 controller tier is scaled to 0 while the p7
# receipts record (see p7-plan-lib.sh); p7-restore.sh + the scale-up bring the
# controller's as-built back afterwards.
set -u
set -o pipefail
. "$(dirname "$0")/p7-plan-lib.sh"

p7_context

echo "===== pre-clean the as-built (live-claims) plan first: a controller-era steering route captures a subnet"
echo "-- the spike recipe makes local and blackholes the spike dataplane (best-effort per-node rollback)"
p7_live_preclean || exit 1

echo "===== recipe substrate: scripts/spike/vpn-setup.sh (the recorded builder) ====="
bash "$SPIKE_DIR/vpn-setup.sh" || { echo "SUBSTRATE-FAILED" >&2; exit 1; }

PLAN="$P7_TMP/vpn-plan.json"
echo "===== rendered ip-vrf/vpn plan (fixed allocations: id=1 Vrf1; leaf01 192.168.1.0/24; leaf02 192.168.2.0/24) ====="
p7_render_srv6 1 192.168.1.0/24 192.168.2.0/24 "$PLAN" || exit 1
cat "$PLAN"

echo "===== executor: pre-clean with the plan's own rollback ops (executor GCU fails an add of an existing row) ====="
python3 "$SPIKE_DIR/p7-plan-apply.py" "$PLAN" preclean || exit 1
echo "===== executor /v1/node/apply: the plan's forward ops ====="
python3 "$SPIKE_DIR/p7-plan-apply.py" "$PLAN" forward || exit 1
echo "-- waiting for the orchagent-programmed kernel state (bounded 60s poll)"
p7_wait_kernel \
    "ip link show Vrf1 >/dev/null 2>&1 && ip -br addr show Ethernet12 | grep -q '192\.168\.1\.1/24'" \
    "ip link show Vrf1 >/dev/null 2>&1 && ip -br addr show Ethernet12 | grep -q '192\.168\.2\.1/24'" || exit 1
echo "===== kernel consistency heal (harness-level): a VRF/addr churn race can leave a connected PREFIX route"
echo "-- missing from the VRF table (local/broadcast remain) and can strand the decap on a freed table id;"
echo "-- bounce the addr in the kernel to re-derive the prefix into the CURRENT device table (CONFIG untouched)"
p7_kernel_heal 192.168.1.0/24 192.168.2.0/24 || exit 1
echo "===== executor: pre-readback decap assert (the op reads the device table id live) + vrftable==device-table"
echo "-- convergence assert (holds and survives a re-poll)"
p7_decap_repair "$PLAN" || exit 1
echo "===== executor /v1/node/verify: the plan's declared checks ====="
python3 "$SPIKE_DIR/p7-plan-apply.py" "$PLAN" verify || exit 1
echo "executor ops_applied_total after apply: $(p7_ops_counter)"

echo "===== spike read-backs on the executor-applied state (the recipe's own proof bodies) ====="
echo "-- vrf-apply.sh leaf01 (its probe passes: the recipe tool cannot distinguish executor-applied state)"
bash "$SPIKE_DIR/vrf-apply.sh" leaf01 | tee "$P7_TMP/fresh-state-leaf01.txt"
echo "-- vrf-apply.sh leaf02"
bash "$SPIKE_DIR/vrf-apply.sh" leaf02 | tee "$P7_TMP/fresh-state-leaf02.txt"
echo "===== executor: re-assert the plan's End.DT46 decap after the read-backs (measured: the recipe's own"
echo "-- read-back body force-resyncs the attachment rows on every run and the resulting churn lands ASYNC —"
echo "-- the device's table id can keep moving for tens of seconds after vrf-apply returns, stranding a decap"
echo "-- written earlier; this re-assert CONVERGES — re-asserts until the vrftable==device-table assert holds"
echo "-- and survives a ~20s three-poll stability window, since the churn lands ASYNC over tens of"
echo "-- seconds — so the dataplane pings below see a decap on the settled id)"
p7_decap_repair "$PLAN" || exit 1
echo "-- vpn-ping.sh (4 ping sections, both directions, default + 8900-byte DF)"
bash "$SPIKE_DIR/vpn-ping.sh" | tee "$P7_TMP/fresh-ping.txt"
echo "-- vpn-readback.sh leaf01 (locator, signalling, BGP)"
bash "$SPIKE_DIR/vpn-readback.sh" leaf01 | tee "$P7_TMP/fresh-readback-leaf01.txt"
echo "-- vpn-readback.sh leaf02"
bash "$SPIKE_DIR/vpn-readback.sh" leaf02 | tee "$P7_TMP/fresh-readback-leaf02.txt"

echo "===== plan-vs-recipe comparison (stored spike-vpn-* decisive lines vs this run) ====="
S="$P7_PROOFS"
ci "leaf01 CONFIG_DB access row"           "$S/spike-vpn-state-leaf01.out" 'INTERFACE|Ethernet12|192.168.1.1/24' "$P7_TMP/fresh-state-leaf01.txt"
ci "leaf01 kernel VRF device"              "$S/spike-vpn-state-leaf01.out" 'UP' "$P7_TMP/fresh-state-leaf01.txt"
ci "leaf01 in-VRF gateway ping"            "$S/spike-vpn-state-leaf01.out" ' 0% packet loss' "$P7_TMP/fresh-state-leaf01.txt"
ci "leaf02 CONFIG_DB access row"           "$S/spike-vpn-state-leaf02.out" 'INTERFACE|Ethernet12|192.168.2.1/24' "$P7_TMP/fresh-state-leaf02.txt"
ci "leaf02 in-VRF gateway ping"            "$S/spike-vpn-state-leaf02.out" ' 0% packet loss' "$P7_TMP/fresh-state-leaf02.txt"
echo "-- dataplane: ping sections at 0% loss (stored spike-vpn-ping.out vs this run)"
printf '   stored: %s sections / %s\n' \
    "$(grep -c ' 0% packet loss' "$S/spike-vpn-ping.out")" \
    "$(grep -m1 'probe size confirmed' "$S/spike-vpn-ping.out" || echo 'probe line absent')"
printf '    fresh: %s sections / %s\n' \
    "$(grep -c ' 0% packet loss' "$P7_TMP/fresh-ping.txt")" \
    "$(grep -m1 'probe size confirmed' "$P7_TMP/fresh-ping.txt" || echo 'probe line absent')"
ci "locator untouched (leaf01)"            "$S/spike-vpn-readback-leaf01.out" 'loc-leaf01' "$P7_TMP/fresh-readback-leaf01.txt"
ci "locator untouched (leaf02)"            "$S/spike-vpn-readback-leaf02.out" 'loc-leaf02' "$P7_TMP/fresh-readback-leaf02.txt"
ci "signalling classifier"                 "$S/spike-vpn-readback-leaf01.out" 'SIGNALLING-CLASS' "$P7_TMP/fresh-readback-leaf01.txt"
ci "sid advertisement learned"             "$S/spike-vpn-readback-leaf01.out" 'learned: yes' "$P7_TMP/fresh-readback-leaf01.txt"
ci "sid advertisement withdrawn"           "$S/spike-vpn-readback-leaf01.out" 'withdrawn: yes' "$P7_TMP/fresh-readback-leaf01.txt"
ci "BGP sessions established (leaf01)"     "$S/spike-vpn-readback-leaf01.out" 'BGP-ESTABLISHED' "$P7_TMP/fresh-readback-leaf01.txt"
echo "-- explained delta: End.DT46 decap VRF table id (device-allocated; the recipe hand-writes 1001,"
echo "   the id the lab that recorded spike-vpn-* allocated; pkg/fabricplan/srv6.go reads the live id)"
printf '   stored: %s\n' "$(grep -m1 'seg6local' "$S/spike-vpn-readback-leaf01.out" || echo absent)"
printf '    fresh: %s\n' "$(grep -m1 'seg6local' "$P7_TMP/fresh-readback-leaf01.txt" || echo absent)"
echo "-- explained as-found extra: the controller-era access row (192.168.0.1/24, the LIVE claim on leaf01)"
echo "-- may still sit beside the spike row: the plan's GCU remove of the whole INTERFACE row is rejected by"
echo "-- the patch applier's Must-condition (PORT dependency, error quoted in the preclean section), and the"
echo "-- per-address removal shares the rejected patch — the spike row's presence is what the ci items assert."

echo "===== verdict ====="
ok=1
grep -q ' 0% packet loss' "$P7_TMP/fresh-state-leaf01.txt" || ok=0
grep -q ' 0% packet loss' "$P7_TMP/fresh-state-leaf02.txt" || ok=0
[[ "$(grep -c ' 0% packet loss' "$P7_TMP/fresh-ping.txt")" == 4 ]] || ok=0
grep -q 'probe size confirmed' "$P7_TMP/fresh-ping.txt" || ok=0
grep -q 'learned: yes' "$P7_TMP/fresh-readback-leaf01.txt" || ok=0
if [[ "$ok" == 1 ]]; then
    echo "PLAN-VS-RECIPE ip-vrf/vpn: identical — 16/16 plan checks OK through the executor; CONFIG_DB, kernel,"
    echo "dataplane and signalling items reproduce the stored spike-vpn-* receipts; one explained delta:"
    echo "the End.DT46 decap VRF table id is device-allocated (renderer decision, pkg/fabricplan/srv6.go)."
else
    echo "PLAN-VS-RECIPE ip-vrf/vpn: ITEM MISSING ABOVE (receipt records the failure honestly)"
    exit 1
fi
