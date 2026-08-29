#!/usr/bin/env bash
# Install least-privilege namespaces/RBAC/NetworkPolicies and lab Secrets via Kubernetes (Phase 3)
set -euo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
CTX="kind-${AINETOPS_CLUSTER_NAME:-ainetops}"
require(){ command -v "$1" >/dev/null 2>&1 || { echo "missing $1" >&2; exit 1; }; }
require kubectl

kubectl --context "$CTX" apply -f "$ROOT/deploy/rbac/base.yaml"
# Controller service accounts and cluster roles/bindings
kubectl --context "$CTX" apply -f "$ROOT/config/rbac/service_account.yaml"
kubectl --context "$CTX" apply -f "$ROOT/config/rbac/cluster_role.yaml"
kubectl --context "$CTX" apply -f "$ROOT/config/rbac/cluster_role_binding.yaml"
# SRv6 CRD read permissions bound to the SRv6 controller SA
kubectl --context "$CTX" apply -f "$ROOT/deploy/rbac/srv6-crd-rbac.yaml"
# Lab secrets and generator job
kubectl --context "$CTX" apply -f "$ROOT/deploy/rbac/secrets.yaml"
# Run generator job to populate runtime secrets
kubectl --context "$CTX" apply -f "$ROOT/deploy/rbac/secret-generator-job.yaml"
# Wait for job completion (best-effort)
kubectl --context "$CTX" -n ainetops-system wait --for=condition=Complete --timeout=120s job/ainetops-secret-generator || true
echo "[rbac] base namespaces/RBAC/network policies, controller RBAC, and lab Secrets applied"
