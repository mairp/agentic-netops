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
kuid_commit=$(section kuid | awk '/commit:/ {print $2; exit}')
sdc_release=$(section sdc | awk '/release:/ {print $2; exit}')

[[ $kubenet_commit =~ ^[0-9a-f]{40}$ ]] || { echo "invalid kubenet commit in versions.lock.yaml" >&2; exit 1; }
[[ $kuid_commit =~ ^[0-9a-f]{40}$ ]] || { echo "invalid kuid commit in versions.lock.yaml" >&2; exit 1; }
[[ $sdc_release =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "invalid sdc release in versions.lock.yaml" >&2; exit 1; }

# Example upstream raw paths (pinned by commit/release). Replace with authoritative paths as needed.
KUBENET_CRDS=(
  "https://raw.githubusercontent.com/kubenet-dev/kubenet/${kubenet_commit}/config/crd/bases/network.kubenet.dev_networks.yaml"
  "https://raw.githubusercontent.com/kubenet-dev/kubenet/${kubenet_commit}/config/crd/bases/network.kubenet.dev_networkdevices.yaml"
)
KUBENET_EXAMPLES=(
  "https://raw.githubusercontent.com/kubenet-dev/kubenet/${kubenet_commit}/examples/default-network.yaml"
)
KUID_CRDS=(
  "https://raw.githubusercontent.com/kubenet-dev/kuid/${kuid_commit}/config/crd/bases/id.kuid.dev_claims.yaml"
)
SDC_CRDS=(
  "https://raw.githubusercontent.com/sdcio/sdc/${sdc_release}/deploy/crds/sdc.sdcio.dev_schemas.yaml"
  "https://raw.githubusercontent.com/sdcio/sdc/${sdc_release}/deploy/crds/sdc.sdcio.dev_configs.yaml"
  "https://raw.githubusercontent.com/sdcio/sdc/${sdc_release}/deploy/crds/sdc.sdcio.dev_targets.yaml"
)

run_dry_run() {
  local what=$1; shift
  local -a files=("$@")
  echo "[validate-crds] server-side dry-run: ${what} (${#files[@]} files)" >&2
  # Build multiple -f flags so kubectl handles each manifest separately
  local -a args=(apply --dry-run=server)
  for f in "${files[@]}"; do args+=( -f "$f" ); done
  set -x
  kubectl "${args[@]}" 1>/dev/null
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
