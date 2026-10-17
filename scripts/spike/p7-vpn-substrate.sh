#!/usr/bin/env bash
# p7-vpn-substrate.sh — establish the ip-vrf/vpn recipe substrate for the p7
# receipts that need it (T340, T341-T344). In this order:
#
#   1. p7_live_preclean — the as-built (live-claims) plan's rollback ops run
#      first: a controller-era steering route captures a subnet the spike
#      recipe makes local and blackholes the spike dataplane (the recipe's
#      own builder never removes it; observed live 2026-10-17).
#   2. scripts/spike/vpn-setup.sh — the recorded builder — asserts the recipe
#      rows/routes/clients (idempotent; silent here).
#   3. the SRv6Service plan rendered with the spike recipe's own allocations
#      (service id 1 -> Vrf1; leaf01 192.168.1.0/24; leaf02 192.168.2.0/24)
#      is pre-cleaned with its own rollback ops and applied through the
#      fabric-executor, which repairs the one recipe value that cannot be
#      hardcoded: the End.DT46 decap's VRF table id is device-allocated
#      (pkg/fabricplan/srv6.go reads the live id; the recipe's hand-written
#      1001 matches only the lab that recorded the spike receipts).
#   4. p7_decap_repair — the same decap op re-asserted after the kernel
#      converged, with a vrftable==device-table assert (vrfmgrd can churn
#      the device right after the GCU re-add; observed live 2026-10-17).
#
# The executor-applied state is then the thing the spike read-back bodies
# (vrf-apply.sh, vpn-ping.sh, vpn-readback.sh) verify.
set -u
. "$(dirname "$0")/p7-plan-lib.sh"

p7_live_preclean || exit 1

if ! bash "$SPIKE_DIR/vpn-setup.sh" >/dev/null 2>&1; then
    echo "  vpn-setup gate tripped — kernel re-enslave heal + one bounded retry"
    echo "  (documented intfmgrd churn race: CONFIG vrf_name=Vrf1 while the kernel port is"
    echo "  un-enslaved and the connected route sits in the main table; observed live 2026-10-17)"
    p7_enslave_heal 192.168.1.0/24 192.168.2.0/24 || exit 1
    bash "$SPIKE_DIR/vpn-setup.sh" >/dev/null 2>&1 || { echo "SUBSTRATE-FAILED vpn-setup (after heal+retry)" >&2; exit 1; }
fi

PLAN="$P7_TMP/vpn-plan.json"
p7_render_srv6 1 192.168.1.0/24 192.168.2.0/24 "$PLAN" || exit 1
python3 "$SPIKE_DIR/p7-plan-apply.py" "$PLAN" preclean || exit 1
python3 "$SPIKE_DIR/p7-plan-apply.py" "$PLAN" forward || exit 1
# The VRF-row/addr churn above can leave leaf02's kernel port un-enslaved with
# the connected route in the main table (observed live 2026-10-17 twice) —
# heal BEFORE the bounded kernel wait (the wait alone would time out; the heal
# is exactly what re-derives the kernel state CONFIG already specifies).
p7_enslave_heal 192.168.1.0/24 192.168.2.0/24 || { echo "SUBSTRATE-FAILED kernel-heal" >&2; exit 1; }
p7_wait_kernel \
    "ip link show Vrf1 >/dev/null 2>&1 && ip -br addr show Ethernet12 | grep -q '192\.168\.1\.1/24'" \
    "ip link show Vrf1 >/dev/null 2>&1 && ip -br addr show Ethernet12 | grep -q '192\.168\.2\.1/24'" >/dev/null || {
    echo "SUBSTRATE-FAILED kernel" >&2; exit 1; }
p7_kernel_heal 192.168.1.0/24 192.168.2.0/24 || exit 1
p7_decap_repair "$PLAN" || exit 1
python3 "$SPIKE_DIR/p7-plan-apply.py" "$PLAN" verify >/dev/null || {
    echo "SUBSTRATE-FAILED checks" >&2; exit 1; }
echo "SUBSTRATE-READY (recipe rows + executor-applied plan; decap re-asserted; 16/16 checks)"
