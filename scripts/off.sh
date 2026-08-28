#!/usr/bin/env bash
set -euo pipefail

# AINETOPS SONiC EVPN/VXLAN Fabric — shutdown/cleanup script (Phase 3)
# Sole implementation of environment teardown per contracts/crd-api.md

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
LIB_DIR="${SCRIPT_DIR}/lib"

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
if [[ "${AINETOPS_DELETE_KIND:-false}" == "true" && -x "${LIB_DIR}/kind.sh" ]]; then
  "${LIB_DIR}/kind.sh" delete
fi

echo "[off] Teardown complete."
