#!/usr/bin/env bash
# Lab qualification harness: run capability tests and gate downstream (FR-005)
set -euo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
REPORT_DIR="${ROOT_DIR}/.wiggum/features/001-agentic-netops-srlinux-evpn-fabric/gates/proofs"
mkdir -p "$REPORT_DIR"

# Accumulators for the machine-readable report (visible to helpers)
ALL_TESTS=()
ALL_STATUSES=()
ALL_REASONS=()
FAILED=0

# SRv6 is not a capability of this platform. It is recorded as not-applicable
# with a written reason on every run — never as `pass`, and never quietly
# dropped from the report (constitution II).
SRV6_NA_REASON="SR Linux 7220 container has no SRv6 data plane"
SRV6_ENTRIES=(SRv6-Underlay H.Encaps.Red End End.DT46 SID-list Decapsulation Counters)

run_test() {
  local name=$1
  echo "[qualify] Running $name" | tee -a "$REPORT_DIR/qualify.run.log"
  "${ROOT_DIR}/tests/integration/srlinux_gnmi_suite.sh" --run "$name" 2>&1 | tee -a "$REPORT_DIR/qualify.$name.out.log"
}

record_result() {
  local name=$1 status=$2 reason=${3:-}
  ALL_TESTS+=("$name")
  ALL_STATUSES+=("$status")
  ALL_REASONS+=("$reason")
  # not-applicable is a decided, documented outcome, not a failure and not a pass.
  if [[ "$status" != "pass" && "$status" != "not-applicable" ]]; then FAILED=1; fi
}

emit_report() {
  {
    echo '{"tests":['
    local sep=""; local i
    for ((i=0; i<${#ALL_TESTS[@]}; i++)); do
      if [[ -n "${ALL_REASONS[$i]}" ]]; then
        printf '%s{"name":"%s","status":"%s","reason":"%s"}' \
          "$sep" "${ALL_TESTS[$i]}" "${ALL_STATUSES[$i]}" "${ALL_REASONS[$i]}"
      else
        printf '%s{"name":"%s","status":"%s"}' "$sep" "${ALL_TESTS[$i]}" "${ALL_STATUSES[$i]}"
      fi
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

record_srv6_not_applicable() {
  local t
  for t in "${SRV6_ENTRIES[@]}"; do
    record_result "$t" "not-applicable" "$SRV6_NA_REASON"
    echo "[qualify] $t: not-applicable — $SRV6_NA_REASON" | tee -a "$REPORT_DIR/qualify.run.log"
  done
}

main() {
  local core_failed=0
  # Materialize lab credentials/TLS locally before any gNMI capability test
  # shellcheck source=lab_secrets.sh
  source "${ROOT_DIR}/scripts/lib/lab_secrets.sh"
  lab_secrets::ensure "kind-${AGENTIC_NETOPS_CLUSTER_NAME:-agentic-netops}"

  # gNMI core tests (run all in this block, then gate downstream on any failure)
  for t in Capabilities Get Set Subscribe; do
    if run_test "$t"; then
      record_result "$t" "pass"
    else
      record_result "$t" "fail"
      core_failed=1
    fi
  done
  if (( core_failed != 0 )); then
    record_srv6_not_applicable
    bail "core capability failure; not running persistence, EVPN or YANG path suites"
  fi

  # Persistence: write a witness over gNMI, save, restart every node, re-read.
  echo "[qualify] Running persistence (gNMI witness across a container restart)"
  if "${ROOT_DIR}/scripts/lib/persistence.sh" --run 2>&1 | tee -a "$REPORT_DIR/qualify.persistent.out.log"; then
    record_result "persistent" "pass"
  else
    record_result "persistent" "fail"
    record_srv6_not_applicable
    bail "persistence check failed; not running EVPN or YANG path suites"
  fi

  # EVPN capability coverage (short-circuit on first failure)
  for t in EVPN-Type2 EVPN-Type3 EVPN-Type5 Remote-VTEP Overlay-Traffic; do
    echo "[qualify] Running $t"
    if "${ROOT_DIR}/tests/integration/evpn_suite.sh" --run "$t" 2>&1 | tee -a "$REPORT_DIR/qualify.$t.out.log"; then
      record_result "$t" "pass"
    else
      record_result "$t" "fail"
      record_srv6_not_applicable
      bail "EVPN capability '$t' failed; gating remaining tests"
    fi
  done

  # Required SR Linux YANG path qualification
  if "${ROOT_DIR}/tests/integration/yang_paths_suite.sh" --run YANG-Paths 2>&1 | tee -a "$REPORT_DIR/qualify.YANG-Paths.out.log"; then
    record_result "YANG-Paths" "pass"
  else
    record_result "YANG-Paths" "fail"
    record_srv6_not_applicable
    bail "YANG path qualification failed"
  fi

  # SRv6: declared absent with a reason, on every run, pass or fail.
  record_srv6_not_applicable

  # Write machine-readable report and success log
  emit_report
  echo "[qualify] OK" | tee -a "$REPORT_DIR/qualify.run.log"
}

main "$@"
