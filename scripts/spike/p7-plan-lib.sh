# p7-plan-lib.sh — shared helpers for the T339-T344 p7 receipts (attempt 4,
# run 20261017-083608-3277419): rendering a fabricplan and driving it through
# the fabric-executor (/v1/node/apply + /v1/node/verify) exactly the way the
# controller does, then reading the resulting state back with the spike
# recipe's own proof bodies.
#
# Choreography: the srv6 controller tier is scaled to 0 while the six p7
# receipts record, so executor-level state changes are deterministic (no
# drift-resync interleaving). The executor's FABRIC_PROBE_MAP is static
# process env, so onClient ops keep resolving with the controller down.
# scripts/spike/p7-restore.sh + the scale-up bring the as-built back after
# the last receipt. See gates/GATE5-ACCELERATOR-NOTE.md.

set -u

SPIKE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SPIKE_DIR/../.." && pwd)"
# shellcheck disable=SC1091
. "$SPIKE_DIR/spike-env.sh"

P7_EXECUTOR_URL=${P7_EXECUTOR_URL:-http://127.0.0.1:8084}
P7_PORTMAP=${P7_PORTMAP:-$REPO_ROOT/lab/profiles/sonic-vm/port-map.json}
P7_KIND=${P7_KIND:-sonic-vm}
P7_PROOFS="$REPO_ROOT/.wiggum/features/004-srv6-service-requests/gates/proofs"
P7_TMP=/tmp/p7-proofs
mkdir -p "$P7_TMP"

p7_go() {
    [[ -d /usr/lib/go-1.24/bin ]] && export PATH="/usr/lib/go-1.24/bin:$PATH"
    return 0
}

# p7_ops_counter — the executor's applied-ops counter, for the receipt's
# transparency lines (every apply through this harness moves it).
p7_ops_counter() {
    curl -s --max-time 5 "$P7_EXECUTOR_URL/metrics" \
        | awk '/^fabric_executor_ops_applied_total/{print $2; exit}'
}

# p7_context — the receipt's opening block.
p7_context() {
    echo "===== run context ====="
    echo "controller tier: $(kubectl -n agentic-netops-system get deploy agentic-netops-srv6-controller -o jsonpath='{.spec.replicas}' 2>/dev/null) replica(s) desired — scaled to 0 for the p7 receipts (deterministic executor-level state; restored by scripts/spike/p7-restore.sh); FABRIC_PROBE_MAP is static executor env, so onClient ops still resolve"
    echo "executor: $P7_EXECUTOR_URL ops_applied_total=$(p7_ops_counter)"
    echo "lab health gate: .wiggum/features/004-srv6-service-requests/health-check rc=0 before these receipts"
}

# p7_render_srv6 <serviceId> <leaf01Prefix> <leaf02Prefix> <outfile> — render
# the SRv6Service plan with debug/srv6-plan-dump (the same renderer the
# controller runs; the flags fix the allocations instead of claiming them).
p7_render_srv6() {
    p7_go
    go run -mod=vendor "$REPO_ROOT/debug/srv6-plan-dump" \
        -id "$1" -p0 "$2" -p1 "$3" -kind "$P7_KIND" > "$4" 2> "$4.err" \
        || { echo "RENDER-FAILED:" >&2; cat "$4.err" >&2; return 1; }
    rm -f "$4.err"
}

# p7_render_construct <network-yaml> <outfile> — render a Network construct
# plan with cmd/fabricplan-print (the same renderer ForNetwork exposes to the
# network controller; the ip-vrf/evpn and mac-vrf/evpn variants come from
# here because ForSRv6Service refuses those attachment kinds by name).
p7_render_construct() {
    p7_go
    go run -mod=vendor "$REPO_ROOT/cmd/fabricplan-print" \
        -f "$1" -portmap "$P7_PORTMAP" -kind "$P7_KIND" -vtep vtep1 \
        > "$2" 2> "$2.err" \
        || { echo "RENDER-FAILED:" >&2; cat "$2.err" >&2; return 1; }
    rm -f "$2.err"
}

# p7_wait_kernel <leaf01Expr> <leaf02Expr> — bounded poll for the
# orchagent-programmed kernel state the checks verify (mirrors
# vrf-apply.sh's vrf_k_ok loop; orchagent lags seconds behind CONFIG_DB).
p7_wait_kernel() {
    local i n c ok
    for i in $(seq 1 30); do
        ok=1
        for n in leaf01 leaf02; do
            c=$(container_of "$n")
            node_run "$c" "$([[ $n == leaf01 ]] && echo "$1" || echo "$2")" \
                >/dev/null 2>&1 || ok=0
        done
        [[ "$ok" == 1 ]] && { echo "kernel state converged (bounded 60s poll)"; return 0; }
        sleep 2
    done
    echo "KERNEL-STATE-TIMEOUT (60s)"
    return 1
}

# p7_settle <nodeExpr> — bounded poll until a condition that must become
# false is false (used after a construct rollback: BGP withdrawal of the
# trial's Type-5/Type-3 routes lags behind the config removal).
p7_settle() { # p7_settle <notExpr>  — loops while <notExpr> matches
    local i c out
    for i in $(seq 1 30); do
        c=$(container_of leaf01)
        out=$(node_run "$c" "$1" 2>/dev/null || true)
        [[ -z "$out" ]] && { echo "settled (bounded 60s poll)"; return 0; }
        sleep 2
    done
    echo "NOT-SETTLED (60s)"
    return 1
}

# p7_live_preclean — render the as-built (live-claims) plan and run its
# rollback ops on both leaves BEFORE the recipe substrate is built. The
# controller-era steering routes capture subnets the spike recipe makes
# LOCAL (e.g. the live leaf01 claim 192.168.0.0/24 steers leaf02->SID 4:11;
# the spike recipe gives leaf01 192.168.1.0/24 locally), and the recipe's
# own builder (vpn-setup.sh) never removes them — a left-over steering route
# blackholes the spike dataplane (observed live 2026-10-17). Best-effort:
# absent-row removals are tolerated by the executor path.
p7_live_preclean() {
    local plan="$P7_TMP/live-plan.json"
    p7_render_srv6 1 192.168.0.0/24 192.168.1.0/24 "$plan" || return 1
    python3 "$SPIKE_DIR/p7-plan-apply.py" "$plan" preclean
}

# p7_decap_repair <plan.json> — re-assert the plan's own End.DT46 decap ops
# after the kernel converged and assert vrftable == the device's current
# table id (the renderer derives the id live; see p7-plan-apply.py).
p7_decap_repair() {
    python3 "$SPIKE_DIR/p7-plan-apply.py" "$1" decap-repair
}

# p7_kernel_heal <subnet-leaf01> <subnet-leaf02> — post-apply kernel
# consistency heal (observed live 2026-10-17): a VRF-row/addr churn race can
# leave a leaf's connected PREFIX route missing from the VRF device's table
# while the addr's local/broadcast routes are present (intfmgrd re-added the
# addr mid-churn), which fails the read-back probes and churns the recipe's
# dance further. Heal: bounce the addr in the KERNEL (the CONFIG_DB row is
# untouched; intfmgrd sees kernel==CONFIG at the end), which deterministically
# re-derives prefix+local+broadcast into the CURRENT device table. Harness
# level only — no code, renderer or recipe change.
p7_kernel_heal() {
    local spec leaf subnet addr c rc=0
    for spec in "leaf01:$1" "leaf02:$2"; do
        leaf="${spec%%:*}"; subnet="${spec##*:}"
        addr="${subnet%.*}.1/${subnet#*/}"
        c=$(container_of "$leaf")
        if ! node_run "$c" "ip route show vrf Vrf1 2>/dev/null | grep -q '^${subnet} dev '"; then
            echo "   heal $leaf: connected route '${subnet} dev Ethernet12' missing from the VRF table — bouncing ${addr} in the kernel"
            node_run "$c" "sudo ip addr del ${addr} dev Ethernet12 2>/dev/null; sudo ip addr add ${addr} dev Ethernet12"
            local i=0 found=""
            while [[ $i -lt 15 ]]; do
                found=$(node_run "$c" "ip route show vrf Vrf1 2>/dev/null | grep -c '^${subnet} dev '" | tr -d '[:space:]')
                [[ "$found" != "0" && -n "$found" ]] && break
                i=$((i+1)); sleep 2
            done
            if [[ "$found" == "0" || -z "$found" ]]; then
                echo "   heal $leaf: FAILED — '${subnet} dev Ethernet12' still absent from the VRF table"; rc=1
            else
                echo "   heal $leaf: connected route re-derived into the VRF table"
            fi
        else
            echo "   heal $leaf: connected route '${subnet} dev Ethernet12' present — no bounce needed"
        fi
    done
    return $rc
}

# p7_enslave_heal — kernel-level VRF port re-enslavement (observed live
# 2026-10-17): after VRF-row/addr churn, intfmgrd can leave a port with
# CONFIG vrf_name=Vrf1 while the KERNEL port is un-enslaved and the connected
# route sits in the main table (the addr-bounce heal cannot fix this — the
# route re-derives into main, not the VRF table, because the master is gone).
# Heal: re-enslave the port to Vrf1 in the kernel (CONFIG_DB untouched — the
# kernel is moved to where CONFIG already says it must be), re-add the addr,
# and let the standard addr-bounce heal re-derive the routes.
p7_enslave_heal() {
    local leaf c subnet addr rc=0
    for spec in "leaf01:192.168.1.0/24" "leaf02:192.168.2.0/24"; do
        leaf="${spec%%:*}"; subnet="${spec##*:}"
        addr="${subnet%.*}.1/${subnet#*/}"
        c=$(container_of "$leaf")
        if [[ "$(node_run "$c" "ip link show Ethernet12 2>/dev/null | grep -c 'master Vrf1'" | tr -d '[:space:]')" == "0" ]] \
           && [[ -n "$(node_run "$c" "sudo redis-cli -n 4 hget 'INTERFACE|Ethernet12' vrf_name" | tr -d '[:space:]')" ]]; then
            echo "   enslave-heal $leaf: CONFIG vrf_name=Vrf1 but the kernel port is un-enslaved — re-enslaving in the kernel"
            node_run "$c" "sudo ip link set Ethernet12 nomaster 2>/dev/null; sudo ip addr del ${addr} dev Ethernet12 2>/dev/null; sudo ip link set Ethernet12 master Vrf1; sudo ip addr add ${addr} dev Ethernet12"
        else
            echo "   enslave-heal $leaf: kernel enslavement matches CONFIG — no re-enslave needed"
        fi
    done
    p7_kernel_heal "$1" "$2" || rc=1
    return $rc
}

# ci <label> <storedFile> <fixedPattern> <freshFile> — print the stored
# decisive line next to this run's line for one plan-vs-recipe item.
ci() {
    local s f
    s=$(grep -m1 -F -- "$3" "$2" 2>/dev/null || true)
    f=$(grep -m1 -F -- "$3" "$4" 2>/dev/null || true)
    printf -- '-- %s\n   stored: %s\n    fresh: %s\n' "$1" "${s:-<absent>}" "${f:-<absent>}"
}
