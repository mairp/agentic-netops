#!/usr/bin/env bash
# Utility waits for resources readiness and counts (Phase 3)
set -euo pipefail
CTX="kind-${AGENTIC_NETOPS_CLUSTER_NAME:-agentic-netops}"
require(){ command -v "$1" >/dev/null 2>&1 || { echo "missing $1" >&2; exit 1; }; }
require kubectl

wait::crd(){ local name=$1; kubectl --context "$CTX" wait --for=condition=Established --timeout=180s crd/$name; }
wait::pods(){ local ns=$1 sel=$2; kubectl --context "$CTX" -n "$ns" wait --for=condition=Ready --timeout=300s pods -l "$sel"; }

case "${1:-}" in
  crd) shift; wait::crd "$@";;
  pods) shift; wait::pods "$@";;
  *) echo "usage: $0 {crd <name>|pods <ns> <selector>}" >&2; exit 2;;
esac
