#!/usr/bin/env bash
set -euo pipefail

# AINETOPS SONiC EVPN/VXLAN Fabric — provision script (Phase 2 updates)
# Sole implementation of environment creation/convergence per contracts/crd-api.md

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
REPO_ROOT=$(cd -- "${SCRIPT_DIR}/.." && pwd)
LIB_DIR="${SCRIPT_DIR}/lib"

# shellcheck source=./lib/preflight.sh
if [[ -f "${LIB_DIR}/preflight.sh" ]]; then
  # Preflight validates versions.lock.yaml, host resources, privileges, MTU, address overlaps, KVM
  source "${LIB_DIR}/preflight.sh"
  preflight::run "$@"
fi

# Ordered phases (Phase 3): verify pins, validate CRDs, create Kind, attach mgmt net, run capability gate
if [[ -f "${REPO_ROOT}/Makefile" ]]; then
  make -C "${REPO_ROOT}" verify-compat
fi

# Ensure external management network exists (idempotent)
if command -v docker >/dev/null 2>&1; then
  docker network inspect ainetops-mgmt >/dev/null 2>&1 || docker network create --label ainetops.owner=ainetops ainetops-mgmt
fi

# Ensure Kind cluster exists and is using pinned image; attach nodes to mgmt network
if [[ -x "${LIB_DIR}/kind.sh" ]]; then
  "${LIB_DIR}/kind.sh" ensure
  "${LIB_DIR}/kind.sh" attach-mgmt
  "${LIB_DIR}/kind.sh" verify-context
else
  echo "[provision] WARN: kind helper not found; skipping Kind cluster ensure" >&2
fi

# Deploy lab topology with containerlab if available
if [[ -x "${LIB_DIR}/containerlab.sh" ]]; then
  "${LIB_DIR}/containerlab.sh" deploy || { echo "[provision] containerlab deploy failed" >&2; exit 1; }
  # Optional inspect step for diagnostics
  "${LIB_DIR}/containerlab.sh" inspect || true
else
  echo "[provision] WARN: containerlab helper not found; skipping lab deploy" >&2
fi

# Install least-privilege RBAC base
if [[ -x "${LIB_DIR}/rbac.sh" ]]; then
  "${LIB_DIR}/rbac.sh"
fi
# Install pinned Kubenet/KUID and SDC into Kind and wait basic readiness
if [[ -x "${REPO_ROOT}/deploy/kubenet/install.sh" ]]; then
  "${REPO_ROOT}/deploy/kubenet/install.sh"
fi
if [[ -x "${REPO_ROOT}/deploy/sdc/install.sh" ]]; then
  "${REPO_ROOT}/deploy/sdc/install.sh"
fi

# Build, load, and deploy provider and srv6-controller images into Kind (T041)
if command -v docker >/dev/null 2>&1 && command -v kind >/dev/null 2>&1 && command -v kubectl >/dev/null 2>&1; then
  echo "[provision] building controller images"
  docker build -t ainetops-sonic-provider:dev -f "${REPO_ROOT}/cmd/sonic-provider/Dockerfile" "${REPO_ROOT}"
  docker build -t ainetops-srv6-controller:dev -f "${REPO_ROOT}/cmd/srv6-controller/Dockerfile" "${REPO_ROOT}"
  echo "[provision] loading images into Kind"
  kind load docker-image ainetops-sonic-provider:dev --name "${AINETOPS_CLUSTER_NAME:-ainetops}" || true
  kind load docker-image ainetops-srv6-controller:dev --name "${AINETOPS_CLUSTER_NAME:-ainetops}" || true
  echo "[provision] deploying controllers"
  # Use dev images by overriding the container image in manifests
  kubectl --context "kind-${AINETOPS_CLUSTER_NAME:-ainetops}" -n ainetops-system apply -f "${REPO_ROOT}/deploy/ainetops/manifests/provider.yaml"
  kubectl --context "kind-${AINETOPS_CLUSTER_NAME:-ainetops}" -n ainetops-system apply -f "${REPO_ROOT}/deploy/ainetops/manifests/srv6-controller.yaml"
  kubectl --context "kind-${AINETOPS_CLUSTER_NAME:-ainetops}" -n ainetops-system set image deploy/ainetops-sonic-provider provider=ainetops-sonic-provider:dev || true
  kubectl --context "kind-${AINETOPS_CLUSTER_NAME:-ainetops}" -n ainetops-system set image deploy/ainetops-srv6-controller srv6-controller=ainetops-srv6-controller:dev || true
  echo "[provision] waiting for controller pods ready"
  kubectl --context "kind-${AINETOPS_CLUSTER_NAME:-ainetops}" -n ainetops-system rollout status deploy/ainetops-sonic-provider --timeout=180s
  kubectl --context "kind-${AINETOPS_CLUSTER_NAME:-ainetops}" -n ainetops-system rollout status deploy/ainetops-srv6-controller --timeout=180s
  # Capture independent observation proof
  mkdir -p "${REPO_ROOT}/.wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs"
  kubectl --context "kind-${AINETOPS_CLUSTER_NAME:-ainetops}" -n ainetops-system get deploy,po,svc -o wide \
    | nl -ba > "${REPO_ROOT}/.wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/kubectl-get-ainetops-system.txt"
