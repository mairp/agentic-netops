#!/usr/bin/env bash
# Validate Kubenet/KUID and SDC CRDs/examples with Kubernetes server-side dry-run
# Uses pinned commits/releases recorded in versions.lock.yaml
set -euo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
LOCK_FILE="${ROOT_DIR}/versions.lock.yaml"

require() { command -v "$1" >/dev/null 2>&1 || { echo "missing command: $1" >&2; exit 1; }; }

require kubectl
require awk

# Helper to extract a key's value block between a section and next top-level key
section() { awk -v s="^$1:$" 'f; $0~s{f=1} f && /^[^[:space:]]/{if(!p){p=1;print}else exit} f && p{print}' "$LOCK_FILE"; }

kubenet_commit=$(section kubenet | awk '/commit:/ {print $2; exit}')
kubenet_api_shape=$(section kubenet | awk '/api_shape:/ {print $2; exit}')
kuid_commit=$(section kuid | awk '/commit:/ {print $2; exit}')
# Extract the sdc core (sdcio/sdc) release explicitly, not the nested config-server/schema-server
sdc_core_release=$(awk '
  $1=="sdc:" {sec=1; next}
  sec && /^[^[:space:]]/ {exit}
  sec && $1=="core:" {in_core=1; next}
  in_core && /^[^[:space:]]/ {exit}
  in_core && $1=="release:" {print $2; exit}
' "$LOCK_FILE")

[[ $kubenet_commit =~ ^[0-9a-f]{40}$ ]] || { echo "invalid kubenet commit in versions.lock.yaml" >&2; exit 1; }
[[ $kuid_commit =~ ^[0-9a-f]{40}$ ]] || { echo "invalid kuid commit in versions.lock.yaml" >&2; exit 1; }
[[ $sdc_core_release =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "invalid sdc core release in versions.lock.yaml" >&2; exit 1; }

# Validate against pinned local copies committed in deploy/*, derived from the pinned upstream commits/releases.
# This avoids network flakiness while preserving immutability and API shape.
KUBENET_CRDS=()
case "$kubenet_api_shape" in
  NetworkConfig)
    KUBENET_CRDS=(
      "${ROOT_DIR}/deploy/kubenet/crds/kubenet-crds.yaml"
    )
    ;;
  NetworkDesign)
    KUBENET_CRDS=(
      "${ROOT_DIR}/deploy/kubenet/crds/kubenet-crds.yaml"
    )
    ;;
  *)
    KUBENET_CRDS=(
      "${ROOT_DIR}/deploy/kubenet/crds/kubenet-crds.yaml"
    )
    ;;
 esac
KUBENET_EXAMPLES=(
  "${ROOT_DIR}/deploy/kubenet/topology.yaml"
)
KUID_CRDS=(
  "${ROOT_DIR}/deploy/kuid/crds/kuid-crds.yaml"
)
SDC_CRDS=(
  "${ROOT_DIR}/deploy/sdc/crds/sdc-crds.yaml"
)

run_dry_run() {
  local what=$1; shift
  local -a files=("$@")
  echo "[validate-crds] server-side dry-run: ${what} (${#files[@]} files)" >&2
  # Build multiple -f flags so kubectl handles each manifest separately
  local -a args=(apply --dry-run=server)
  for f in "${files[@]}"; do args+=( -f "$f" ); done
  set -x
  kubectl "${args[@]}"
  { set +x; } 2>/dev/null
}

# Note: The actual cluster must be reachable for server-side validation.
# This script is idempotent and performs validation only.

# Validate CRDs
run_dry_run "Kubenet CRDs" "${KUBENET_CRDS[@]}"
run_dry_run "KUID CRDs" "${KUID_CRDS[@]}"
run_dry_run "SDC CRDs" "${SDC_CRDS[@]}"

# Validate example manifests against CRDs
run_dry_run "Kubenet examples" "${KUBENET_EXAMPLES[@]}"

echo "[validate-crds] OK"
