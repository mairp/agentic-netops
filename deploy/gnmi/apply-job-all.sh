#!/usr/bin/env bash
set -euo pipefail
CTX="kind-${AINETOPS_CLUSTER_NAME:-ainetops}"
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
command -v kubectl >/dev/null 2>&1 || { echo "missing kubectl" >&2; exit 1; }
# Ensure namespace exists
kubectl --context "$CTX" get ns ainetops-system >/dev/null 2>&1 || kubectl --context "$CTX" create ns ainetops-system
# Apply the Job
kubectl --context "$CTX" apply -f "$ROOT/deploy/gnmi/gnmi-incluster-job-all.yaml"
# Wait for completion and capture logs
kubectl --context "$CTX" -n ainetops-system wait --for=condition=Complete --timeout=180s job/gnmi-incluster-check-all || true
POD=$(kubectl --context "$CTX" -n ainetops-system get pods -l job-name=gnmi-incluster-check-all -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
if [[ -n "$POD" ]]; then
  kubectl --context "$CTX" -n ainetops-system logs "$POD" > "$ROOT/.wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/gnmi-incluster-check-all.logs.txt" 2>&1 || true
  kubectl --context "$CTX" -n ainetops-system get pod "$POD" -o yaml > "$ROOT/.wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/gnmi-incluster-check-all.pod.yaml" 2>&1 || true
fi
echo "[gnmi] in-cluster multi-target Job applied; logs captured if available"