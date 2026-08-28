#!/usr/bin/env bash
# Idempotent Kind cluster lifecycle and Docker network attachment (Phase 3)
set -euo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
KIND_CLUSTER_NAME=${AINETOPS_CLUSTER_NAME:-ainetops}
KIND_CONTEXT="kind-${KIND_CLUSTER_NAME}"
KIND_CONFIG="${ROOT_DIR}/config/kind/cluster.yaml"
MGMT_NET=${AINETOPS_MGMT_NET:-ainetops-mgmt}
LABEL_OWNER=${AINETOPS_OWNER_LABEL:-ainetops}
NODE_IMAGE_PIN=$(awk '/^kind:/,/^[^[:space:]]/ {print}' "${ROOT_DIR}/versions.lock.yaml" | awk -F': *' '/node_image:/ {print $2; exit}')

require() { command -v "$1" >/dev/null 2>&1 || { echo "[kind] missing command: $1" >&2; exit 1; }; }

kind::cluster_exists() {
  kind get clusters 2>/dev/null | grep -Fxq "${KIND_CLUSTER_NAME}"
}

kind::nodes() {
  kind get nodes --name "${KIND_CLUSTER_NAME}" 2>/dev/null || true
}

kind::recover_partial() {
  # If cluster is listed but nodes are missing or unhealthy, delete and recreate
  local nodes; nodes=$(kind::nodes)
  if [[ -n "${nodes}" ]]; then
    # Expect at least a control-plane node
    if ! grep -q "${KIND_CLUSTER_NAME}-control-plane" <<<"${nodes}"; then
      echo "[kind] partial cluster detected; deleting for recovery" >&2
      kind delete cluster --name "${KIND_CLUSTER_NAME}" || true
    fi
  fi
}

kind::ensure() {
  require kind
  require docker
  # Ensure mgmt network exists and is labeled (shared with containerlab)
  if ! docker network inspect "${MGMT_NET}" >/dev/null 2>&1; then
    docker network create --label ainetops.owner="${LABEL_OWNER}" "${MGMT_NET}"
  fi
  kind::recover_partial
  if ! kind::cluster_exists; then
    echo "[kind] creating cluster '${KIND_CLUSTER_NAME}' using ${KIND_CONFIG}"
    [[ -f "${KIND_CONFIG}" ]] || { echo "[kind] missing config ${KIND_CONFIG}" >&2; exit 1; }
    kind create cluster --name "${KIND_CLUSTER_NAME}" --config "${KIND_CONFIG}"
  else
    echo "[kind] cluster '${KIND_CLUSTER_NAME}' already exists (idempotent)"
  fi
  kind::verify_node_image
  kind::kube_context
}

kind::verify_node_image() {
  # Verify that nodes run the pinned image from versions.lock.yaml
  local pin base image_ok=1
  pin="${NODE_IMAGE_PIN}"
  if [[ -z "${pin}" ]]; then
    echo "[kind] WARN: no node image pin found in versions.lock.yaml" >&2
    return 0
  fi
  while read -r n; do
    [[ -z "${n}" ]] && continue
    base=$(docker inspect -f '{{.Config.Image}}' "${n}" 2>/dev/null || true)
    if [[ "${base%@*}" != "${pin%@*}" || "${base#*@}" != "${pin#*@}" ]]; then
      echo "[kind] ERROR: node ${n} image ${base} != pinned ${pin}" >&2
      image_ok=0
    fi
  done < <(kind::nodes)
  (( image_ok == 1 )) || { echo "[kind] node image mismatch" >&2; exit 1; }
}

kind::kube_context() {
  require kubectl
  # Ensure kube context resolves and points at our cluster
  kubectl cluster-info --context "${KIND_CONTEXT}" >/dev/null 2>&1 || {
    echo "[kind] setting current kubectl context to ${KIND_CONTEXT}" >&2
    kubectl config use-context "${KIND_CONTEXT}"
  }
  kubectl cluster-info --context "${KIND_CONTEXT}" >/dev/null 2>&1 || {
    echo "[kind] ERROR: kube-context ${KIND_CONTEXT} not available" >&2; exit 1; }
}

kind::attach_mgmt() {
  # Attach every Kind node container to the external mgmt network if not already attached
  require docker
  local nodes; nodes=$(kind::nodes)
  [[ -n "${nodes}" ]] || { echo "[kind] no nodes found to attach" >&2; return 0; }
  # Ensure mgmt network labeled
  docker network inspect "${MGMT_NET}" >/dev/null 2>&1 || docker network create --label ainetops.owner="${LABEL_OWNER}" "${MGMT_NET}"
  while read -r n; do
    [[ -z "${n}" ]] && continue
    if ! docker network inspect "${MGMT_NET}" -f '{{json .Containers}}' | grep -q "${n}"; then
      echo "[kind] attaching ${n} to ${MGMT_NET}"
      docker network connect "${MGMT_NET}" "${n}" || true
    else
      echo "[kind] ${n} already attached to ${MGMT_NET} (idempotent)"
    fi
  done <<<"${nodes}"
}

kind::delete() {
  require kind
  if kind::cluster_exists; then
    echo "[kind] deleting cluster '${KIND_CLUSTER_NAME}'"
    kind delete cluster --name "${KIND_CLUSTER_NAME}" || true
  else
    echo "[kind] cluster '${KIND_CLUSTER_NAME}' not present (idempotent)"
  fi
}

case "${1:-}" in
  ensure) shift; kind::ensure "$@" ;;
  attach-mgmt) shift; kind::attach_mgmt "$@" ;;
  delete) shift; kind::delete "$@" ;;
  verify-context) shift; kind::kube_context "$@" ;;
  *) echo "usage: $0 {ensure|attach-mgmt|delete|verify-context}" >&2; exit 2 ;;
 esac
