#!/usr/bin/env bash
# tier-proof.sh — intent-tier lifecycle proofs (T192-T218).
#
#   tier-proof.sh provision <manifest.yaml>
#   tier-proof.sh update   <manifest.yaml>   # manifest is the UPDATED intent
#   tier-proof.sh delete   <manifest.yaml>   # deletes by the manifest's name
#
# apply/wait/read-only device truth; never mutates the device directly.
# Exit 0 = the lifecycle step completed; the printed sections carry the verdict.
set -euo pipefail
REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
KCTX="kind-${KIND_CLUSTER:-agentic-netops}"
NS=agentic-netops-intent
MODE=$1
MANIFEST=$2

name() { python3 -c 'import sys,yaml; print(yaml.safe_load(open(sys.argv[1]))["metadata"]["name"])' "$MANIFEST"; }
NAME=$(name "$MANIFEST")

gen() { kubectl --context "$KCTX" -n "$NS" get network "$NAME" -o jsonpath='{.metadata.generation}' 2>/dev/null; }

cond() { # Ready condition reason+message as one line
  kubectl --context "$KCTX" -n "$NS" get network "$NAME" -o json 2>/dev/null | python3 -c '
import json,sys
try: d=json.load(sys.stdin)
except Exception: print("absent"); raise SystemExit
cs=d.get("status",{}).get("conditions",[])
ready=[c for c in cs if c.get("type")=="Ready"]
if not ready: print("no Ready condition yet"); raise SystemExit
c=ready[-1]
msg=(c.get("message") or "")[:200]
obs=d.get("status",{}).get("observedGeneration")
gen=d.get("metadata",{}).get("generation")
print(c.get("status"), "reason="+str(c.get("reason")), "obs="+str(obs), "gen="+str(gen), "msg="+msg)' | tr -d '"'
}

wait_ready() { # $1 = expect True|False, $2 = seconds
  local expect=$1 limit=$2 i=0 state
  while (( i < limit )); do
    state=$(cond)
    case "$state" in
      # Ready=True only counts when the controller has OBSERVED the current
      # generation — a stale True from the previous generation must not pass
      # (observed live: the p4-svc-acl update converged a full work-queue
      # turn after the old condition still read True).
      True*) [[ "$expect" == True && "$state" == *"obs=$(gen)"* ]] && { echo "Ready condition: $state"; return 0; };;
      False*) [[ "$expect" == False ]] && { echo "Ready condition: $state"; return 0; };;
    esac
    sleep 2; i=$((i+2))
  done
  echo "TIMEOUT waiting for Ready=$expect (last: $(cond))"; return 1
}

case "$MODE" in
  provision|update)
    echo "== manifest ($MODE): $MANIFEST"
    cat "$MANIFEST"
    echo "== kubectl apply"
    kubectl --context "$KCTX" apply -f "$MANIFEST"
    echo "== waiting for Ready=True (≤150s)"
    wait_ready True 150
    echo "== final status"
    kubectl --context "$KCTX" -n "$NS" get network "$NAME" -o json | python3 -c '
import json,sys
d=json.load(sys.stdin)
print("name:", d["metadata"]["name"], "generation:", d["metadata"].get("generation"))
for c in d.get("status",{}).get("conditions",[]): print("condition:", c.get("type"), c.get("status"), c.get("reason"), "|", (c.get("message") or "")[:220])
print("observedGeneration:", d.get("status",{}).get("observedGeneration"))'
    ;;
  delete)
    echo "== delete $NAME (finalizer rollback runs first)"
    kubectl --context "$KCTX" -n "$NS" delete network "$NAME" --timeout=150s
    echo "== object gone: $(kubectl --context "$KCTX" -n "$NS" get network "$NAME" 2>&1 | head -1)"
    ;;
  *)
    echo "usage: tier-proof.sh <provision|update|delete> <manifest>" >&2; exit 2;;
esac
