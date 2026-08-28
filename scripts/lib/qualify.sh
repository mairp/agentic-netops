#!/usr/bin/env bash
# Lab qualification harness (Phase 2): run capability tests and gate downstream
set -euo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
REPORT_DIR="${ROOT_DIR}/.wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs"
mkdir -p "$REPORT_DIR"

# Accumulators for machine-readable report (visible to helpers)
ALL_TESTS=()
ALL_STATUSES=()
FAILED=0

run_test() {
  local name=$1
  echo "[qualify] Running $name" | tee -a "$REPORT_DIR/qualify.run.log"
  "${ROOT_DIR}/tests/integration/sonic_gnmi_suite.sh" --run "$name" 2>&1 | tee -a "$REPORT_DIR/qualify.$name.out.log"
}

record_result() {
  local name=$1 status=$2
  ALL_TESTS+=("$name")
  ALL_STATUSES+=("$status")
  if [[ "$status" != "pass" ]]; then FAILED=1; fi
}

emit_report() {
  {
    echo '{"tests":['
    local sep=""; local i
    for ((i=0; i<${#ALL_TESTS[@]}; i++)); do
      printf '%s{"name":"%s","status":"%s"}' "$sep" "${ALL_TESTS[$i]}" "${ALL_STATUSES[$i]}"
      sep=",";
    done
    if (( FAILED != 0 )); then
      echo '],"result":"fail"}'
    else
      echo '],"result":"pass"}'
    fi
  } > "$REPORT_DIR/qualify.report.json"
}

bail() {
  local msg=$1
  emit_report
  echo "[qualify] FAILED: $msg" | tee -a "$REPORT_DIR/qualify.run.log"
  exit 1
}

main() {
  local core_failed=0
  # gNMI core tests (always run all in this block, then gate downstream on any failure)
  for t in Capabilities Get Set Subscribe sonic-srv6; do
    if run_test "$t"; then
      record_result "$t" "pass"
    else
      record_result "$t" "fail"
      core_failed=1
    fi
  done
  if (( core_failed != 0 )); then
    bail "core capability failure; not running EVPN/SRv6 or YANG path suites"
  fi

  # Persistence test: program a value, restart, verify value persists
  echo "[qualify] Running persistence pre-set (Set)"
  if run_test Set && "${ROOT_DIR}/scripts/lib/persistence.sh" --run; then
    record_result "persistent" "pass"
  else
    record_result "persistent" "fail"
    bail "persistence check failed; not running EVPN/SRv6 or YANG path suites"
  fi

  # EVPN/SRv6 capability coverage (short-circuit on first failure)
  for t in EVPN-Type2 EVPN-Type3 EVPN-Type5 SRv6-Underlay H.Encaps.Red End End.DT46 SID-list Decapsulation Counters; do
    echo "[qualify] Running $t"
    if "${ROOT_DIR}/tests/integration/evpn_srv6_suite.sh" --run "$t" 2>&1 | tee -a "$REPORT_DIR/qualify.$t.out.log"; then
      record_result "$t" "pass"
    else
      record_result "$t" "fail"
      bail "EVPN/SRv6 capability '$t' failed; gating remaining tests"
    fi
  done

  # Required OpenConfig/SONiC YANG path qualification
  if "${ROOT_DIR}/tests/integration/yang_paths_suite.sh" --run YANG-Paths 2>&1 | tee -a "$REPORT_DIR/qualify.YANG-Paths.out.log"; then
    record_result "YANG-Paths" "pass"
  else
    record_result "YANG-Paths" "fail"
    bail "YANG path qualification failed"
  fi

  # Write machine-readable report and success log
  emit_report
  echo "[qualify] OK" | tee -a "$REPORT_DIR/qualify.run.log"
}

main "$@"
