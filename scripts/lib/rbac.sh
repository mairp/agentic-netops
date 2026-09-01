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
# T022 placeholders: apply ONLY when the secrets are absent. Re-applying an empty
# placeholder over a POPULATED secret wipes its data keys (kubectl apply removes
# keys absent from the manifest via the last-applied annotation), which emptied
# gnmi-lab-creds on the second idempotence provision and spun the rbac
# verification loop below forever (observed 2026-09-01).
if ! kubectl --context "$CTX" -n ainetops-system get secret gnmi-lab-creds >/dev/null 2>&1 || \
   ! kubectl --context "$CTX" -n ainetops-system get secret gnmi-lab-tls >/dev/null 2>&1; then
  kubectl --context "$CTX" apply -f "$ROOT/deploy/rbac/secrets.yaml"
fi
# The generator Job runs the pinned Kind node image (kubectl + openssl + curl).
# Ensure that exact digest is resolvable in the cluster's containerd on every node
# before scheduling the Job (idempotent; a fresh Kind node stores it under the
# node-image import name only).
if command -v kind >/dev/null 2>&1 && command -v docker >/dev/null 2>&1; then
  NODE_IMAGE=$(awk '/^kind:/{f=1;next} f&&/node_image:/{print $2;exit}' "$ROOT/versions.lock.yaml")
  if [[ -n "${NODE_IMAGE:-}" ]]; then
    kind load docker-image "$NODE_IMAGE" --name "${AINETOPS_CLUSTER_NAME:-ainetops}" || \
      echo "[rbac] WARN: kind load $NODE_IMAGE failed (Job may retry the pull)" >&2
  fi
fi
# Run generator job to populate runtime secrets
kubectl --context "$CTX" apply -f "$ROOT/deploy/rbac/secret-generator-job.yaml"
# Wait for job completion and VERIFY the generated Secret data keys (T073/T077:
# populated at runtime, never committed). Re-run the Job once if a prior partial
# provision left the placeholders empty; fail if the keys are still missing.
if ! kubectl --context "$CTX" -n ainetops-system wait --for=condition=Complete --timeout=60s job/ainetops-secret-generator 2>/dev/null; then
  echo "[rbac] generator job incomplete; recreating it" >&2
  kubectl --context "$CTX" -n ainetops-system delete job ainetops-secret-generator --ignore-not-found
  kubectl --context "$CTX" apply -f "$ROOT/deploy/rbac/secret-generator-job.yaml"
  kubectl --context "$CTX" -n ainetops-system wait --for=condition=Complete --timeout=90s job/ainetops-secret-generator
fi
for key in gnmi-lab-creds/username gnmi-lab-creds/password gnmi-lab-tls/ca.crt gnmi-lab-tls/tls.crt gnmi-lab-tls/tls.key; do
  sec=${key%%/*}; k=${key##*/}
  until [[ -n "$(kubectl --context "$CTX" -n ainetops-system get secret "$sec" -o "jsonpath={.data.${k//./\\.}}" 2>/dev/null)" ]]; do
    echo "[rbac] secret $sec key $k missing; rerunning generator job" >&2
    kubectl --context "$CTX" -n ainetops-system delete job ainetops-secret-generator --ignore-not-found
    kubectl --context "$CTX" apply -f "$ROOT/deploy/rbac/secret-generator-job.yaml"
    kubectl --context "$CTX" -n ainetops-system wait --for=condition=Complete --timeout=90s job/ainetops-secret-generator
  done
done
echo "[rbac] base namespaces/RBAC/network policies, controller RBAC, and lab Secrets applied"
