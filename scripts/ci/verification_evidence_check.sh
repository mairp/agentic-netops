#!/usr/bin/env bash
# Deterministic check for the fixed-argv verification gate artifacts referenced by the critic
# Verifies that both the verification plan and the latest phase evidence JSON exist and are readable.
# Emits human-readable status and returns non-zero on missing artifacts.
set -euo pipefail
ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
FEATURE_DIR="$ROOT_DIR/.wiggum/features/001-agentic-netops-srlinux-evpn-fabric"
# The run id is not knowable ahead of time, so resolve the most recent run that
# actually carries verification artifacts rather than pinning a literal that
# belonged to the previous feature's run history. Overridable for a specific run.
RUN_DIR="${WIGGUM_RUN_DIR:-$(ls -1d "$FEATURE_DIR"/runs/*/verification 2>/dev/null | sort | tail -n1)}"
if [[ -z "${RUN_DIR:-}" ]]; then
  echo "[verification-evidence] ERROR: no run with verification artifacts under $FEATURE_DIR/runs/" >&2
  exit 1
fi
PLAN="$RUN_DIR/verification-plan.json"
EVID=$(ls -1 "$RUN_DIR"/phase-*-attempt-*.json 2>/dev/null | sort | tail -n1)
EVID="${EVID:-$RUN_DIR/phase-attempt.json}"

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
  if jq -e '.passed == true and (.gateId | startswith("GATE-phase-"))' "$EVID" >/dev/null 2>&1; then
    echo "[verification-evidence] OK: evidence JSON shows passed=true for $(jq -r .gateId "$EVID")"
  else
    echo "[verification-evidence] WARN: evidence JSON missing expected passed=true or a GATE-phase-* gateId"
  fi
else
  echo "[verification-evidence] ERROR: missing evidence JSON: $EVID" >&2
  ok=false
fi

$ok || exit 1
echo "[verification-evidence] All required verification artifacts present"
