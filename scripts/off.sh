#!/usr/bin/env bash
set -euo pipefail

# AINETOPS SONiC EVPN/VXLAN Fabric — shutdown/cleanup script (Phase 8)
# Sole implementation of environment teardown per contracts/crd-api.md

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
LIB_DIR="${SCRIPT_DIR}/lib"

# Flags
AINETOPS_CLUSTER_NAME=${AINETOPS_CLUSTER_NAME:-ainetops}
DELETE_KIND=${AINETOPS_DELETE_KIND:-false}
CAPTURE_EVIDENCE=${AINETOPS_CAPTURE_EVIDENCE:-false}

usage() {
  cat <<EOF
Usage: $0 [--cluster-name NAME] [--delete-kind true|false] [--capture-evidence true|false]
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cluster-name) shift; AINETOPS_CLUSTER_NAME=${1:-$AINETOPS_CLUSTER_NAME} ;;
    --delete-kind) shift; DELETE_KIND=${1:-$DELETE_KIND} ;;
    --capture-evidence) shift; CAPTURE_EVIDENCE=${1:-$CAPTURE_EVIDENCE} ;;
    -h|--help) usage; exit 0 ;;
    *) echo "[off] unknown flag: $1" >&2; usage; exit 2 ;;
  esac
  shift || true
done
export AINETOPS_CLUSTER_NAME

# Optional evidence capture
if [[ "$CAPTURE_EVIDENCE" == "true" ]]; then
  proofs="${SCRIPT_DIR}/../.wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs"
  mkdir -p "$proofs"
  if command -v kubectl >/dev/null 2>&1; then
    CTX="kind-${AINETOPS_CLUSTER_NAME}"
    kubectl --context "$CTX" get pods -A -o wide | nl -ba > "$proofs/kubectl-get-all-before-off.txt" || true
    kubectl --context "$CTX" get crds | nl -ba > "$proofs/kubectl-get-crds-before-off.txt" || true
  fi
fi

# Remove generated Secrets from the local repo BEFORE containerlab destroy:
# the destroy helper verifies the lab left no generated credentials behind, so
# the lifecycle-owned removal must happen first (the test phase may have
# materialized ./secrets/* from in-cluster Secrets).
rm -f "${SCRIPT_DIR}/../secrets/gnmi.key" "${SCRIPT_DIR}/../secrets/gnmi.crt" "${SCRIPT_DIR}/../secrets/ca.crt" 2>/dev/null || true

# Idempotent containerlab teardown and cleanup checks
if [[ -x "${LIB_DIR}/containerlab.sh" ]]; then
  "${LIB_DIR}/containerlab.sh" destroy || {
    echo "[off] containerlab destroy reported leftovers" >&2
    exit 1
  }
else
  echo "[off] WARN: containerlab helper not found; skipping lab teardown" >&2
fi

# Optionally delete Kind cluster if requested
if [[ "$DELETE_KIND" == "true" && -x "${LIB_DIR}/kind.sh" ]]; then
  "${LIB_DIR}/kind.sh" delete
fi

# Cleanup owned network and generated Secrets (safe, scoped)
if command -v docker >/dev/null 2>&1; then
  if docker network inspect ainetops-mgmt >/dev/null 2>&1; then
    # Do not remove if foreign label
    if docker network inspect ainetops-mgmt -f '{{json .Labels}}' | grep -q '"ainetops.owner":"ainetops"'; then
      docker network rm ainetops-mgmt >/dev/null 2>&1 || true
    else
      echo "[off] preserving non-owned network ainetops-mgmt" >&2
    fi
  fi
fi

# Remove generated Secrets from local repo if present
rm -f "${SCRIPT_DIR}/../secrets/gnmi.key" "${SCRIPT_DIR}/../secrets/gnmi.crt" "${SCRIPT_DIR}/../secrets/ca.crt" 2>/dev/null || true

echo "[off] Teardown complete (idempotent)."