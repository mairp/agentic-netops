#!/usr/bin/env bash
set -Eeuo pipefail

WORKDIR=${1:-/root/agentic-netops}
INTERVAL=${INTERVAL:-15}
LOGDIR="$WORKDIR/logs"
MONLOG="$LOGDIR/wiggum-monitor.log"
METRICS="$LOGDIR/wiggum-metrics.jsonl"
ALERTS="$LOGDIR/wiggum-alerts.log"
EVENTS_LINK="$WORKDIR/.wiggum/events.jsonl"
RUNLOG_LINK="$WORKDIR/.wiggum/run.log"
FEATURE=$(grep -E '^feature=' "$WORKDIR/.wiggum/last-run.conf" 2>/dev/null | sed 's/^feature=//')

mkdir -p "$LOGDIR"
: >"$MONLOG"
: >"$METRICS"
: >"$ALERTS"

ts() { date -Iseconds; }

log() { echo "$(ts) $*" | tee -a "$MONLOG" >/dev/null; }
metric() {
  # Usage: metric key=value ...
  local kv; kv=$(printf '%s ' "$@");
  echo "$(ts) feature=${FEATURE:-unknown} ${kv}" >>"$METRICS"
}
alert() { echo "$(ts) ALERT $*" | tee -a "$ALERTS" "$MONLOG" >/dev/null; }

log "Starting Wiggum monitor: workdir=$WORKDIR feature=${FEATURE:-unknown} interval=${INTERVAL}s"

# Watch events.jsonl for anomalies
watch_events() {
  if [[ ! -e "$EVENTS_LINK" ]]; then
    log "events file not present yet: $EVENTS_LINK (will wait)"
    # wait until it appears
    while [[ ! -e "$EVENTS_LINK" ]]; do sleep 2; done
  fi
  log "Following events: $EVENTS_LINK"
  # Tail new lines and classify
  tail -Fn0 "$EVENTS_LINK" | while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    echo "$line" >>"$MONLOG"
    # Basic anomaly detection
    if echo "$line" | grep -Eqi '\b(error|fatal|panic|exception|traceback|failed)\b'; then
      alert "event_error: $line"
    fi
    if echo "$line" | grep -Eqi '\b(verdict).*result=REJECTED\b'; then
      alert "critic_rejected: $line"
    fi
    if echo "$line" | grep -Eqi '\b(halt|stopped|aborted)\b'; then
      alert "loop_stopped: $line"
    fi
    # Record as metric
sanitized=${line//\"/\\\"}
    metric event="$sanitized"
  done
}

# Periodic process sampler
sample_procs() {
  while true; do
    # ps can emit multiple lines; summarize CPU/mem for wiggum-related processes
    local pids cpu mem count
    pids=$(pgrep -f -d, -a '(/root/wiggum/wiggum|orchestrator.sh|proposer.sh|critic.py)' || true)
    count=$(printf "%s" "$pids" | grep -c . || true)
    cpu=$(ps -C bash,python3 -o %cpu= --ppid $(pgrep -f '(/root/wiggum/wiggum|orchestrator.sh|proposer.sh|critic.py)' 2>/dev/null | tr '\n' ' ') 2>/dev/null | awk '{s+=$1} END{printf "%.1f", s}' || echo 0)
    mem=$(ps -C bash,python3 -o %mem= --ppid $(pgrep -f '(/root/wiggum/wiggum|orchestrator.sh|proposer.sh|critic.py)' 2>/dev/null | tr '\n' ' ') 2>/dev/null | awk '{s+=$1} END{printf "%.1f", s}' || echo 0)
    metric procs=$count cpu=$cpu mem=$mem
    sleep "$INTERVAL"
  done
}

# Periodic gates snapshot
sample_gates() {
  local gates_dir="$WORKDIR/.wiggum/features/${FEATURE:-}/gates"
  while true; do
    if [[ -d "$gates_dir" ]]; then
      local newest mtime files
      files=$(ls -1 "$gates_dir" 2>/dev/null | wc -l || echo 0)
      newest=$(ls -1t "$gates_dir" 2>/dev/null | head -n1 || true)
      if [[ -n "$newest" ]]; then
        mtime=$(stat -c '%Y' "$gates_dir/$newest" 2>/dev/null || echo 0)
      else
        mtime=0
      fi
      metric gates_files=$files gates_latest="$newest" gates_latest_mtime=$mtime
    fi
    sleep "$INTERVAL"
  done
}

watch_events &
EVENTS_PID=$!
sample_procs &
PROCS_PID=$!
sample_gates &
GATES_PID=$!

log "Monitor running: events_pid=$EVENTS_PID procs_pid=$PROCS_PID gates_pid=$GATES_PID"

# Wait forever; clean up on exit
trap 'log "Stopping monitor"; kill -9 $EVENTS_PID $PROCS_PID $GATES_PID 2>/dev/null || true' EXIT
wait
