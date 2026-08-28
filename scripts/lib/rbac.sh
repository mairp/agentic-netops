#!/usr/bin/env bash
# Install least-privilege namespaces/RBAC/NetworkPolicies and lab Secrets via Kubernetes (Phase 3)
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
CTX="kind-${AINETOPS_CLUSTER_NAME:-ainetops}"
require(){ command -v "$1" >/dev/null 2>&1 || { echo "missing $1" >&2; exit 1; }; }
require kubectl

kubectl --context "$CTX" apply -f "$ROOT/deploy/rbac/base.yaml"
kubectl --context "$CTX" apply -f "$ROOT/deploy/rbac/secrets.yaml"
# Run generator job to populate runtime secrets
kubectl --context "$CTX" apply -f "$ROOT/deploy/rbac/secret-generator-job.yaml"
# Wait for job completion (best-effort)
kubectl --context "$CTX" -n ainetops-system wait --for=condition=Complete --timeout=120s job/ainetops-secret-generator || true
echo "[rbac] base namespaces/RBAC/network policies and lab Secrets applied"
