#!/usr/bin/env bash
# T080: Run three clean provision/test/off cycles, plus a second-provision
# idempotence check, an off-from-partial-state test, and a conformance-profile
# cycle. Stores logs under gates/proofs/cycles/.
#
# A "clean" cycle starts from Absent (off.sh --delete-kind true removes the
# Kind cluster, lab, and owned network at cycle end), runs the ordered
# provision workflow, the test phase against the live lab, and a full teardown.
#
# The capability gate (scripts/lib/qualify.sh) is executed by provision.sh and
# is the single source of truth for SRv6 qualification (FR-022). When the
# selected profile is not SRv6-qualified, provision exits non-zero with the
# documented message; the cycle runner records that designed outcome and
# continues with teardown so each cycle ends in a verified clean state.
set -u

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
PROOFS="$ROOT_DIR/.wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/cycles"
mkdir -p "$PROOFS"

# --- Skip-if-fresh: reuse a just-completed, still-valid prior pass's evidence
# wiggum's ensure_long_job() launches this command fresh on EVERY orchestrator
# restart — it scopes done-markers by run-id with no concept of "recent and
# still valid" (see INCIDENT-2026-08-31-ainetops-phase8.md, issue #9). Without
# this check, a restart mid-phase-8 unconditionally overwrites a fully
# verified ~90-minute pass sitting untouched on disk, at the very next write
# below (the `tee` that truncates cycles.run.log). This check must run before
# that line. It only affects future invocations of this script — it cannot
# retroactively help a copy that is already mid-run.
CYCLES_FRESH_MAX_AGE_SEC="${CYCLES_FRESH_MAX_AGE_SEC:-21600}"  # 6h default
if [[ -z "${CYCLES_FORCE_RERUN:-}" && -f "$PROOFS/cycles.run.log" ]]; then
  # The script's actual last stdout line, "CYCLES_DONE", is a bare echo (not
  # tee) so it never lands in cycles.run.log itself — only "[cycles] end ..."
  # (the line right before it) is tee'd into the file. That line only prints
  # if the script ran to its final statement uninterrupted (no `set -e`, but
  # a kill/crash mid-run stops output here too), so it's the correct on-disk
  # completion marker to check. Confirmed live 2026-08-31: a bare CYCLES_DONE
  # check here never matches, so the very first attempted skip silently fails
  # to skip.
  if [[ "$(tail -n1 "$PROOFS/cycles.run.log" 2>/dev/null)" == "[cycles] end "* ]]; then
    age=$(( $(date +%s) - $(stat -c %Y "$PROOFS/cycles.run.log") ))
    if (( age <= CYCLES_FRESH_MAX_AGE_SEC )); then
      echo "[cycles] skip-if-fresh: cycles.run.log already complete, ${age}s old (<= ${CYCLES_FRESH_MAX_AGE_SEC}s) — reusing existing evidence, not rerunning" | tee -a "$PROOFS/cycles.run.log"
      echo "CYCLES_DONE"
      exit 0
    fi
    echo "[cycles] skip-if-fresh: prior completed run is ${age}s old (> ${CYCLES_FRESH_MAX_AGE_SEC}s) — treating as stale, rerunning" >&2
  fi
fi

TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
echo "[cycles] start $TS host=$(hostname) cpu=$(nproc) mem=$(awk '/MemTotal/{print int($2/1024)"MB"}' /proc/meminfo)" | tee "$PROOFS/cycles.run.log"

run_provision() {
  # $1=log-file  $2=profile
  local log=$1 profile=$2
  echo "[cycles] provision profile=$profile log=$log" >>"$PROOFS/cycles.run.log"
  ( cd "$ROOT_DIR" && ./scripts/provision.sh --profile "$profile" --cluster-name ainetops --timeout 120s ) >"$log" 2>&1
  local rc=$?
  echo "[cycles] provision profile=$profile exit=$rc" | tee -a "$PROOFS/cycles.run.log"
  return 0
}

run_off() {
  local log=$1
  echo "[cycles] off log=$log" >>"$PROOFS/cycles.run.log"
  ( cd "$ROOT_DIR" && ./scripts/off.sh --cluster-name ainetops --delete-kind true --capture-evidence true ) >"$log" 2>&1
  local rc=$?
  echo "[cycles] off exit=$rc" | tee -a "$PROOFS/cycles.run.log"
  return 0
}

run_off_noop() {
  local log=$1
  ( cd "$ROOT_DIR" && ./scripts/off.sh --cluster-name ainetops --delete-kind true ) >"$log" 2>&1
  echo "[cycles] off-noop log=$(basename "$log") exit=$?" | tee -a "$PROOFS/cycles.run.log"
  return 0
}

