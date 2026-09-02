#!/usr/bin/env bash
# T130 — the intent-tier denial probe suite. Runs every denial probe:
#
#   rbac-denials.sh         T055/SC-005: every denial listed in
#                           contracts/kubernetes-objects.md for the two
#                           token-bearing identities (deployer, allocator).
#   mgmt-network-denial.sh  T056/NFR-007: a tier pod cannot reach the
#                           mgmt network (172.31.0.21:57400).
#   us2-denials.sh          US2/FR-016: the full identity set cannot
#                           express forbidden actions (no device session,
#                           no writes outside the deployer's scope) —
#                           structural denials, not behavioral ones.
#
# Each probe's output is captured under logs/ next to this script; the
# suite exit code is 0 iff every probe passed.
#
# Usage: deploy/agents/tests/probes/run-all.sh [kubectl-context]
# Exit:  0 = every probe passed; 1 = at least one probe failed.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CTX="${1:-}"
LOG_DIR="${LOG_DIR:-${HERE}/logs}"
mkdir -p "$LOG_DIR"

fail=0
pass=0

run_probe() {
  local name=$1
  local log="${LOG_DIR}/${name}.log"
  echo "== probe: ${name}"
  if "$HERE/${name}.sh" "$CTX" >"$log" 2>&1; then
    pass=$((pass + 1))
    echo "PASS  ${name}  (log: ${log})"
  else
    fail=$((fail + 1))
    echo "FAIL  ${name}  (log: ${log})"
    tail -5 "$log" | sed 's/^/      | /'
  fi
}

run_probe rbac-denials
run_probe mgmt-network-denial
run_probe us2-denials

echo
echo "run-all: ${pass} probes passed, ${fail} failed (logs: ${LOG_DIR})"
[[ "$fail" -eq 0 ]] || exit 1
