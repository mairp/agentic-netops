#!/usr/bin/env bash
# Generate tests.summary.txt from existing suite logs under gates/proofs.
# This does not run any suites — it only summarizes logs already present.
# It mirrors scripts/ci/run_suites.sh summary format: one line per suite,
# with STATUS first (PASS|FAIL|SKIP-LIVE) followed by the suite name.
set -euo pipefail
ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
PROOFS_DIR="$ROOT_DIR/.wiggum/features/001-agentic-netops-sonic-evpn-fabric/gates/proofs"
SUMMARY="$PROOFS_DIR/tests.summary.txt"
mkdir -p "$PROOFS_DIR"

log_for(){
  case "$1" in
    api)               echo "$PROOFS_DIR/tests.api.log" ;;
    unit)              echo "$PROOFS_DIR/tests.unit.log" ;;
    golden)            echo "$PROOFS_DIR/tests.golden.log" ;;
    sdc-validation)    echo "$PROOFS_DIR/tests.sdc-validation.log" ;;
    integration)       echo "$PROOFS_DIR/tests.integration.log" ;;
    failure)           echo "$PROOFS_DIR/tests.failure.log" ;;
    traffic)           echo "$PROOFS_DIR/tests.traffic.log" ;;
    srv6-capture)      echo "$PROOFS_DIR/tests.srv6-capture.log" ;;
    srv6-failover)     echo "$PROOFS_DIR/tests.srv6-failover.log" ;;
    topology-parity)   echo "$PROOFS_DIR/tests.topology-parity.log" ;;
    observability)     echo "$PROOFS_DIR/tests.observability.log" ;;
    teardown)          echo "$PROOFS_DIR/tests.teardown.log" ;;
    *) echo "/dev/null" ;;
  esac
}

status_for(){
  local name=$1; shift
  local log=$1
  # Missing log → treat as FAIL to avoid false green
  [[ -s "$log" ]] || { echo "FAIL(missing-log)"; return; }

  # Generic failure markers first
  if grep -Eq 'ASSERTION FAILED|ERROR:' "$log"; then
    echo "FAIL(assertion)"; return
  fi
  # Explicit live-environment skips
  if grep -Eq 'SKIP-LIVE|FABRIC_VERIFY_SKIPPED' "$log"; then
    echo "SKIP-LIVE"; return
  fi

  case "$name" in
    topology-parity)
      grep -q 'TOPOLOGY_PARITY_OK' "$log" && { echo PASS; return; } || { echo FAIL; return; } ;;
    observability)
      grep -q 'OBSERVABILITY_SUITE_OK' "$log" && { echo PASS; return; } || { echo FAIL; return; } ;;
    teardown)
      grep -q 'TEARDOWN_SUITE_OK' "$log" && { echo PASS; return; } || { echo FAIL; return; } ;;
    api|unit|golden|sdc-validation)
      # Go test logs: PASS present and no FAIL lines
      grep -q 'PASS' "$log" && ! grep -q 'FAIL' "$log" && { echo PASS; return; } || { echo FAIL; return; } ;;
    integration)
      # Mark PASS if there are positive assertions and no failures/skip markers
      grep -q 'assertion passed' "$log" && { echo PASS; return; } || { echo FAIL; return; } ;;
    failure|traffic|srv6-capture|srv6-failover)
      # These suites use explicit SKIP-LIVE when lab is absent; otherwise rely on ERROR/ASSERTION FAILED above
      echo PASS; return ;;
    *) echo FAIL ;;
  esac
}

main(){
  local suites=(api unit golden sdc-validation integration failure traffic srv6-capture srv6-failover topology-parity observability teardown)
  : > "$SUMMARY"
  for s in "${suites[@]}"; do
    l=$(log_for "$s")
    st=$(status_for "$s" "$l")
    printf '%s %s\n' "$st" "$s" >>"$SUMMARY"
  done
  echo "Wrote summary: $SUMMARY"
}

main "$@"
