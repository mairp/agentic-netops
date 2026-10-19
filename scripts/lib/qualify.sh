#!/usr/bin/env bash
# Lab qualification harness (Phase 2): run capability tests and gate downstream
set -euo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
REPORT_DIR="${ROOT_DIR}/.wiggum/features/001-agentic-netops-sonic-evpn-fabric/gates/proofs"
mkdir -p "$REPORT_DIR"

# Accumulators for machine-readable report (visible to helpers)
ALL_TESTS=()
ALL_STATUSES=()
FAILED=0
SKIPPED=0
PASSED=0

run_test() {
  local name=$1
  echo "[qualify] Running $name" | tee -a "$REPORT_DIR/qualify.run.log"
  "${ROOT_DIR}/tests/integration/sonic_gnmi_suite.sh" --run "$name" 2>&1 | tee -a "$REPORT_DIR/qualify.$name.out.log"
}

record_result() {
  local name=$1 status=$2
  ALL_TESTS+=("$name")
  ALL_STATUSES+=("$status")
  case "$status" in
    pass) PASSED=$((PASSED + 1)) ;;
    # T030: a skip is not a pass and not a fail — only failures gate.
    skip) SKIPPED=$((SKIPPED + 1)) ;;
    *) FAILED=1 ;;
  esac
}

emit_report() {
  {
    echo '{"tests":['
    local sep=""; local i
    for ((i=0; i<${#ALL_TESTS[@]}; i++)); do
      printf '%s{"name":"%s","status":"%s"}' "$sep" "${ALL_TESTS[$i]}" "${ALL_STATUSES[$i]}"
      sep=",";
    done
    # T030 (contracts/capability-record.md §5): totals make skips first-class —
    # result is pass iff failed == 0 (skips never count as passed).
    printf '],"totals":{"passed":%s,"failed":%s,"skipped":%s},"result":"%s"}\n' \
      "$PASSED" "$FAILED" "$SKIPPED" \
      "$(if (( FAILED != 0 )); then echo fail; else echo pass; fi)"
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
  # Materialize lab credentials/TLS locally before any gNMI capability test (T076)
  # shellcheck source=lab_secrets.sh
  source "${ROOT_DIR}/scripts/lib/lab_secrets.sh"
  lab_secrets::ensure "kind-${AGENTIC_NETOPS_CLUSTER_NAME:-agentic-netops}"
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

  # EVPN/SRv6 capability coverage (short-circuit on first FAILURE; a check
  # that cannot run exits 77 and is recorded as skip — never pass, never fail)
  local t rc
  for t in EVPN-Session-Established-MACIP EVPN-Session-Established-IMET EVPN-Session-Established-JSONRIB SRv6-Underlay H.Encaps.Red End End.DT46 SID-list Decapsulation Counters; do
    echo "[qualify] Running $t"
    set +e
    "${ROOT_DIR}/tests/integration/evpn_srv6_suite.sh" --run "$t" 2>&1 | tee -a "$REPORT_DIR/qualify.$t.out.log"
    rc=$?
    set -e
    if (( rc == 0 )); then
      record_result "$t" "pass"
    elif (( rc == 77 )); then
      record_result "$t" "skip"
    else
      record_result "$t" "fail"
      bail "EVPN/SRv6 capability '$t' failed; gating remaining tests"
    fi
  done

  # Required OpenConfig/SONiC YANG path qualification
  set +e
  "${ROOT_DIR}/tests/integration/yang_paths_suite.sh" --run YANG-Paths 2>&1 | tee -a "$REPORT_DIR/qualify.YANG-Paths.out.log"
  rc=$?
  set -e
  if (( rc == 0 )); then
    record_result "YANG-Paths" "pass"
  elif (( rc == 77 )); then
    record_result "YANG-Paths" "skip"
  else
    record_result "YANG-Paths" "fail"
    bail "YANG path qualification failed"
  fi

  # Write machine-readable report and success log
  emit_report
  echo "[qualify] OK" | tee -a "$REPORT_DIR/qualify.run.log"
}

# T600: report the path qualify writes its machine-readable report to, so
# downstream derivation (scripts/lib/capability.sh) never hardcodes a literal.
if [[ ${1:-} == "--print-report-path" ]]; then
  echo "${REPORT_DIR}/qualify.report.json"
  exit 0
fi

main "$@"
