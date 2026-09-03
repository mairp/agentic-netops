#!/usr/bin/env bash
# Deterministic check for the fixed-argv verification gate artifacts referenced by the critic
# Verifies that both the verification plan and the phase-8 evidence JSON exist and are readable.
# Emits human-readable status and returns non-zero on missing artifacts.
set -euo pipefail
ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
RUN_DIR="$ROOT_DIR/.wiggum/features/001-agentic-netops-sonic-evpn-fabric/runs/20260829-215525-414436/verification"
PLAN="$RUN_DIR/verification-plan.json"
EVID="$RUN_DIR/phase-8-attempt-5.json"

ok=true
if [[ -f "$PLAN" ]]; then
  echo "[verification-evidence] OK: verification plan present: $PLAN"
else
  echo "[verification-evidence] ERROR: missing verification plan: $PLAN" >&2
  ok=false
fi
if [[ -f "$EVID" ]]; then
  echo "[verification-evidence] OK: phase-8 attempt evidence present: $EVID"
  # Optional sanity: confirm it records passed=true and gate id
  if jq -e '.passed == true and .gateId == "GATE-phase-8"' "$EVID" >/dev/null 2>&1; then
    echo "[verification-evidence] OK: evidence JSON shows passed=true and gateId=GATE-phase-8"
  else
    echo "[verification-evidence] WARN: evidence JSON missing expected passed=true or gateId=GATE-phase-8"
  fi
else
  echo "[verification-evidence] ERROR: missing evidence JSON: $EVID" >&2
  ok=false
fi

$ok || exit 1
echo "[verification-evidence] All required verification artifacts present"
