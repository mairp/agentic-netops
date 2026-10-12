#!/usr/bin/env bash
# Proof q10-baseline (plan 1-08): replay every corpus phrasing against
# baseline_snapshot.json — `cd agents && pytest tests/unit/test_phrasings_baseline.py`.
#
# The verification gate declares this proof by SCRIPT PATH and execs it as
# `/usr/bin/bash scripts/proofs/run-q10-baseline.sh`. The command must not be
# wrapped in `bash -c`: the gate already runs bash, so a nested `bash -c`
# string is executed as `bash -c <script-file>` and dies with exit 126
# ("cannot execute binary file") before pytest starts (gate CMD-1fed03d3…).
#
# The venv is sourced here so the proof is self-contained: agents/.venv carries
# the a2a package and the plugin set the recorded output expects.
#
# No telemetry knob is needed here: these unit tests never initialize the
# telemetry stack (agents/config/telemetry.py init_telemetry is not on their
# path), so no OTLP exporter thread ever exists and the captured output has
# no exporter bytes to go nondeterministic. Test outcomes are unchanged.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
VENV_ACTIVATE="$REPO_ROOT/agents/.venv/bin/activate"
[[ -f "$VENV_ACTIVATE" ]] || { echo "run-q10-baseline.sh: missing $VENV_ACTIVATE" >&2; exit 3; }
# shellcheck source=/dev/null
source "$VENV_ACTIVATE"
cd "$REPO_ROOT/agents"
exec pytest tests/unit/test_phrasings_baseline.py
