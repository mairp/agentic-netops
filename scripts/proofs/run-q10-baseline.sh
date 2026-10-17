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
# Two deterministic-output pins, both needed for byte-replay (FR-039):
#
# 1. COLUMNS: pytest pads every "=" banner line (session header, progress
#    dots, the summary) to the detected terminal width, and the detected
#    width itself has been observed to flip between runs of the same command
#    in this environment (80 vs 100), so the width is pinned explicitly.
#
# 2. Banner normalization (awk): the summary line is "==== <title> ===="
#    where <title> includes the duration ("5 passed in 9.78s"). proof.sh's
#    renderer rewrites "in N.Ns" to the variable-length "in ELAPSED" (+2
#    chars for a 5-char duration, +1 for a 6-char one), so suites whose
#    duration crosses a digit-count boundary byte-flapped on the pad width.
#    The awk below rewrites every "=" banner to EXACTLY 100 chars: it
#    substitutes the duration with the fixed token "in ELAPSED", then pads
#    or chops the trailing "=" run to the fixed width — the banner is
#    constant regardless of the detected width or the duration's length,
#    and proof.sh's renderer then finds no digits left to substitute.
#    pipefail keeps pytest's exit status (set -e turns it into the
#    runner's).
#
# The trailing-blank sed is unchanged: pytest intermittently emits one empty
# line after the summary (asyncio-plugin shutdown); the sed drops a trailing
# empty line before capture.
export COLUMNS=100
cd "$REPO_ROOT/agents"
pytest tests/unit/test_phrasings_baseline.py 2>&1 2>&1 | awk '
  # progress-dots line: the dots run and the right-aligned "[100%]" are
  # padded to the detected width, so squeeze the inter-run padding to one
  # space — the line becomes width-independent (the dots count is the test
  # count, which is fixed).
  /^[^ ]+ +[.sxFE ]+\[[ 0-9]+%\]$/ { gsub(/ +/, " "); print; next }
  /^=+[^=]*=+$/ {
    line = $0
    sub(/in [0-9]+\.[0-9]+s/, "in ELAPSED", line)
    while (length(line) < 100) line = line "="
    while (length(line) > 100) line = substr(line, 1, 100)
    print line
    next
  }
  { print }
' | sed -e '${/^$/d;}'
