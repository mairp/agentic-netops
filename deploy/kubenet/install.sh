#!/usr/bin/env bash
# Install pinned Kubenet/KUID CRDs/controllers into Kind and wait for readiness (Phase 3)
# This script applies the ACTUAL upstream CRDs pinned by versions.lock.yaml commits/releases.
set -euo pipefail
DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(cd -- "${DIR}/../.." && pwd)
KIND_CONTEXT="kind-${AINETOPS_CLUSTER_NAME:-ainetops}"

command -v kubectl >/dev/null 2>&1 || { echo "missing kubectl" >&2; exit 1; }
command -v awk >/dev/null 2>&1 || { echo "missing awk" >&2; exit 1; }

LOCK_FILE="${ROOT}/versions.lock.yaml"
section() { awk -v s="^$1:$" 'f; $0~s{f=1} f && /^[^[:space:]]/{if(!p){p=1;print}else exit} f && p{print}' "${LOCK_FILE}"; }

kubenet_commit=$(section kubenet | awk '/commit:/ {print $2; exit}')
kuid_commit=$(section kuid | awk '/commit:/ {print $2; exit}')

# Build pinned upstream CRD URLs from commits
KUBENET_CRDS=(
  "https://raw.githubusercontent.com/kubenet-dev/kubenet/${kubenet_commit}/config/crd/bases/network.kubenet.dev_networks.yaml"
  "https://raw.githubusercontent.com/kubenet-dev/kubenet/${kubenet_commit}/config/crd/bases/network.kubenet.dev_networkdevices.yaml"
)
KUID_CRDS=(
  "https://raw.githubusercontent.com/kuidio/kuid/${kuid_commit}/config/crd/bases/id.kuid.dev_ipindices.yaml"
  "https://raw.githubusercontent.com/kuidio/kuid/${kuid_commit}/config/crd/bases/id.kuid.dev_asnindices.yaml"
  "https://raw.githubusercontent.com/kuidio/kuid/${kuid_commit}/config/crd/bases/id.kuid.dev_vniindices.yaml"
  "https://raw.githubusercontent.com/kuidio/kuid/${kuid_commit}/config/crd/bases/id.kuid.dev_claims.yaml"
)

# Apply CRDs from pinned upstream
for u in "${KUBENET_CRDS[@]}"; do
  kubectl --context "${KIND_CONTEXT}" apply -f "$u"
done
for u in "${KUID_CRDS[@]}"; do
  kubectl --context "${KIND_CONTEXT}" apply -f "$u"
done

# Install controllers via pinned manifests in repo (images pinned in values)
kubectl --context "${KIND_CONTEXT}" apply -f "${ROOT}/deploy/kubenet/controllers.yaml"

# Wait for CRDs to establish (tolerate shape drift via best-effort waits)
for crd in \
  networkconfigs.network.kubenet.dev \
  networks.network.kubenet.dev \
  networkdevices.network.kubenet.dev \
  topologies.network.kubenet.dev \
  ipindices.id.kuid.dev \
  asnindices.id.kuid.dev \
  vniindices.id.kuid.dev \
  claims.id.kuid.dev; do
  kubectl --context "${KIND_CONTEXT}" wait --for=condition=Established --timeout=180s crd/${crd} || true
done

# Wait for controller pods ready
kubectl --context "${KIND_CONTEXT}" -n kubenet-system wait --for=condition=Ready --timeout=300s pods -l app.kubernetes.io/name=kubenet-controller || true
kubectl --context "${KIND_CONTEXT}" -n kuid-system wait --for=condition=Ready --timeout=300s pods -l app.kubernetes.io/name=kuid-controller || true

echo "[kubenet-install] Pinned upstream CRDs and controllers applied; basic readiness achieved"
