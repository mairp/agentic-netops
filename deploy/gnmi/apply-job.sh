#!/usr/bin/env bash
set -euo pipefail
CTX="kind-${AGENTIC_NETOPS_CLUSTER_NAME:-agentic-netops}"
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
command -v kubectl >/dev/null 2>&1 || { echo "missing kubectl" >&2; exit 1; }
# Ensure namespace and secrets exist (installed via deploy/rbac/*.yaml)
kubectl --context "$CTX" get ns agentic-netops-system >/dev/null 2>&1 || kubectl --context "$CTX" create ns agentic-netops-system
# Apply the Job
kubectl --context "$CTX" apply -f "$ROOT/deploy/gnmi/gnmi-incluster-job.yaml"
# Wait for completion and capture logs
kubectl --context "$CTX" -n agentic-netops-system wait --for=condition=Complete --timeout=120s job/gnmi-incluster-check || true
POD=$(kubectl --context "$CTX" -n agentic-netops-system get pods -l job-name=gnmi-incluster-check -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
if [[ -n "$POD" ]]; then
  kubectl --context "$CTX" -n agentic-netops-system logs "$POD" > "$ROOT/.wiggum/features/001-agentic-netops-sonic-evpn-fabric/gates/proofs/gnmi-incluster-check.logs.txt" 2>&1 || true
  kubectl --context "$CTX" -n agentic-netops-system get pod "$POD" -o yaml > "$ROOT/.wiggum/features/001-agentic-netops-sonic-evpn-fabric/gates/proofs/gnmi-incluster-check.pod.yaml" 2>&1 || true
fi
echo "[gnmi] in-cluster Job applied; logs captured if available"