run_tests() {
  local idx=$1
  ( cd "$ROOT_DIR" && AINETOPS_CLUSTER_NAME=ainetops ./tests/integration/fabric_verify.sh run ) >"$PROOFS/test-fabric-$idx.log" 2>&1
  echo "[cycles] test-fabric-$idx exit=$?" | tee -a "$PROOFS/cycles.run.log"
  ( cd "$ROOT_DIR" && ./tests/integration/topology_parity.sh ) >"$PROOFS/test-parity-$idx.log" 2>&1
  echo "[cycles] test-parity-$idx exit=$?" | tee -a "$PROOFS/cycles.run.log"
  ( cd "$ROOT_DIR" && AINETOPS_CLUSTER_NAME=ainetops ./tests/integration/observability_suite.sh ) >"$PROOFS/test-observability-$idx.log" 2>&1
  echo "[cycles] test-observability-$idx exit=$?" | tee -a "$PROOFS/cycles.run.log"
  # Additional Phase 8 required suites in the live lab window
  ( cd "$ROOT_DIR" && ./tests/integration/evpn_traffic.sh run ) >"$PROOFS/test-traffic-$idx.log" 2>&1
  echo "[cycles] test-traffic-$idx exit=$?" | tee -a "$PROOFS/cycles.run.log"
  ( cd "$ROOT_DIR" && ./tests/integration/srv6_capture_counters.sh run ) >"$PROOFS/test-srv6-capture-$idx.log" 2>&1
  echo "[cycles] test-srv6-capture-$idx exit=$?" | tee -a "$PROOFS/cycles.run.log"
  ( cd "$ROOT_DIR" && ./tests/integration/srv6_failover_path_change.sh run ) >"$PROOFS/test-srv6-failover-$idx.log" 2>&1
  echo "[cycles] test-srv6-failover-$idx exit=$?" | tee -a "$PROOFS/cycles.run.log"
  ( cd "$ROOT_DIR" && ./tests/integration/failure_recovery_invalid_yang.sh run ) >"$PROOFS/test-failure-$idx.log" 2>&1
  echo "[cycles] test-failure-$idx exit=$?" | tee -a "$PROOFS/cycles.run.log"
}

runtime_inventory() {
  local idx=$1
  if command -v kubectl >/dev/null 2>&1 && kubectl --context kind-ainetops cluster-info >/dev/null 2>&1; then
    kubectl --context kind-ainetops get pods -A -o wide 2>/dev/null | tee "$PROOFS/runtime-inventory-kubectl-$idx.log" || true
  else
    echo "no live kind-ainetops context at inventory time" >"$PROOFS/runtime-inventory-kubectl-$idx.log"
  fi
  helm list -A 2>/dev/null | tee "$PROOFS/runtime-inventory-helm-$idx.log" || true
  if command -v docker >/dev/null 2>&1; then
    docker ps -a --format "{{.ID}} {{.Image}} {{.Names}} {{.Labels}}" 2>/dev/null | tee "$PROOFS/runtime-inventory-docker-$idx.log" || true
  fi
  ( cd "$ROOT_DIR" && ./scripts/ci/denylist_runtime_scan.sh ) >"$PROOFS/runtime-scan-runtime-$idx.log" 2>&1
  echo "[cycles] runtime-scan-$idx exit=$?" | tee -a "$PROOFS/cycles.run.log"
}

# --- Three clean provision/test/off cycles (sonic-vs fast profile) -----------
for idx in 1 2 3; do
  echo "[cycles] ===== clean cycle $idx =====" | tee -a "$PROOFS/cycles.run.log"
  run_provision "$PROOFS/provision-$idx.log" sonic-vs
  run_tests "$idx"
  runtime_inventory "$idx"
  run_off "$PROOFS/off-$idx.log"
  # Repeatable no-op: off again from the just-cleaned state must succeed
  run_off_noop "$PROOFS/off-$idx-noop.log"
done

# --- Second-provision idempotence (provision twice without teardown) ---------
echo "[cycles] ===== second-provision idempotence =====" | tee -a "$PROOFS/cycles.run.log"
run_provision "$PROOFS/idempotence-provision-1.log" sonic-vs
run_provision "$PROOFS/idempotence-provision-2.log" sonic-vs
( cd "$ROOT_DIR" && ./scripts/off.sh --cluster-name ainetops --delete-kind true ) >"$PROOFS/idempotence-off.log" 2>&1
echo "[cycles] idempotence-off exit=$?" | tee -a "$PROOFS/cycles.run.log"

# --- Off from partial state (provision aborted at the capability gate) -------
echo "[cycles] ===== off-from-partial =====" | tee -a "$PROOFS/cycles.run.log"
# T077 off-from-PARTIAL: the provision here must FAIL partway so off.sh cleans a
# genuinely partial state. sonic-vs now passes the capability gate (re-pinned v2
# gNMI image), so the old sonic-vs call degraded into a full-provision test; the
# documented gate-fail path is the sonic-vm profile (capability gate fails →
# exit=1 → off.sh cleans the partial state) — the same shape off-conformance
# exercises below. (Fix 2026-09-01, operator reconciliation.)
run_provision "$PROOFS/partial-provision.log" sonic-vm
run_off "$PROOFS/off-from-partial.log"
run_off_noop "$PROOFS/off-from-partial-noop.log"

# --- Conformance-profile cycle (sonic-vm, where applicable) ------------------
echo "[cycles] ===== conformance profile (sonic-vm) =====" | tee -a "$PROOFS/cycles.run.log"
run_provision "$PROOFS/provision-conformance.log" sonic-vm
run_off "$PROOFS/off-conformance.log"

# --- Final runtime scan -------------------------------------------------------
( cd "$ROOT_DIR" && ./scripts/ci/denylist_runtime_scan.sh ) >"$PROOFS/runtime-scan-runtime.log" 2>&1
echo "[cycles] final runtime-scan exit=$?" | tee -a "$PROOFS/cycles.run.log"
echo "[cycles] end $(date -u +%Y-%m-%dT%H:%M:%SZ)" | tee -a "$PROOFS/cycles.run.log"
echo "CYCLES_DONE"
