#!/usr/bin/env bash
# Stand-in owner for the 004 MoL watch. While the primary owner (a Claude Code
# session) answers its wakes (deletes `wake-pending`) and keeps watch.py running, this
# does nothing. When a wake has gone unanswered or no watcher has run for
# STALE_SEC (the primary is out of quota or gone), it runs one
# watch cycle of evals/prompts/observe-mol-vs-infra.md on dsh headless with
# glm-5.3-flash, every CYCLE_SEC, until the primary answers again or the
# final REPORT.md exists.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO=/root/agentic-netops
STALE_SEC=${STALE_SEC:-2400}
CYCLE_SEC=${CYCLE_SEC:-1200}
IDLE_SEC=${IDLE_SEC:-300}
PROVIDER=zai MODEL=glm-5.3-flash
LOG="$HERE/standin.log"
say() { echo "$(date '+%F %T') $*" >> "$LOG"; }

# Model pin without touching the host's dsh settings: a private DSH_HOME that
# symlinks the real one except settings.yaml (recipe from specstride-batch).
REAL_HOME="${DSH_HOME:-$HOME/.dsh}"
OVERLAY=/root/.cache/mol004-standin/dsh-home
mkdir -p "$OVERLAY"
for entry in "$REAL_HOME"/* "$REAL_HOME"/.[!.]*; do
  [[ -e "$entry" ]] || continue
  base="${entry##*/}"; [[ "$base" == settings.yaml ]] && continue
  ln -sfn "$entry" "$OVERLAY/$base"
done
{ printf 'agent-default-model:\n  provider: %s\n  model: %s\n' "$PROVIDER" "$MODEL"
  awk '/^agent-default-model:/ { skip=1; next }
       skip && /^[[:space:]]*$/ { next }
       skip && /^[[:space:]]/   { next }
       { skip=0; print }' "$REAL_HOME/settings.yaml"; } > "$OVERLAY/settings.yaml"

TASK="You are the stand-in owner of a running autonomous loop; the primary owner is temporarily unavailable. Read /root/agentic-netops/evals/prompts/observe-mol-vs-infra.md completely, then perform exactly ONE watch cycle as its section 5 describes, obeying section 4 strictly. Before deciding anything, read the last OWNER entry and any later OWNER-REPORT in /root/agentic-netops/.wiggum/features/004-srv6-service-requests/PROGRESS.md and the last 5 entries of /root/agentic-netops/evals/observations/004-srv6-service-requests/OBSERVATIONS.md so you continue the primary owner's direction instead of starting a new one. Every fact you write must come from a command you actually ran or a file you actually read in this cycle; never write a command's output from expectation. Do NOT delete the wake-pending file and do not start watch.py (both belong to the primary owner); read wake-pending if it exists, it says why the primary was called. Sign everything you write 'by stand-in glm-5.3-flash'. When unsure whether an intervention is warranted, do not intervene: record what you saw in OBSERVATIONS.md and leave the decision to the primary owner. End with a three-line summary: state of the run, alarms, what you did."

say "stand-in daemon started (stale=${STALE_SEC}s cycle=${CYCLE_SEC}s model=$PROVIDER/$MODEL)"
active=0
while true; do
  [[ -f "$HERE/REPORT.md" ]] && { say "REPORT.md exists — watch is over, exiting"; exit 0; }
  # The primary owner is "away" when a wake it was sent has gone unanswered, or
  # when no watcher is running at all (it restarts the watcher on every wake).
  now=$(date +%s); age=0
  if [[ -f "$HERE/wake-pending" ]]; then age=$(( now - $(stat -c %Y "$HERE/wake-pending") )); fi
  if ! pgrep -f "$HERE/watch.py" >/dev/null; then
    nw=$(( now - $(stat -c %Y "$HERE/timeline.jsonl" 2>/dev/null || echo "$now") )); (( nw > age )) && age=$nw
  fi
  if (( age < STALE_SEC )); then
    (( active )) && say "primary owner is back — standing down"
    active=0; sleep "$IDLE_SEC"; continue
  fi
  (( active )) || say "primary owner silent for ${age}s — taking the watch"
  active=1
  say "cycle start"
  ( cd "$REPO" && DSH_HOME="$OVERLAY" DSH_PERMISSION_MODE=danger-full-access \
      timeout 1500 dsh --profile headless "$TASK" ) >> "$LOG" 2>&1
  say "cycle end rc=$?"
  sleep "$CYCLE_SEC"
done
