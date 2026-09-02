#!/usr/bin/env bash
# Run the Phase 8 verification test suites and capture logs under gates/proofs.
# T079 contract: this runner is STRICT. Every suite records its real exit code;
# the script prints a PASS/FAIL/SKIP summary and exits non-zero if any suite
# failed. Suites that legitimately require a live lab report their skip reason
# explicitly, so a green summary always means every listed suite actually ran
# or was skipped with a printed, greppable reason.
set -u

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
PROOFS_DIR="$ROOT_DIR/.wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs"
mkdir -p "$PROOFS_DIR"
SUMMARY="$PROOFS_DIR/tests.summary.txt"
: > "$SUMMARY"

# envtest control-plane binaries (real assets required — a skipped envtest is
# a failure, not a pass).
if [[ -z "${KUBEBUILDER_ASSETS:-}" ]]; then
  for d in /root/.local/share/kubebuilder-envtest/*-linux-amd64 /usr/local/kubebuilder/bin; do
    if [[ -x "$d/kube-apiserver" ]]; then export KUBEBUILDER_ASSETS="$d"; break; fi
  done
fi

record(){ printf '%s %s\n' "$2" "$1" >>"$SUMMARY"; }

suite(){
  local name=$1 out=$2; shift 2
  echo "[run] $name: $*" >"$out"
  set +e
  ( "$@" ) >>"$out" 2>&1
  local rc=$?
  set -e
  if [[ $rc -ne 0 ]]; then
    record "$name" "FAIL(rc=$rc)"
  elif grep -q 'SKIP-LIVE' "$out" || grep -q 'FABRIC_VERIFY_SKIPPED' "$out"; then
    # A suite that self-skipped (live-lab prerequisite absent) prints an
    # explicit marker and exits 0; it is a SKIP, never a PASS.
    record "$name" "SKIP-LIVE($(grep -m1 -oE 'SKIP-LIVE.*|FABRIC_VERIFY_SKIPPED' "$out" | head -c 70))"
  else
    record "$name" PASS
  fi
}

go_bin=""
command -v go >/dev/null 2>&1 && go_bin=go

# 1) API suite — CRD/envtest sanity (requires real envtest assets)
if [[ -n "$go_bin" ]]; then
  suite api "$PROOFS_DIR/tests.api.log" env KUBEBUILDER_ASSETS="${KUBEBUILDER_ASSETS:-}" \
    "$go_bin" test ./tests/envtest -v
else
  echo "FAIL: no go toolchain" >"$PROOFS_DIR/tests.api.log"; record api "FAIL(no-go)"
fi

# 2) Unit suite — all unit tests
[[ -n "$go_bin" ]] && suite unit "$PROOFS_DIR/tests.unit.log" "$go_bin" test ./tests/unit -v

# 3) Golden suite — table/golden tests only
[[ -n "$go_bin" ]] && suite golden "$PROOFS_DIR/tests.golden.log" "$go_bin" test ./tests/unit -run Golden -v

# 4) SDC validation suite — offline validators + path-register guards
[[ -n "$go_bin" ]] && suite sdc-validation "$PROOFS_DIR/tests.sdc-validation.log" \
  "$go_bin" test ./tests/unit -run 'OfflineValidate|RegisterGuard|RendererPathsCoveredByRegister|FullValidate' -v

# 5) Integration: API-level probes over gNMI and inventory checks (live lab)
suite integration "$PROOFS_DIR/tests.integration.log" "$ROOT_DIR/tests/integration/fabric_verify.sh" run

# 6) Failure suite — negative cases and recovery (live lab)
suite failure "$PROOFS_DIR/tests.failure.log" "$ROOT_DIR/tests/integration/failure_recovery_invalid_yang.sh" run

# 7) Traffic suite — EVPN client traffic (live lab)
suite traffic "$PROOFS_DIR/tests.traffic.log" "$ROOT_DIR/tests/integration/evpn_traffic.sh" run

# 8) SRv6 packet-capture suite (live lab)
suite srv6-capture "$PROOFS_DIR/tests.srv6-capture.log" "$ROOT_DIR/tests/integration/srv6_capture_counters.sh" run

# 9) SRv6 failover/path-change suite (live lab)
suite srv6-failover "$PROOFS_DIR/tests.srv6-failover.log" "$ROOT_DIR/tests/integration/srv6_failover_path_change.sh" run

# 10) Topology parity suite (live lab)
suite topology-parity "$PROOFS_DIR/tests.topology-parity.log" "$ROOT_DIR/tests/integration/topology_parity.sh"

# 11) Observability suite
suite observability "$PROOFS_DIR/tests.observability.log" "$ROOT_DIR/tests/integration/observability_suite.sh"

# 12) Teardown suite (lab-state safe/idempotent semantics)
suite teardown "$PROOFS_DIR/tests.teardown.log" "$ROOT_DIR/tests/integration/teardown_suite.sh"

echo "================ tests.summary.txt ================"
cat "$SUMMARY"
fails=$(grep -c '^FAIL' "$SUMMARY" || true)
skips=$(grep -c '^SKIP' "$SUMMARY" || true)
passes=$(grep -c '^PASS' "$SUMMARY" || true)
echo "[run_suites] PASS=$passes FAIL=$fails SKIP=$skips"
if [[ "$fails" -ne 0 ]]; then
  echo "ALL_SUITES_FAILED=$fails"
  exit 1
fi
echo "ALL_SUITES_PASSED"
