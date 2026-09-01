#!/usr/bin/env bash
# Assert installed AINETOPS-owned CRDs (T079a): exactly SRv6Service.ainetops.io
# and enforce FR-006: fail if duplicate/conflicting fabric/device-config CRDs exist.
# Note: The Kubernetes CRD name is the lowercase plural form srv6services.ainetops.io,
# while the success criterion names the Kind.Group form "SRv6Service.ainetops.io".
# Both refer to the same CRD family:
#   - Kind: SRv6Service
#   - Group: ainetops.io
#   - Plural name: srv6services.ainetops.io
# Allowed (only if T060 enables it): MigrationPlan.ainetops.io (plural: migrationplans.ainetops.io)
set -euo pipefail

CTX="kind-${AINETOPS_CLUSTER_NAME:-ainetops}"

# Get all CRD names in the cluster
all_crds=$(kubectl --context "$CTX" get crds -o jsonpath='{.items[*].metadata.name}' 2>/dev/null || true)

# AINETOPS-owned must contain exactly srv6services.ainetops.io
owned_want=(srv6services.ainetops.io)

# Build found list filtered by group ainetops.io
owned_found=()
for n in $all_crds; do
  if [[ "$n" == *.ainetops.io ]]; then owned_found+=("$n"); fi
done

# If MigrationPlan was explicitly enabled by T060 in future, allow it; otherwise enforce single CRD
allow_migration=${AINETOPS_ALLOW_MIGRATIONPLAN:-false}

ok=true
if [[ "$allow_migration" == "true" ]]; then
  # Allow two CRDs at most
  for n in "${owned_found[@]}"; do
    if [[ "$n" != "srv6services.ainetops.io" && "$n" != "migrationplans.ainetops.io" ]]; then
      ok=false
    fi
  done
else
  # Must be exactly one and match desired
  if [[ ${#owned_found[@]} -ne 1 || "${owned_found[0]}" != "srv6services.ainetops.io" ]]; then
    ok=false
  fi
fi

# FR-006 duplicate/conflict detection across fabric/device-config CRDs.
# Parse each CRD name into <plural>.<group>. Flag any fabric-related plural in the wrong group.
# Allowed groups for our fabric categories:
#   - Kubenet fabric intent: network.kubenet.dev (networkconfigs, networkdevices, topologies)
#   - KUID allocation: id.kuid.dev (ipindices, asnindices, vniindices, claims)
#   - SDC device-config: sdc.sdcio.dev (schemas, configs, targets)
conflicts=()
for n in $all_crds; do
  plural=${n%%.*}
  group=${n#*.}
  # Kubenet
  case "$plural" in
    networkconfigs|networkdevices|topologies)
      if [[ "$group" != "network.kubenet.dev" ]]; then conflicts+=("$n (expected group network.kubenet.dev)"); fi ;;
  esac
  # KUID
  case "$plural" in
    ipindices|asnindices|vniindices|claims)
      if [[ "$group" != "id.kuid.dev" ]]; then conflicts+=("$n (expected group id.kuid.dev)"); fi ;;
  esac
  # SDC
  case "$plural" in
    schemas|configs|targets)
      if [[ "$group" != "sdc.sdcio.dev" ]]; then conflicts+=("$n (expected group sdc.sdcio.dev)"); fi ;;
  esac
done

if [[ ${#conflicts[@]} -gt 0 ]]; then
  echo "[assert-crds] ERROR: Found duplicate/conflicting fabric/device-config CRDs:" >&2
  for c in "${conflicts[@]}"; do echo " - $c" >&2; done
  exit 1
fi

if ! $ok; then
  echo "[assert-crds] ERROR: AINETOPS-owned CRD set invalid: ${owned_found[*]:-<none>}" >&2
  exit 1
fi

echo "[assert-crds] OK: AINETOPS-owned CRDs = ${owned_found[*]} and no duplicate/conflicting fabric/device-config CRDs detected"
