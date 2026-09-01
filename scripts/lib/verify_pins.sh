#!/usr/bin/env bash
# Verify versions.lock.yaml pins per NFR-003
set -euo pipefail

fail() { echo "[verify-pins] ERROR: $*" >&2; exit 1; }
info() { echo "[verify-pins] $*" >&2; }

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
LOCK_FILE="${ROOT_DIR}/versions.lock.yaml"

[[ -f "$LOCK_FILE" ]] || fail "missing $LOCK_FILE"

# Reject floating refs
if grep -En '\blatest\b|\bmain\b|\bmaster\b|\bHEAD\b' "$LOCK_FILE" >/dev/null; then
  fail "floating refs found (latest/main/master/HEAD)"
fi

# Extract helper: get yaml value block by top-level section name (simple, indentation-based)
get_block() {
  # get_block SECTION_NAME returns block lines until next top-level key (top-level only)
  awk -v sec="$1" '
    $0 ~ "^" sec ":\\s*$" {inside=1; print; next}
    inside && /^[^[:space:]]/ {exit}
    inside {print}
  ' "$LOCK_FILE"
}

# Check kind node image digest (robust section parsing)
if ! get_block kind | grep -E '^[[:space:]]*node_image:[[:space:]]*[^@]+@sha256:[0-9a-f]{64}[[:space:]]*$' >/dev/null; then
  fail "kind.node_image must include @sha256 digest"
fi

# Check controller-runtime and Go (use robust block extraction)
get_block kubernetes | grep -E '^[[:space:]]*controller_runtime:[[:space:]]*v[0-9]+\.[0-9]+\.[0-9]+' >/dev/null || fail "missing kubernetes.controller_runtime semver"
get_block kubernetes | grep -E "^[[:space:]]*go:[[:space:]]*['\"]?1\.[0-9]+(\.[0-9]+)?['\"]?[[:space:]]*$" >/dev/null || fail "missing kubernetes.go version"

# Check Kubenet/KUID/SDC pinned release+commit
for sec in kubenet kuid sdc; do
  block=$(get_block "$sec") || true
  echo "$block" | grep -E "^[[:space:]]*release:[[:space:]]*v?[0-9]+\.[0-9]+\.[0-9]+" >/dev/null || fail "$sec.release missing or not semver"
  # Some nested SDC entries may not have a single top-level commit; allow absence for sdc but enforce for kubenet/kuid
  if [[ "$sec" != "sdc" ]]; then
    echo "$block" | grep -E "^[[:space:]]*commit:[[:space:]]*[0-9a-f]{40}[[:space:]]*$" >/dev/null || fail "$sec.commit must be 40-hex"
  fi
  if [[ "$sec" == "kubenet" ]]; then
    echo "$block" | grep -E '^[[:space:]]*api_shape:[[:space:]]*(NetworkConfig|NetworkDesign)([[:space:]]+#.*)?$' >/dev/null || fail "kubenet.api_shape must be NetworkConfig or NetworkDesign"
  fi
done

# Tooling images must be pinned by digest
get_block tooling | grep -E '@sha256:[0-9a-f]{64}' >/dev/null || fail "tooling images must include @sha256 digests"

# Containerlab version pinned
get_block containerlab | grep -E '^[[:space:]]*version:[[:space:]]*[0-9]+\.[0-9]+\.[0-9]+' >/dev/null || fail "containerlab.version must be semver"

# SONiC images pinned: allow image+separate digest, but require digest present
# Robust YAML scan without relying on regex ranges sensitive to comments
svs_img=$(awk '
  $1=="sonic_images:" {sec=1; next}
  sec && /^[^[:space:]]/ {exit}
  sec && $1=="sonic_vs:" {vs=1; next}
  sec && vs && /^[^[:space:]]/ {vs=0}
  sec && vs && $1=="image:" {print $2; exit}
' "$LOCK_FILE")
svs_dig=$(awk '
  $1=="sonic_images:" {sec=1; next}
  sec && /^[^[:space:]]/ {exit}
  sec && $1=="sonic_vs:" {vs=1; next}
  sec && vs && /^[^[:space:]]/ {vs=0}
  sec && vs && $1=="digest:" {print $2; exit}
' "$LOCK_FILE")
svm_img=$(awk '
  $1=="sonic_images:" {sec=1; next}
  sec && /^[^[:space:]]/ {exit}
  sec && $1=="sonic_vm:" {vm=1; next}
  sec && vm && /^[^[:space:]]/ {vm=0}
  sec && vm && $1=="image:" {print $2; exit}
' "$LOCK_FILE")
svm_dig=$(awk '
  $1=="sonic_images:" {sec=1; next}
  sec && /^[^[:space:]]/ {exit}
  sec && $1=="sonic_vm:" {vm=1; next}
  sec && vm && /^[^[:space:]]/ {vm=0}
  sec && vm && $1=="digest:" {print $2; exit}
' "$LOCK_FILE")

[[ -n "$svs_img" && -n "$svs_dig" ]] || fail "sonic_vs image and digest required"
[[ -n "$svm_img" && -n "$svm_dig" ]] || fail "sonic_vm image and digest required"
[[ "$svs_dig" =~ ^sha256:[0-9a-f]{64}$ ]] || fail "sonic_vs digest must be sha256:..."
[[ "$svm_dig" =~ ^sha256:[0-9a-f]{64}$ ]] || fail "sonic_vm digest must be sha256:..."

svs_full="${svs_img%@*}@${svs_dig}"
svm_full="${svm_img%@*}@${svm_dig}"

# YANG compatibility must include entries for both images and match commit prefixes
# Extract commits by simple grep (robust to comments/indent)
oc_commit=$(grep -E '^[[:space:]]*openconfig_commit:[[:space:]]*[0-9a-f]{40}[[:space:]]*$' "$LOCK_FILE" | head -n1 | sed 's/.*openconfig_commit:[[:space:]]*//')
na_commit=$(grep -E '^[[:space:]]*sonic_native_commit:[[:space:]]*[0-9a-f]{40}[[:space:]]*$' "$LOCK_FILE" | head -n1 | sed 's/.*sonic_native_commit:[[:space:]]*//')
[[ -n "$oc_commit" ]] || fail "openconfig_commit must be 40-hex"
[[ -n "$na_commit" ]] || fail "sonic_native_commit must be 40-hex"

oc_pref=${oc_commit:0:8}
na_pref=${na_commit:0:8}

# Check that compatibility block contains expected images and version prefixes
grep -F "image: ${svs_full}" "$LOCK_FILE" >/dev/null || fail "compatibility missing sonic_vs image ${svs_full}"
grep -F "image: ${svm_full}" "$LOCK_FILE" >/dev/null || fail "compatibility missing sonic_vm image ${svm_full}"
grep -F "oc_version: openconfig@${oc_pref}" "$LOCK_FILE" >/dev/null || fail "compatibility oc_version must match openconfig commit prefix ${oc_pref}"
grep -F "native_version: sonic_yang@${na_pref}" "$LOCK_FILE" >/dev/null || fail "compatibility native_version must match native commit prefix ${na_pref}"

info "versions.lock.yaml pins and compatibility are consistent"
