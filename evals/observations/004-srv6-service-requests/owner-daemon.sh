#!/usr/bin/env bash
# Owner daemon for the 004 MoL run (mol004-owner-daemon.service, enabled, survives reboots and the
# loss of any interactive Claude session). Replaces standin.sh (O-61, O-63, O-65).
#
#   owner-daemon.sh run                 the daemon loop (systemd ExecStart)
#   owner-daemon.sh relaunch "<reason>" relaunch the orchestrator in the next free unit (also used by
#                                       the agent cycle)
#
# Each tick: exit when REPORT.md exists; relaunch a dead orchestrator by itself only for the resumable
# ends (killed by a reboot/crash, rc=4, or a clean rc=6 nobody holds), within a budget; keep watch.py
# running; and on every wake (watch.py's wake-pending, or a dead run it may not relaunch) run ONE owner
# cycle with headless Claude Code (owner-daemon-task.md), falling back to dsh glm-5.3-flash.
set -u
HERE=/root/agentic-netops/evals/observations/004-srv6-service-requests
REPO=/root/agentic-netops
M=$REPO/.mixture-of-loops/004-srv6-service-requests
RESUME_LOG=$M/owner-resume-20261014.log
RELAUNCH_DIR=/root/.cache/mol004-relaunch
PROGRESS=$REPO/.wiggum/features/004-srv6-service-requests/PROGRESS.md
STATE=/root/.cache/mol004-owner-daemon
LOG=$HERE/owner-daemon.log
TICK=${TICK:-60}
RC6_GRACE=${RC6_GRACE:-900}            # a clean stop may be an owner amending tasks: give them 15 min
RELAUNCH_MAX=${RELAUNCH_MAX:-3}        # automatic relaunches per RELAUNCH_WINDOW before asking the agent
RELAUNCH_WINDOW=${RELAUNCH_WINDOW:-21600}
CYCLE_TIMEOUT=${CYCLE_TIMEOUT:-3000}
export HOME=/root PATH=/root/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
mkdir -p "$STATE"

say() { echo "$(date '+%F %T') $*" >> "$LOG"; }
alert() { say "ALERT: $*"; logger -t mol004-owner-daemon -p user.warning "$*"; }
orch_alive() { pgrep -f 'specstride/[o]rchestrator.sh .*--feature 004-srv6-service-requests' >/dev/null; }
run_done() { grep -aq '# DONE — all 11 phase(s) approved' "$REPO/.wiggum/run.log" 2>/dev/null; }

# How the last direct-resume run ended: "killed" (a start with no exit line: reboot/crash/kill -9),
# "rc=N <epoch>", or "none".
last_end() {
  local last
  last=$(grep -a -E '^\[OWNER-RESUME(-EXIT)?\] ' "$RESUME_LOG" 2>/dev/null | tail -1)
  case "$last" in
    "[OWNER-RESUME-EXIT]"*) echo "rc=${last##*rc=} $(date -d "$(awk '{print $2}' <<<"$last")" +%s)";;
    "[OWNER-RESUME]"*) echo "killed";;
    *) echo "none";;
  esac
}

next_unit() {
  local n
  for n in $(seq 8 99); do
    [[ $(systemctl show -p LoadState --value "mol004-direct-resume$n") == not-found ]] && { echo "mol004-direct-resume$n"; return; }
  done
  return 1
}

relaunch() {
  local reason=$1 unit
  if orch_alive; then say "relaunch refused: an orchestrator is alive"; return 1; fi
  unit=$(next_unit) || { alert "no free mol004-direct-resume unit name"; return 1; }
  {
    echo
    echo "===== $(date '+%F %H:%M') — OWNER (daemon) — run relaunched in $unit ====="
    echo "1. Why: $reason"
    echo "2. Same argv and environment as before ($RELAUNCH_DIR). Nothing else in your tree changed by this relaunch."
    echo "3. If the lab is down (e.g. after a host reboot), health-check exits 1 for that reason, not because of"
    echo "   your work: restore it through a yield with \"requires_healthy_infra\": false, and confirm health-check"
    echo "   exits 0 before recording any live receipt."
  } >> "$PROGRESS"
  systemd-run --unit "$unit" --collect -p KillMode=process \
    -p StandardOutput=append:"$RESUME_LOG" -p StandardError=append:"$RESUME_LOG" \
    "$HERE/direct-resume.sh" "$RELAUNCH_DIR/orch.environ" "$RELAUNCH_DIR/orch.cmdline" >> "$LOG" 2>&1
  local rc=$?
  date +%s >> "$STATE/relaunches"
  say "relaunch in $unit rc=$rc — $reason"
  return $rc
}

relaunch_budget_left() {
  local now cut n
  now=$(date +%s); cut=$((now - RELAUNCH_WINDOW))
  n=$(awk -v c="$cut" '$1 >= c' "$STATE/relaunches" 2>/dev/null | wc -l)
  (( n < RELAUNCH_MAX ))
}

