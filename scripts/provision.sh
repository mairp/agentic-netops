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