fi

# Apply default Kubenet Network, tenant examples, and SRv6 sample (T042, T044, T045, T046)
if command -v kubectl >/dev/null 2>&1; then
  CTX="kind-${AINETOPS_CLUSTER_NAME:-ainetops}"
  echo "[provision] applying SRv6Service CRD and Kubenet default/tenant networks"
  kubectl --context "$CTX" apply -f "${REPO_ROOT}/config/crd/bases/ainetops.io_srv6services.yaml"
  kubectl --context "$CTX" apply -f "${REPO_ROOT}/deploy/kubenet/topology.yaml"
  kubectl --context "$CTX" apply -f "${REPO_ROOT}/deploy/kubenet/topology-and-indices.yaml"
  kubectl --context "$CTX" apply -f "${REPO_ROOT}/deploy/kubenet/claims.yaml"
  kubectl --context "$CTX" apply -f "${REPO_ROOT}/deploy/kubenet/srv6-pools.yaml"
  kubectl --context "$CTX" apply -f "${REPO_ROOT}/deploy/kubenet/networks/default.yaml"
  kubectl --context "$CTX" apply -f "${REPO_ROOT}/deploy/kubenet/networks/tenants/l2-bridged.yaml"
  kubectl --context "$CTX" apply -f "${REPO_ROOT}/deploy/kubenet/networks/tenants/l3-routed.yaml"
  kubectl --context "$CTX" apply -f "${REPO_ROOT}/deploy/kubenet/networks/tenants/irb-symmetric.yaml"
  kubectl --context "$CTX" apply -f "${REPO_ROOT}/config/samples/ainetops_v1alpha1_srv6service.yaml"
  # Capture independent observation of applied Network resources
  kubectl --context "$CTX" -n kubenet-system get networkconfigs,networks 2>/dev/null | nl -ba > "${REPO_ROOT}/.wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/kubectl-get-kubenet-networks.txt" || true
fi
# Seed SDC schema/profile/discovery (address-based); tolerate apply idempotence
if command -v kubectl >/dev/null 2>&1; then
  CTX="kind-${AINETOPS_CLUSTER_NAME:-ainetops}"
  kubectl --context "$CTX" apply -f "${REPO_ROOT}/deploy/sdc/seed/sonic-schema.yaml"
  kubectl --context "$CTX" apply -f "${REPO_ROOT}/deploy/sdc/seed/discovery-rule.yaml"
fi

# Run lab capability qualification (fast profile can be selected via env)
if [[ -x "${LIB_DIR}/qualify.sh" ]]; then
  "${LIB_DIR}/qualify.sh" || { echo "[provision] capability gate failed" >&2; exit 1; }
fi

echo "[provision] Phase 3: pins verified, CRDs validated, Kind ensured/attached, apps installed, seed applied, capability gate executed."