ensure_watcher() {
  [[ -f $HERE/wake-pending ]] && return
  pgrep -f "$HERE/watch.py" >/dev/null && return
  setsid python3 "$HERE/watch.py" >> "$STATE/watch.out" 2>&1 < /dev/null 9>&- &   # 9>&-: never inherit the daemon lock
  say "watch.py started (pid $!)"
}

# One owner cycle. Claude Code first; dsh glm when Claude fails (quota, outage, timeout).
cycle() {
  local why=$1 out rc
  out=$STATE/cycle-$(date +%Y%m%d-%H%M%S).out
  say "cycle start — $why"
  ( exec 9>&-; cd "$REPO" && timeout "$CYCLE_TIMEOUT" claude -p --dangerously-skip-permissions --model opus \
      --output-format text "$(cat "$HERE/owner-daemon-task.md")

## Wake reason (from the daemon, $(date -Is))
$why" ) > "$out" 2>&1 < /dev/null
  rc=$?
  if (( rc != 0 )) || ! grep -q '^STATE:' "$out"; then
    say "claude cycle failed rc=$rc ($(tail -c 300 "$out" | tr '\n' ' ')) — falling back to dsh glm-5.3-flash"
    ( exec 9>&-; cd "$REPO" && { [[ -d /root/.cache/mol004-standin/dsh-home ]] && export DSH_HOME=/root/.cache/mol004-standin/dsh-home; }  # glm-5.3-flash pin from standin.sh
      DSH_PERMISSION_MODE=danger-full-access timeout "$CYCLE_TIMEOUT" \
        dsh --profile headless "$(cat "$HERE/owner-daemon-task.md")

You are running on the fallback model. When unsure whether an intervention is warranted, do not
intervene: record what you saw in OBSERVATIONS.md for the next Claude cycle.

## Wake reason (from the daemon, $(date -Is))
$why" ) >> "$out" 2>&1 < /dev/null
    rc=$?
  fi
  grep -E '^(STATE|ALARMS|DID):' "$out" | tail -3 | sed 's/^/    /' >> "$LOG"
  say "cycle end rc=$rc (transcript $out)"
  if (( rc != 0 )) || ! grep -q '^STATE:' "$out"; then
    echo $(( $(cat "$STATE/fails" 2>/dev/null || echo 0) + 1 )) > "$STATE/fails"
    alert "owner cycle failed ($(cat "$STATE/fails") in a row) — wake: $why"
    return 1
  fi
  echo 0 > "$STATE/fails"
}

daemon() {
  exec 9> "$STATE/daemon.lock"
  flock -n 9 || { echo "another owner daemon holds the lock"; exit 0; }
  say "owner daemon started (pid $$, boot $(uptime -s))"
  local dead_since="" last_dead_wake=0
  while true; do
    if [[ -f $HERE/REPORT.md ]]; then say "REPORT.md exists — watch is over, exiting"; exit 0; fi

    if orch_alive || run_done; then
      dead_since=""
    else
      dead_since=${dead_since:-$(date +%s)}
      local end now; end=$(last_end); now=$(date +%s)
      local auto="" why=""
      case "$end" in
        killed) auto="the previous run died without an exit line (host reboot, crash or kill -9) — boot $(uptime -s)";;
        "rc=4 "*) auto="the run halted resumably (rc=4: yield budget or deadline)";;
        "rc=6 "*) if [[ ! -f $HERE/owner-hold ]] && (( now - ${end##* } > RC6_GRACE )); then
                    auto="the run was stopped cleanly (rc=6) more than $((RC6_GRACE/60)) min ago and no owner-hold is set"
                  fi;;
        *) why="the orchestrator is not running and its last end was '$end', which the daemon does not relaunch by itself";;
      esac
      if [[ -f $HERE/owner-hold ]]; then
        auto=""; why=""          # an owner is deliberately holding the run
      elif [[ -n $auto ]] && ! relaunch_budget_left; then
        why="auto-relaunch budget exhausted ($RELAUNCH_MAX in $((RELAUNCH_WINDOW/3600)) h); last end '$end'. Find out why the run keeps ending."
        auto=""
      fi
      if [[ -n $auto ]] && (( now - dead_since >= 120 )); then
        relaunch "$auto" && dead_since=""
      elif [[ -n $why ]] && (( now - last_dead_wake > 3600 )); then
        last_dead_wake=$now
        cycle "LOOP DEAD: $why"
      fi
    fi

    if [[ -f $HERE/wake-pending ]]; then
      local w; w=$(cat "$HERE/wake-pending")
      cycle "watch.py wake: $w"
      cat "$HERE/wake-pending" >> "$STATE/wakes-handled.log" 2>/dev/null
      rm -f "$HERE/wake-pending"
    fi
    ensure_watcher
    sleep "$TICK"
  done
}

case "${1:-run}" in
  run) daemon;;
  relaunch) relaunch "${2:?reason}";;
  *) echo "usage: $0 run | relaunch <reason>" >&2; exit 2;;
esac
