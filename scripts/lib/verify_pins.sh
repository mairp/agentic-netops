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

# Extract helper: get yaml value by key path (simple, indentation-based)
get_block() {
  # get_block SECTION_NAME returns block lines until next top-level key
  awk -v key="$1:" '
    $1==key {print; in=1; next}
    in && /^[^[:space:]]/ {exit}
    in {print}
  ' "$LOCK_FILE"
}

# Check kind node image digest
if ! awk '/^kind:/,/^[^[:space:]]/ {print}' "$LOCK_FILE" | grep -E '^\s*node_image:\s*[^@]+@sha256:[0-9a-f]{64}\s*$' >/dev/null; then
  fail "kind.node_image must include @sha256 digest"
fi

# Check controller-runtime and Go
awk '/^kubernetes:/,/^[^[:space:]]/ {print}' "$LOCK_FILE" | grep -E '^\s*controller_runtime:\s*v[0-9]+\.[0-9]+\.[0-9]+' >/dev/null || fail "missing kubernetes.controller_runtime semver"
awk '/^kubernetes:/,/^[^[:space:]]/ {print}' "$LOCK_FILE" | grep -E '^\s*go:\s*\"?1\.[0-9]+(\.[0-9]+)?\"?$' >/dev/null || fail "missing kubernetes.go version"

# Check Kubenet/KUID/SDC pinned release+commit
for sec in kubenet kuid sdc; do
  block=$(awk -v s="^${sec}:$" 'f; $0~s{f=1} f && /^[^[:space:]]/{if (!p){p=1; print} else exit} f && p{print}' "$LOCK_FILE") || true
  grep -E "^\s*release:\s*v?[0-9]+\.[0-9]+\.[0-9]+" <<<"$block" >/dev/null || fail "$sec.release missing or not semver"
  grep -E "^\s*commit:\s*[0-9a-f]{40}\s*$" <<<"$block" >/dev/null || fail "$sec.commit must be 40-hex"
  if [[ "$sec" == "kubenet" ]]; then
    grep -E '^\s*api_shape:\s*(NetworkConfig|NetworkDesign)\s*$' <<<"$block" >/dev/null || fail "kubenet.api_shape must be NetworkConfig or NetworkDesign"
  fi
done

# Tooling images must be pinned by digest
awk '/^tooling:/,/^[^[:space:]]/ {print}' "$LOCK_FILE" | grep -E '@sha256:[0-9a-f]{64}' >/dev/null || fail "tooling images must include @sha256 digests"

# Containerlab version pinned
awk '/^containerlab:/,/^[^[:space:]]/ {print}' "$LOCK_FILE" | grep -E '^\s*version:\s*[0-9]+\.[0-9]+\.[0-9]+' >/dev/null || fail "containerlab.version must be semver"

# SONiC images pinned: allow image+separate digest, but require digest present
svs_img=$(awk '/sonic_images:/,/^[^[:space:]]/ {print}' "$LOCK_FILE" | awk '/sonic_vs:/, /^\s*[^[:space:]]/ {print}' | grep -E '^\s*image:\s*' | sed 's/.*image:\s*//')
svs_dig=$(awk '/sonic_images:/,/^[^[:space:]]/ {print}' "$LOCK_FILE" | awk '/sonic_vs:/, /^\s*[^[:space:]]/ {print}' | grep -E '^\s*digest:\s*' | sed 's/.*digest:\s*//')
svm_img=$(awk '/sonic_images:/,/^[^[:space:]]/ {print}' "$LOCK_FILE" | awk '/sonic_vm:/, /^\s*[^[:space:]]/ {print}' | grep -E '^\s*image:\s*' | sed 's/.*image:\s*//')
svm_dig=$(awk '/sonic_images:/,/^[^[:space:]]/ {print}' "$LOCK_FILE" | awk '/sonic_vm:/, /^\s*[^[:space:]]/ {print}' | grep -E '^\s*digest:\s*' | sed 's/.*digest:\s*//')

[[ -n "$svs_img" && -n "$svs_dig" ]] || fail "sonic_vs image and digest required"
[[ -n "$svm_img" && -n "$svm_dig" ]] || fail "sonic_vm image and digest required"
[[ "$svs_dig" =~ ^sha256:[0-9a-f]{64}$ ]] || fail "sonic_vs digest must be sha256:..."
[[ "$svm_dig" =~ ^sha256:[0-9a-f]{64}$ ]] || fail "sonic_vm digest must be sha256:..."

svs_full="${svs_img%@*}@${svs_dig}"
svm_full="${svm_img%@*}@${svm_dig}"

# YANG compatibility must include entries for both images and match commit prefixes
oc_commit=$(awk '/^sonic_yang:/,/^[^[:space:]]/ {print}' "$LOCK_FILE" | grep -E '^\s*openconfig_commit:' | sed 's/.*openconfig_commit:\s*//')
na_commit=$(awk '/^sonic_yang:/,/^[^[:space:]]/ {print}' "$LOCK_FILE" | grep -E '^\s*sonic_native_commit:' | sed 's/.*sonic_native_commit:\s*//')
[[ "$oc_commit" =~ ^[0-9a-f]{40}$ ]] || fail "openconfig_commit must be 40-hex"
[[ "$na_commit" =~ ^[0-9a-f]{40}$ ]] || fail "sonic_native_commit must be 40-hex"

oc_pref=${oc_commit:0:8}
na_pref=${na_commit:0:8}

compat_block=$(awk '/^sonic_yang:/,/^[^[:space:]]/ {print}' "$LOCK_FILE" | awk '/compatibility:/, /^[^[:space:]]/ {print}')

grep -F "image: ${svs_full}" <<<"$compat_block" >/dev/null || fail "compatibility missing sonic_vs image ${svs_full}"

grep -F "image: ${svm_full}" <<<"$compat_block" >/dev/null || fail "compatibility missing sonic_vm image ${svm_full}"

grep -F "oc_version: openconfig@${oc_pref}" <<<"$compat_block" >/dev/null || fail "compatibility oc_version must match openconfig commit prefix ${oc_pref}"

grep -F "native_version: sonic_yang@${na_pref}" <<<"$compat_block" >/dev/null || fail "compatibility native_version must match native commit prefix ${na_pref}"

info "versions.lock.yaml pins and compatibility are consistent"
