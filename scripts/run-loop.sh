#!/usr/bin/env bash
# run-loop.sh — resume the wiggum proposer/critic loop for this feature.
#   ./scripts/run-loop.sh          resume with live timeline + telemetry
#   ./scripts/run-loop.sh --quiet  resume without the live view
#   ./scripts/run-loop.sh --stop   stop a running loop cleanly
set -euo pipefail

WORKDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FEATURE="001-ainetops-sonic-evpn-fabric"
SPEC="$WORKDIR/specs/$FEATURE/tasks.md"
ORCH="${ORCH:-/root/wiggum/orchestrator.sh}"

if [[ "${1:-}" == "--stop" ]]; then
  touch "$WORKDIR/.wiggum/stop.flag"
  echo "stop flag set — the loop halts at its next checkpoint (exit 6 is a clean stop)"
  exit 0
fi

[[ -x "$ORCH" ]] || { echo "orchestrator not found: $ORCH" >&2; exit 1; }
[[ -f "$SPEC" ]]  || { echo "spec not found: $SPEC" >&2; exit 1; }

# A leftover stop flag makes the loop exit 6 immediately.
rm -f "$WORKDIR/.wiggum/stop.flag"

LIVE=(--live --debug)
[[ "${1:-}" == "--quiet" ]] && LIVE=(--no-live)

exec "$ORCH" \
  -w "$WORKDIR" \
  -s "$SPEC" \
  --spec-format speckit-tasks \
  --feature "$FEATURE" \
  --verification plan \
  "${LIVE[@]}" \
  --telemetry --loki-url http://127.0.0.1:3100 \
  --otel --otel-url http://127.0.0.1:4318
