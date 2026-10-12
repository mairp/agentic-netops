#!/usr/bin/env bash
# Proof q10-srv6 (plan 1-08): the interim SRv6 phrasings must yield the R1
# refusal — `cd agents && pytest tests/unit/test_phrasings_srv6.py`.
#
# Declared to the verification gate by SCRIPT PATH (exec'd as
# `/usr/bin/bash scripts/proofs/run-q10-srv6.sh`), never wrapped in `bash -c`:
# the gate already runs bash, and a nested `bash -c` string is executed as
# `bash -c <script-file>` → exit 126 ("cannot execute binary file").
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
[[ -f "$VENV_ACTIVATE" ]] || { echo "run-q10-srv6.sh: missing $VENV_ACTIVATE" >&2; exit 3; }
# shellcheck source=/dev/null
source "$VENV_ACTIVATE"
cd "$REPO_ROOT/agents"
exec pytest tests/unit/test_phrasings_srv6.py
