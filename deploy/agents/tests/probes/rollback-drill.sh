#!/usr/bin/env bash
# rollback-drill.sh — Phase 10 drills T404–T405 (roll-forward / rollback)
# Usage:
#   deploy/agents/tests/probes/rollback-drill.sh [kubectl-context] roll-forward <deployment> <image>
#   deploy/agents/tests/probes/rollback-drill.sh [kubectl-context] rollback    <deployment>
# Records independent effect (pod UID changes; rollout history).
set -euo pipefail
CTX="${1:-}"
ACTION="${2:-}"
DEPLOY="${3:-supervisor}"
IMAGE="${4:-}"
NS=agentic-netops-agents
kc() { if [[ -n "$CTX" ]]; then kubectl --context "$CTX" "$@"; else kubectl "$@"; fi }
log() { echo "[rollback] $*"; }

if [[ -z "$ACTION" ]]; then echo "usage: $0 [ctx] <roll-forward|rollback> [deployment] [image]" >&2; exit 2; fi

case "$ACTION" in
  roll-forward)
    [[ -n "$IMAGE" ]] || { echo "image required for roll-forward" >&2; exit 2; }
    OLD=$(kc -n "$NS" get pods -l app="$DEPLOY" -o jsonpath='{.items[0].metadata.uid}' || true)
    log "before UID: $OLD"
    kc -n "$NS" set image "deploy/$DEPLOY" "$DEPLOY=$IMAGE"
    kc -n "$NS" rollout status "deploy/$DEPLOY" --timeout=180s || true
    NEW=$(kc -n "$NS" get pods -l app="$DEPLOY" -o jsonpath='{.items[0].metadata.uid}' || true)
    IMG=$(kc -n "$NS" get deploy "$DEPLOY" -o jsonpath='{.spec.template.spec.containers[0].image}')
    log "after UID: $NEW image=$IMG"
    ;;
  rollback)
    OLD=$(kc -n "$NS" get pods -l app="$DEPLOY" -o jsonpath='{.items[0].metadata.uid}' || true)
    log "before UID: $OLD"
    kc -n "$NS" rollout undo "deploy/$DEPLOY" || true
    kc -n "$NS" rollout status "deploy/$DEPLOY" --timeout=180s || true
    NEW=$(kc -n "$NS" get pods -l app="$DEPLOY" -o jsonpath='{.items[0].metadata.uid}' || true)
    HIST=$(kc -n "$NS" rollout history "deploy/$DEPLOY" || true)
    log "after UID: $NEW\nrollout history:\n$HIST"
    ;;
  *) echo "unknown action: $ACTION" >&2; exit 2 ;;
esac

if [[ -n "${OLD:-}" && -n "${NEW:-}" && "$OLD" == "$NEW" ]]; then
  log "WARN: pod UID did not change — verify image or history"; exit 1
fi
log "drill complete"
