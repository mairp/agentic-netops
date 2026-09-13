#!/usr/bin/env bash
# Verify versions.lock.yaml pins per NFR-003
set -euo pipefail

fail() { echo "[verify-pins] ERROR: $*" >&2; exit 1; }
info() { echo "[verify-pins] $*" >&2; }

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
LOCK_FILE="${ROOT_DIR}/versions.lock.yaml"

[[ -f "$LOCK_FILE" ]] || fail "missing $LOCK_FILE"

# Mode: "all" (default) runs every check; "intent-tier" runs only the feature-002
# intent_tier: digest validation (wired into `make verify-compat`).
MODE="${1:-all}"

# Extract helper: get yaml value block by top-level section name (simple, indentation-based)
get_block() {
  # get_block SECTION_NAME returns block lines until next top-level key (top-level only)
  awk -v sec="$1" '
    $0 ~ "^" sec ":\\s*$" {inside=1; print; next}
    inside && /^[^[:space:]]/ {exit}
    inside {print}
  ' "$LOCK_FILE"
}

# ---------------------------------------------------------------------------
# Feature 002 intent tier (T010-T015): every image under intent_tier: must be
# pinned by immutable digest — tag@sha256:<64-hex> on the image line, a
# matching sha256 digest line per entry, and at least the four tier images
# (python, node, slim, clickhouse) present.
# ---------------------------------------------------------------------------
check_intent_tier() {
  local block n_img n_dig bad bad_digest mism

  block=$(get_block intent_tier)
  [[ -n "$block" ]] || fail "intent_tier section missing from versions.lock.yaml"

  n_img=$(printf '%s\n' "$block" | grep -cE '^[[:space:]]*image:' || true)
  n_dig=$(printf '%s\n' "$block" | grep -cE '^[[:space:]]*digest:' || true)
  [[ "$n_img" -ge 4 ]] || fail "intent_tier must pin at least python, node, slim, and clickhouse images (found $n_img)"
  [[ "$n_img" -eq "$n_dig" ]] || fail "intent_tier: every image entry needs exactly one digest line ($n_img images, $n_dig digests)"

  # Every image line must be <ref>@sha256:<64-hex>
  bad=$(printf '%s\n' "$block" | grep -E '^[[:space:]]*image:' | grep -vE '^[[:space:]]*image:[[:space:]]*[^@[:space:]]+@sha256:[0-9a-f]{64}[[:space:]]*$' || true)
  [[ -z "$bad" ]] || fail "intent_tier image not pinned by digest:
$bad"

  # Every digest line must be sha256:<64-hex>
  bad_digest=$(printf '%s\n' "$block" | grep -E '^[[:space:]]*digest:' | grep -vE '^[[:space:]]*digest:[[:space:]]*sha256:[0-9a-f]{64}[[:space:]]*$' || true)
  [[ -z "$bad_digest" ]] || fail "intent_tier digest malformed (must be sha256:<64-hex>):
$bad_digest"

  # Per entry, the digest recorded on the image line and on the digest line must agree
  mism=$(printf '%s\n' "$block" | awk '
    /^[[:space:]]*image:/ {
      v = $2
      sub(/^[^@]*@/, "", v)
      pending = v
      img = $2
      next
    }
    /^[[:space:]]*digest:/ && pending != "" {
      if ($2 != pending) print "digest mismatch for " img ": image says " pending " but digest line says " $2
      pending = ""
    }
    END { if (pending != "") print "missing digest line after image " img }
  ')
  [[ -z "$mism" ]] || fail "intent_tier image/digest inconsistency:
$mism"

  info "intent_tier: $n_img images all pinned by immutable digest"
}

# ---------------------------------------------------------------------------
# Baseline (feature 001) checks
# ---------------------------------------------------------------------------
check_baseline() {
  # Reject floating refs
  if grep -En '\blatest\b|\bmain\b|\bmaster\b|\bHEAD\b' "$LOCK_FILE" >/dev/null; then
    fail "floating refs found (latest/main/master/HEAD)"
  fi

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
      echo "$block" | grep -E '^[[:space:]]*commit:[[:space:]]*[0-9a-f]{40}[[:space:]]*$' >/dev/null || fail "$sec.commit must be 40-hex"
    fi
    if [[ "$sec" == "kubenet" ]]; then
      echo "$block" | grep -E '^[[:space:]]*api_shape:[[:space:]]*(NetworkConfig|NetworkDesign)([[:space:]]+#.*)?$' >/dev/null || fail "kubenet.api_shape must be NetworkConfig or NetworkDesign"
    fi
  done

  # Tooling images must be pinned by digest
  get_block tooling | grep -E '@sha256:[0-9a-f]{64}' >/dev/null || fail "tooling images must include @sha256 digests"

  # Containerlab version pinned
  get_block containerlab | grep -E '^[[:space:]]*version:[[:space:]]*[0-9]+\.[0-9]+\.[0-9]+' >/dev/null || fail "containerlab.version must be semver"

  # No SONiC pin may survive the migration: the fabric is Nokia SR Linux and the
  # supply-chain policy (scripts/ci/supply_chain.sh) forbids SONiC artifacts in
  # the dependency graph. A leftover key here would re-introduce one silently.
  if grep -nEi 'sonic' "$LOCK_FILE" >/dev/null; then
    fail "SONiC pin(s) still present in versions.lock.yaml:
$(grep -niE 'sonic' "$LOCK_FILE")"
  fi

  # SR Linux image pinned: allow image+separate digest, but require digest present.
  # Robust YAML scan without relying on regex ranges sensitive to comments.
  srl_img=$(awk '
    $1=="srlinux_images:" {sec=1; next}
    sec && /^[^[:space:]]/ {exit}
    sec && $1=="srlinux:" {n=1; next}
    sec && n && /^[^[:space:]]/ {n=0}
    sec && n && $1=="image:" {print $2; exit}
  ' "$LOCK_FILE")
  srl_dig=$(awk '
    $1=="srlinux_images:" {sec=1; next}
    sec && /^[^[:space:]]/ {exit}
    sec && $1=="srlinux:" {n=1; next}
    sec && n && /^[^[:space:]]/ {n=0}
    sec && n && $1=="digest:" {print $2; exit}
  ' "$LOCK_FILE")

  [[ -n "$srl_img" && -n "$srl_dig" ]] || fail "srlinux_images.srlinux image and digest required"
  [[ "$srl_dig" =~ ^sha256:[0-9a-f]{64}$ ]] || fail "srlinux image digest must be sha256:<64-hex>"
  [[ "$srl_img" == ghcr.io/nokia/srlinux:* ]] || fail "srlinux image must come from the public ghcr.io/nokia/srlinux repository (got: $srl_img)"

  srl_full="${srl_img%@*}@${srl_dig}"

  # YANG compatibility must name the pinned image and agree with the model and
  # OpenConfig pins. Extract by simple grep (robust to comments/indent).
  yang_release=$(get_block srlinux_yang | grep -E '^[[:space:]]*release:[[:space:]]*v[0-9]+\.[0-9]+\.[0-9]+[[:space:]]*$' | head -n1 | sed 's/.*release:[[:space:]]*//')
  [[ -n "$yang_release" ]] || fail "srlinux_yang.release must be a v-prefixed semver"
  get_block srlinux_yang | grep -E '^[[:space:]]*model_repo:[[:space:]]*https://github\.com/nokia/srlinux-yang-models[[:space:]]*$' >/dev/null \
    || fail "srlinux_yang.model_repo must be https://github.com/nokia/srlinux-yang-models"

  oc_commit=$(grep -E '^[[:space:]]*openconfig_commit:[[:space:]]*[0-9a-f]{40}[[:space:]]*$' "$LOCK_FILE" | head -n1 | sed 's/.*openconfig_commit:[[:space:]]*//')
  [[ -n "$oc_commit" ]] || fail "openconfig_commit must be 40-hex"
  oc_pref=${oc_commit:0:8}

  grep -F "image: ${srl_full}" "$LOCK_FILE" >/dev/null || fail "srlinux_yang.compatibility missing srlinux image ${srl_full}"
  grep -F "yang_version: srlinux_yang@${yang_release}" "$LOCK_FILE" >/dev/null \
    || fail "compatibility yang_version must match srlinux_yang.release ${yang_release}"
  grep -F "oc_version: openconfig@${oc_pref}" "$LOCK_FILE" >/dev/null \
    || fail "compatibility oc_version must match openconfig commit prefix ${oc_pref}"
}

if [[ "$MODE" == "intent-tier" ]]; then
  check_intent_tier
else
  check_baseline
  check_intent_tier
fi

info "versions.lock.yaml pins and compatibility are consistent"
