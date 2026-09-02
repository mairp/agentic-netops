#!/usr/bin/env bash
# rotate-secrets.sh — Phase 10 drills T401–T403
# Rotate tier secrets and record independent read-back evidence (resourceVersion, pod UIDs).
# Usage:
#   deploy/agents/tests/probes/rotate-secrets.sh [kubectl-context] <llm-provider|clickhouse|slim>
# Exit 0 on success; writes a human-readable log to stdout.
set -euo pipefail
CTX="${1:-}"
TARGET="${2:-}"
NS=ainetops-agents
kc() { if [[ -n "$CTX" ]]; then kubectl --context "$CTX" "$@"; else kubectl "$@"; fi }
log() { echo "[rotate] $*"; }
rand() { head -c 12 /dev/urandom | base64 | tr -dc 'a-zA-Z0-9' | head -c 16; }

if [[ -z "${TARGET}" ]]; then
  echo "usage: $0 [context] <llm-provider|clickhouse|slim>" >&2; exit 2
fi

case "$TARGET" in
  llm-provider)
    SEC=llm-provider
    BEFORE=$(kc -n "$NS" get secret "$SEC" -o jsonpath='{.metadata.resourceVersion}')
    log "llm-provider before resourceVersion=$BEFORE"
    PATCH=$(cat <<EOF
{"metadata": {"annotations": {"ainetops.io/rotated-at": "$(date -u +%FT%TZ)"}},
 "stringData": {"OAUTH2_APPKEY": "$(rand)"}}
EOF
)
    kc -n "$NS" patch secret "$SEC" --type=merge -p "$PATCH" >/dev/null
    AFTER=$(kc -n "$NS" get secret "$SEC" -o jsonpath='{.metadata.resourceVersion}')
    log "llm-provider after resourceVersion=$AFTER"
    # Restart agents that consume the secret
    for d in supervisor mapper allocator deployer; do
      OLD=$(kc -n "$NS" get pods -l app=$d -o jsonpath='{.items[0].metadata.uid}' || true)
      kc -n "$NS" rollout restart deploy/$d || true
      kc -n "$NS" rollout status deploy/$d --timeout=120s || true
      NEW=$(kc -n "$NS" get pods -l app=$d -o jsonpath='{.items[0].metadata.uid}' || true)
      log "$d pod uid: $OLD -> $NEW"
    done
    ;;
  clickhouse)
    SEC=clickhouse-auth
    BEFORE=$(kc -n "$NS" get secret "$SEC" -o jsonpath='{.metadata.resourceVersion}')
    log "clickhouse-auth before resourceVersion=$BEFORE"
    PATCH=$(cat <<EOF
{"metadata": {"annotations": {"ainetops.io/rotated-at": "$(date -u +%FT%TZ)"}},
 "stringData": {"password": "$(rand)"}}
EOF
)
    kc -n "$NS" patch secret "$SEC" --type=merge -p "$PATCH" >/dev/null
    AFTER=$(kc -n "$NS" get secret "$SEC" -o jsonpath='{.metadata.resourceVersion}')
    log "clickhouse-auth after resourceVersion=$AFTER"
    # Restart ClickHouse StatefulSet
    OLD=$(kc -n "$NS" get pods -l app=clickhouse -o jsonpath='{.items[0].metadata.uid}' || true)
    kc -n "$NS" delete pod -l app=clickhouse --wait=true --timeout=120s || true
    kc -n "$NS" wait --for=condition=Ready pod -l app=clickhouse --timeout=180s || true
    NEW=$(kc -n "$NS" get pods -l app=clickhouse -o jsonpath='{.items[0].metadata.uid}' || true)
    log "clickhouse pod uid: $OLD -> $NEW"
    ;;
  slim)
    SEC=slim-gateway
    BEFORE=$(kc -n "$NS" get secret "$SEC" -o jsonpath='{.metadata.resourceVersion}')
    log "slim-gateway before resourceVersion=$BEFORE"
    PATCH=$(cat <<EOF
{"metadata": {"annotations": {"ainetops.io/rotated-at": "$(date -u +%FT%TZ)"}},
 "stringData": {"PASSWORD": "$(rand)"}}
EOF
)
    kc -n "$NS" patch secret "$SEC" --type=merge -p "$PATCH" >/dev/null
    AFTER=$(kc -n "$NS" get secret "$SEC" -o jsonpath='{.metadata.resourceVersion}')
    log "slim-gateway after resourceVersion=$AFTER"
    OLD=$(kc -n "$NS" get pods -l app=slim -o jsonpath='{.items[0].metadata.uid}' || true)
    kc -n "$NS" rollout restart deploy/slim || true
    kc -n "$NS" rollout status deploy/slim --timeout=120s || true
    NEW=$(kc -n "$NS" get pods -l app=slim -o jsonpath='{.items[0].metadata.uid}' || true)
    log "slim pod uid: $OLD -> $NEW"
    ;;
  *) echo "unknown target: $TARGET" >&2; exit 2 ;;
esac

# Effect-witness assertions
if [[ -n "${BEFORE:-}" && -n "${AFTER:-}" ]]; then
  if [[ "$BEFORE" == "$AFTER" ]]; then
    log "ERROR: resourceVersion did not change"; exit 1
  fi
fi
log "rotation complete"
