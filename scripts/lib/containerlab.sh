#!/usr/bin/env bash
# Idempotent containerlab deploy/inspect/destroy helpers (Phase 2)
set -euo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
TOPO_FILE="${ROOT_DIR}/lab/topology.clab.yml"
MGMT_NET="ainetops-mgmt"
LABEL_OWNER="ainetops"

clab::require() { command -v containerlab >/dev/null 2>&1 || { echo "missing containerlab" >&2; exit 1; }; }

clab::deploy() {
  clab::require
  echo "[clab] ensuring external Docker network ${MGMT_NET} exists"
  docker network inspect "${MGMT_NET}" >/dev/null 2>&1 || docker network create --label ainetops.owner=${LABEL_OWNER} "${MGMT_NET}"
  echo "[clab] deploying ${TOPO_FILE}"
  containerlab deploy -t "${TOPO_FILE}" --reconfigure --skip-save -c
}

clab::inspect() {
  clab::require
  containerlab inspect -t "${TOPO_FILE}" -o json
}

clab::destroy() {
  clab::require
  echo "[clab] destroying ${TOPO_FILE}"
  containerlab destroy -t "${TOPO_FILE}" --cleanup || true
  # Verify teardown leaves no owned lab containers or volumes
  local leftovers
  leftovers=$(docker ps -a --format '{{.Names}} {{.Labels}}' | awk '/ainetops.owner=ainetops/ {print $1}') || true
  if [[ -n "$leftovers" ]]; then
    echo "[clab] WARN: leftover AINETOPS containers not removed:\n$leftovers" >&2
    exit 1
  fi
  # Check for owned volumes (persistent /etc/sonic)
  local vol_left
  vol_left=$(docker volume ls -q | grep -E '^ainetops-.*-etc-sonic$' || true)
  if [[ -n "$vol_left" ]]; then
    echo "[clab] WARN: leftover AINETOPS volumes not removed:\n$vol_left" >&2
    exit 1
  fi
  # Check for generated lab credentials under repo secrets/
  if [[ -e "${ROOT_DIR}/secrets/gnmi.key" || -e "${ROOT_DIR}/secrets/gnmi.crt" || -e "${ROOT_DIR}/secrets/ca.crt" ]]; then
    echo "[clab] WARN: leftover lab-generated gNMI credentials under ${ROOT_DIR}/secrets" >&2
    exit 1
  fi
  echo "[clab] destroy complete"
}

case "${1:-}" in
  deploy) shift; clab::deploy "$@" ;;
  inspect) shift; clab::inspect "$@" ;;
  destroy) shift; clab::destroy "$@" ;;
  *) echo "usage: $0 {deploy|inspect|destroy}" >&2; exit 2 ;;
esac
