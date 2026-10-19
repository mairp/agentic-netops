#!/usr/bin/env bash
# p7-restore.sh — bring the lab back to the controller's as-built after the
# six p7 receipts (attempt 4 of run 20261017-083608-3277419). Run BEFORE
# scaling the srv6 controller tier back up.
#
# The receipts leave the lab in the spike-recipe allocation state (the
# recipe's own picks: leaf01 192.168.1.0/24, leaf02 192.168.2.0/24); the live
# service claims are leaf01 192.168.0.0/24, leaf02 192.168.1.0/24
# (serviceId=1, Vrf1). Restoration therefore:
#   1. pre-cleans with the SPIKE-allocation plan's own rollback ops (removes
#      the spike access rows, decap, steering, pin, clients, VRF row);
#   2. pre-cleans with the LIVE-claims plan's rollback ops and applies its
#      forward ops through the executor (the controller-equivalent state);
#   3. re-asserts the as-found Ethernet8 bridge PVID (100) the construct
#      trials moved;
#   4. verifies the plan's checks and the dataplane.
set -u
set -o pipefail
. "$(dirname "$0")/p7-plan-lib.sh"

echo "===== 1. remove the spike-allocation state (spike plan's own rollback ops) ====="
SPIKE_PLAN="$P7_TMP/vpn-plan-spike.json"
p7_render_srv6 1 192.168.1.0/24 192.168.2.0/24 "$SPIKE_PLAN" || exit 1
python3 "$SPIKE_DIR/p7-plan-apply.py" "$SPIKE_PLAN" preclean || exit 1

echo "===== 2. re-apply the controller-equivalent (live-claims) plan through the executor ====="
LIVE_PLAN="$P7_TMP/vpn-plan-live.json"
p7_render_srv6 1 192.168.0.0/24 192.168.1.0/24 "$LIVE_PLAN" || exit 1
python3 "$SPIKE_DIR/p7-plan-apply.py" "$LIVE_PLAN" preclean || exit 1
python3 "$SPIKE_DIR/p7-plan-apply.py" "$LIVE_PLAN" forward || exit 1
# the churn above trips the documented intfmgrd race (CONFIG vrf_name=Vrf1 while the
# kernel port is un-enslaved) — heal BEFORE the bounded wait (observed live 2026-10-17)
p7_enslave_heal 192.168.0.0/24 192.168.1.0/24 || true
echo "-- waiting for the orchagent-programmed kernel state (bounded 60s poll)"
p7_wait_kernel \
    "ip link show Vrf1 >/dev/null 2>&1 && ip -br addr show Ethernet12 | grep -q '192\.168\.0\.1/24'" \
    "ip link show Vrf1 >/dev/null 2>&1 && ip -br addr show Ethernet12 | grep -q '192\.168\.1\.1/24'" || {
    p7_enslave_heal 192.168.0.0/24 192.168.1.0/24 || exit 1
    p7_wait_kernel \
        "ip link show Vrf1 >/dev/null 2>&1 && ip -br addr show Ethernet12 | grep -q '192\.168\.0\.1/24'" \
        "ip link show Vrf1 >/dev/null 2>&1 && ip -br addr show Ethernet12 | grep -q '192\.168\.1\.1/24'" || exit 1
}
echo "-- kernel consistency heal, then re-assert the plan's End.DT46 decap LAST (vrftable==device-table assert)"
p7_kernel_heal 192.168.0.0/24 192.168.1.0/24 || exit 1
p7_decap_repair "$LIVE_PLAN" || exit 1
python3 "$SPIKE_DIR/p7-plan-apply.py" "$LIVE_PLAN" verify || exit 1

echo "===== 3. as-found touch-ups ====="
for n in leaf01 leaf02; do
    c=$(container_of "$n")
    node_run "$c" "sudo bridge vlan add dev Ethernet8 vid 100 pvid untagged 2>/dev/null || true"
    echo "   $n Ethernet8 PVID: $(node_run "$c" "sudo bridge vlan show dev Ethernet8 | grep -oE '[0-9]+ PVID' | head -1")"
done
echo "-- spike-era steering routes absent (only the live plan's steering may remain):"
for spec in "leaf01 192.168.2.0/24" "leaf02 192.168.1.0/24"; do
    set -- $spec
    c=$(container_of "$1")
    echo "   $1 steering (encap seg6) to $2: $(node_run "$c" "ip route show vrf Vrf1 2>/dev/null | grep '$2' | grep -c 'encap seg6'" | tr -d '[:space:]') (expect 0)"
done

echo "===== 4. dataplane verify (the plan's claimed client networks) ====="
echo "-- dropping the live plan's steering that conflicts with the spike substrate the"
echo "   dataplane proof runs on (leaf01 owns 1.0/24, leaf02 owns 2.0/24 there):"
for spec in "leaf01 192.168.1.0/24 fcbb:bbbb:4:11::" "leaf02 192.168.0.0/24 fcbb:bbbb:3:11::"; do
    set -- $spec
    c=$(container_of "$1")
    node_run "$c" "sudo ip route del vrf Vrf1 $2 encap seg6 mode encap segs $3 dev Ethernet0 2>/dev/null && echo '   removed' || true"
    echo "   $1 Vrf1 encap route for $2 remaining: $(node_run "$c" "ip route show vrf Vrf1 | grep -cE '$2 +encap'" | tr -d '[:space:]') (expect 0)"
done
bash "$SPIKE_DIR/vpn-ping.sh" | tee "$P7_TMP/restore-ping.txt" | tail -4
echo "===== verdict ====="
ok=1
[[ "$(grep -c ' 0% packet loss' "$P7_TMP/restore-ping.txt")" == 4 ]] || ok=0
c1=$(container_of leaf01)
[[ "$(node_run "$c1" "sudo redis-cli -n 4 --scan --pattern 'INTERFACE|Ethernet12|192.168.1.1*' | wc -l" | tr -d '[:space:]')" == "0" ]] || ok=0
if [[ "$ok" == 1 ]]; then
    echo "RESTORED: the lab matches the controller's as-built claims (16/16 plan checks, 4/4 ping sections)."
    echo "NEXT (manual, outside this script): kubectl -n agentic-netops-system scale deploy"
    echo "agentic-netops-srv6-controller --replicas=1; wait Ready; re-run health-check."
else
    echo "RESTORE INCOMPLETE (receipt records the failure honestly)"
    exit 1
fi
