#!/usr/bin/env bash
# Idempotent Kind cluster lifecycle and Docker network attachment (Phase 3)
set -euo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
KIND_CLUSTER_NAME=${AINETOPS_CLUSTER_NAME:-ainetops}
KIND_CONTEXT="kind-${KIND_CLUSTER_NAME}"
KIND_CONFIG="${ROOT_DIR}/config/kind/cluster.yaml"
MGMT_NET=${AINETOPS_MGMT_NET:-ainetops-mgmt}
# The management subnet MUST be user-configured: containerlab assigns explicit
# per-node mgmt IPs (172.31.0.x) and Docker rejects user-specified endpoint IPs
# on auto-assigned subnets ("user specified IP address is supported only when
# connecting to networks with user configured subnets"). It must also match the
# mgmt.ipv4-subnet in lab/topology.clab.yml and the AINETOPS_MGMT_CIDR used by
# the preflight overlap check (172.31.0.0/16).
MGMT_SUBNET=${AINETOPS_MGMT_SUBNET:-172.31.0.0/16}
LABEL_OWNER=${AINETOPS_OWNER_LABEL:-ainetops}

# Idempotent, subnet-correct ownership of the shared AINETOPS management network.
# Safe to call from every lifecycle phase; heals a pre-existing network that has
# the wrong (auto-assigned) subnet as long as nothing is attached to it.
kind::ensure_mgmt_network() {
  require docker
  if docker network inspect "${MGMT_NET}" >/dev/null 2>&1; then
    local cur attached
    cur=$(docker network inspect "${MGMT_NET}" -f '{{range .IPAM.Config}}{{.Subnet}}{{end}}' 2>/dev/null || true)
    if [[ "${cur}" == "${MGMT_SUBNET}" ]]; then
      return 0
    fi
    attached=$(docker network inspect "${MGMT_NET}" -f '{{len .Containers}}' 2>/dev/null || echo 1)
    if [[ "${attached}" == "0" ]]; then
      echo "[net] ${MGMT_NET} has subnet '${cur}' (need ${MGMT_SUBNET}); recreating (no attached containers)" >&2
      docker network rm "${MGMT_NET}" >/dev/null
    else
      echo "[net] ERROR: ${MGMT_NET} subnet '${cur}' != ${MGMT_SUBNET} and ${attached} container(s) attached; detach them or remove the network manually" >&2
      return 1
    fi
  fi
  docker network create --label ainetops.owner="${LABEL_OWNER}" --subnet "${MGMT_SUBNET}" "${MGMT_NET}" >/dev/null
}
# Extract the pinned Kind node image from the `kind:` block. The value itself
# contains a colon (registry/image@sha256:digest), so we must strip only the
# leading `node_image:` key, not split on every colon.
NODE_IMAGE_PIN=$(awk '
  /^kind:/ {insec=1; next}
  insec && /^[^[:space:]]/ {exit}
  insec && /node_image:/ {sub(/^[^:]*:[ ]*/,""); print; exit}
' "${ROOT_DIR}/versions.lock.yaml")

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
  # Ensure mgmt network exists, labeled, and subnet-correct (shared with containerlab)
  kind::ensure_mgmt_network
  kind::recover_partial
  # A cluster that is listed but has no resolvable kube context is a stale or
  # partially-deleted state (kind delete removes the context; node containers can
  # linger briefly so `kind get clusters` may still list it). Trust the kube
  # context as the liveness signal: remove the stale state and recreate.
  if kind::cluster_exists && ! kubectl cluster-info --context "${KIND_CONTEXT}" >/dev/null 2>&1; then
    echo "[kind] cluster '${KIND_CLUSTER_NAME}' listed but kube context unavailable; removing stale state for recovery" >&2
    kind delete cluster --name "${KIND_CLUSTER_NAME}" || true
    local i=0
    while kind::cluster_exists && (( i < 30 )); do sleep 2; i=$((i+1)); done
  fi
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
  if kubectl cluster-info --context "${KIND_CONTEXT}" >/dev/null 2>&1; then
    kubectl config use-context "${KIND_CONTEXT}" >/dev/null 2>&1 || true
    return 0
  fi
  echo "[kind] ERROR: kube-context ${KIND_CONTEXT} not available (cluster '${KIND_CLUSTER_NAME}' has no resolvable control plane)" >&2
  return 1
}

kind::attach_mgmt() {
  # Attach every Kind node container to the external mgmt network if not already attached
  require docker
  local nodes; nodes=$(kind::nodes)
  [[ -n "${nodes}" ]] || { echo "[kind] no nodes found to attach" >&2; return 0; }
  # Ensure mgmt network labeled and subnet-correct
  kind::ensure_mgmt_network
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
  ensure-mgmt) shift; kind::ensure_mgmt_network "$@" ;;
  delete) shift; kind::delete "$@" ;;
  verify-context) shift; kind::kube_context "$@" ;;
  *) echo "usage: $0 {ensure|attach-mgmt|ensure-mgmt|delete|verify-context}" >&2; exit 2 ;;
 esac
