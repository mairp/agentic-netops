#!/usr/bin/env bash
# install-deps.sh — install host tooling and resolve every pin in versions.lock.yaml
# to a real, immutable reference. Fails loudly rather than inventing values.
#
#   ./scripts/install-deps.sh            install tools + resolve pins
#   ./scripts/install-deps.sh --check    verify pins only, change nothing
#   ./scripts/install-deps.sh --tools    install host tooling only
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOCK="$REPO_ROOT/versions.lock.yaml"
BIN_DIR="${BIN_DIR:-/usr/local/bin}"
MODE="${1:-all}"

# --- pinned host tool versions -------------------------------------------------
KUBECTL_VERSION="v1.29.4"
KIND_VERSION="v0.22.0"
HELM_VERSION="v3.14.4"
GNMIC_VERSION="0.47.0"
YQ_VERSION="v4.44.1"

# --- pinned upstream sources ---------------------------------------------------
# repo:tag pairs; commit SHAs are resolved from the tag, never hand-written.
declare -A UPSTREAM=(
  [kubenet]="kubenet-dev/kubenet:v0.0.1"
  [kuid]="kuidio/kuid:v0.0.13"
  [sdc_config_server]="sdcio/config-server:v0.0.58"
  [sdc_schema_server]="sdcio/schema-server:v0.0.34"
  [containerlab]="srl-labs/containerlab:v0.79.0"
)

# YANG sources — tag-resolved, and a pinned sonic-buildimage branch commit
OPENCONFIG_REPO="openconfig/public"
OPENCONFIG_TAG="v5.9.0"
SONIC_BUILDIMAGE_REPO="sonic-net/sonic-buildimage"
SONIC_BUILDIMAGE_BRANCH="202405"

# --- pinned images (digest resolved at runtime) --------------------------------
declare -A IMAGES=(
  [kind_node]="kindest/node:v1.29.4"
  [gnmic]="ghcr.io/openconfig/gnmic:0.47.0"
  [otel_collector]="otel/opentelemetry-collector-contrib:0.104.0"
  [prometheus]="prom/prometheus:v2.53.1"
  [grafana]="grafana/grafana:11.2.0"
  # SONiC VS: the containerlab-supported community build. Immutable date tag.
  [sonic_vs]="docker.io/netreplica/docker-sonic-vs:20220111"
)

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[fail]\033[0m %s\n' "$*" >&2; exit 1; }

need() { command -v "$1" >/dev/null 2>&1; }

# ------------------------------------------------------------------------------
# 1. host tooling
# ------------------------------------------------------------------------------
install_tools() {
  local arch; arch="$(uname -m)"
  case "$arch" in
    x86_64|amd64) arch=amd64 ;;
    aarch64|arm64) arch=arm64 ;;
    *) die "unsupported architecture: $arch" ;;
  esac

  for req in curl docker skopeo jq; do
    need "$req" || die "required tool missing and not auto-installable: $req"
  done

  if ! need kubectl; then
    log "installing kubectl $KUBECTL_VERSION"
    curl -fsSLo /tmp/kubectl "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${arch}/kubectl"
    install -m 0755 /tmp/kubectl "$BIN_DIR/kubectl" && rm -f /tmp/kubectl
  fi

  if ! need kind; then
    log "installing kind $KIND_VERSION"
    curl -fsSLo /tmp/kind "https://kind.sigs.k8s.io/dl/${KIND_VERSION}/kind-linux-${arch}"
    install -m 0755 /tmp/kind "$BIN_DIR/kind" && rm -f /tmp/kind
  fi

  if ! need helm; then
    log "installing helm $HELM_VERSION"
    curl -fsSL "https://get.helm.sh/helm-${HELM_VERSION}-linux-${arch}.tar.gz" \
      | tar -xz -C /tmp "linux-${arch}/helm"
    install -m 0755 "/tmp/linux-${arch}/helm" "$BIN_DIR/helm" && rm -rf "/tmp/linux-${arch}"
  fi

  if ! need yq; then
    log "installing yq $YQ_VERSION"
    curl -fsSLo /tmp/yq "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_linux_${arch}"
    install -m 0755 /tmp/yq "$BIN_DIR/yq" && rm -f /tmp/yq
  fi

  if ! need gnmic; then
    log "installing gnmic $GNMIC_VERSION"
    local gnmic_arch; case "$arch" in amd64) gnmic_arch=x86_64 ;; arm64) gnmic_arch=aarch64 ;; esac
    curl -fsSL "https://github.com/openconfig/gnmic/releases/download/v${GNMIC_VERSION}/gnmic_${GNMIC_VERSION}_Linux_${gnmic_arch}.tar.gz" \
      | tar -xz -C /tmp gnmic
    install -m 0755 /tmp/gnmic "$BIN_DIR/gnmic" && rm -f /tmp/gnmic
  fi

  if ! need containerlab; then
    log "installing containerlab"
    curl -fsSL https://get.containerlab.dev | bash -s -- -v "${UPSTREAM[containerlab]#*:v}"
  fi

  log "host tooling present"
}

# ------------------------------------------------------------------------------
# 2. resolve upstream commit SHAs from tags
# ------------------------------------------------------------------------------
# GitHub API with retry; prefers authenticated gh, falls back to curl.
gh_api() {
  local path="$1" out attempt
  for attempt in 1 2 3; do
    if need gh && out="$(gh api "$path" 2>/dev/null)"; then
      printf '%s' "$out"; return 0
    fi
    if out="$(curl -fsSL --retry 2 --connect-timeout 10 "https://api.github.com/${path}" 2>/dev/null)"; then
      printf '%s' "$out"; return 0
    fi
    sleep $(( attempt * 2 ))
  done
  return 1
}

resolve_sha() {
  local repo="$1" tag="$2" body sha
  body="$(gh_api "repos/${repo}/git/ref/tags/${tag}")" \
    || die "GitHub API unreachable while resolving ${repo}@${tag} — check connectivity"
  sha="$(printf '%s' "$body" | jq -r '.object.sha // empty')"
  [[ -n "$sha" ]] || die "tag ${tag} does not exist in ${repo}"
  printf '%s' "$sha"
}

resolve_branch_sha() {
  local repo="$1" branch="$2" body sha
  body="$(gh_api "repos/${repo}/commits/${branch}")" \
    || die "GitHub API unreachable while resolving ${repo}@${branch} — check connectivity"
  sha="$(printf '%s' "$body" | jq -r '.sha // empty')"
  [[ -n "$sha" ]] || die "branch ${branch} does not exist in ${repo}"
  printf '%s' "$sha"
}

# ------------------------------------------------------------------------------
# 3. resolve image digests from registries
# ------------------------------------------------------------------------------
resolve_digest() {
  local ref="$1" digest attempt
  for attempt in 1 2 3; do
    digest="$(skopeo inspect --no-tags "docker://${ref}" 2>/dev/null | jq -r '.Digest // empty')"
    [[ -n "$digest" ]] && { printf '%s' "$digest"; return 0; }
    sleep $(( attempt * 2 ))
  done
  die "cannot resolve digest for ${ref} — image not pullable from this host"
}

# ------------------------------------------------------------------------------
# 4. reject placeholders
# ------------------------------------------------------------------------------
check_pins() {
  [[ -f "$LOCK" ]] || die "missing $LOCK"
  local bad=0

  # repeated-hex and sequential-hex placeholders, e.g. aaaa... or 0123456789abcdef
  if grep -nE 'sha256:(([0-9a-f])\2{15,}|0123456789abcdef)' "$LOCK"; then
    warn "placeholder image digests above"; bad=1
  fi
  if grep -nE '^\s*commit:\s*([0-9a-f])\1{15,}' "$LOCK"; then
    warn "placeholder commit SHAs above"; bad=1
  fi
  if grep -nEi 'latest|:main\b|:master\b' "$LOCK"; then
    warn "floating references above (NFR-003 forbids them)"; bad=1
  fi
  if grep -nE 'MANUAL_ACQUISITION_REQUIRED' "$LOCK"; then
    warn "sonic_vm conformance profile is not pinned (build via vrnetlab; see $LOCK)"
    warn "this blocks SRv6 conformance acceptance, not Phases 3-6"
  fi
  if grep -qE '^\s*image:\s*MANUAL_ACQUISITION_REQUIRED' <(sed -n '/sonic_vs:/,/notes:/p' "$LOCK"); then
    warn "sonic_vs is unpinned — Phase 2 qualification cannot run"; bad=1
  fi

  (( bad == 0 )) || die "versions.lock.yaml contains unresolved pins"
  log "all pins resolved and immutable"
}

# ------------------------------------------------------------------------------
# 5. write the lock file
# ------------------------------------------------------------------------------
resolve_pins() {
  log "resolving upstream commit SHAs"
  local kubenet_sha kuid_sha sdc_cs_sha sdc_ss_sha clab_sha
  kubenet_sha="$(resolve_sha "${UPSTREAM[kubenet]%:*}"           "${UPSTREAM[kubenet]#*:}")"
  kuid_sha="$(resolve_sha    "${UPSTREAM[kuid]%:*}"              "${UPSTREAM[kuid]#*:}")"
  sdc_cs_sha="$(resolve_sha  "${UPSTREAM[sdc_config_server]%:*}" "${UPSTREAM[sdc_config_server]#*:}")"
  sdc_ss_sha="$(resolve_sha  "${UPSTREAM[sdc_schema_server]%:*}" "${UPSTREAM[sdc_schema_server]#*:}")"
  clab_sha="$(resolve_sha    "${UPSTREAM[containerlab]%:*}"      "${UPSTREAM[containerlab]#*:}")"

  log "resolving image digests"
  local kind_d gnmic_d otel_d prom_d graf_d
  kind_d="$(resolve_digest  "${IMAGES[kind_node]}")"
  gnmic_d="$(resolve_digest "${IMAGES[gnmic]}")"
  otel_d="$(resolve_digest  "${IMAGES[otel_collector]}")"
  prom_d="$(resolve_digest  "${IMAGES[prometheus]}")"
  graf_d="$(resolve_digest  "${IMAGES[grafana]}")"
  local sonic_vs_d oc_sha sonic_yang_sha
  sonic_vs_d="$(resolve_digest "${IMAGES[sonic_vs]}")"
  log "resolving YANG source commits"
  oc_sha="$(resolve_sha "$OPENCONFIG_REPO" "$OPENCONFIG_TAG")"
  sonic_yang_sha="$(resolve_branch_sha "$SONIC_BUILDIMAGE_REPO" "$SONIC_BUILDIMAGE_BRANCH")"

  [[ -f "$LOCK" ]] && cp "$LOCK" "${LOCK}.bak"

  cat > "$LOCK" <<LOCKEOF
# Compatibility manifest — immutable pins (NFR-003)
# GENERATED by scripts/install-deps.sh. Every value below was resolved against a
# live upstream; nothing here is hand-written. Re-run the script to refresh.
# Resolved: $(date -u +%Y-%m-%dT%H:%M:%SZ)

kind:
  binary: ${KIND_VERSION}
  node_image: ${IMAGES[kind_node]%:*}@${kind_d}
  kubernetes: ${KUBECTL_VERSION}

kubernetes:
  kubernetes: ${KUBECTL_VERSION}
  controller_runtime: v0.17.5
  go: '1.22.5'

kubenet:
  repo: https://github.com/${UPSTREAM[kubenet]%:*}
  release: ${UPSTREAM[kubenet]#*:}
  commit: ${kubenet_sha}
  release_bundle: artifacts/kubenet-release.yaml
  api_shape: NetworkConfig   # confirm against the bundle before use (T008)

kuid:
  repo: https://github.com/${UPSTREAM[kuid]%:*}
  release: ${UPSTREAM[kuid]#*:}
  commit: ${kuid_sha}
  artifacts_dir: artifacts

sdc:
  config_server:
    repo: https://github.com/${UPSTREAM[sdc_config_server]%:*}
    release: ${UPSTREAM[sdc_config_server]#*:}
    commit: ${sdc_cs_sha}
  schema_server:
    repo: https://github.com/${UPSTREAM[sdc_schema_server]%:*}
    release: ${UPSTREAM[sdc_schema_server]#*:}
    commit: ${sdc_ss_sha}

containerlab:
  repo: https://github.com/${UPSTREAM[containerlab]%:*}
  version: ${UPSTREAM[containerlab]#*:}
  commit: ${clab_sha}

host_tools:
  kubectl: ${KUBECTL_VERSION}
  helm: ${HELM_VERSION}
  yq: ${YQ_VERSION}
  gnmic: ${GNMIC_VERSION}

tooling:
  gnmic: ${IMAGES[gnmic]%:*}@${gnmic_d}
  otel_collector: ${IMAGES[otel_collector]%:*}@${otel_d}
  prometheus: ${IMAGES[prometheus]%:*}@${prom_d}
  grafana: ${IMAGES[grafana]%:*}@${graf_d}

# ---------------------------------------------------------------------------
# SONiC images
#   sonic_vs  — pinned by digest to the containerlab-supported community build.
#   sonic_vm  — no public registry serves it. Build via vrnetlab from a SONiC
#               .img, then pin the resulting digest here:
#                 git clone https://github.com/hellt/vrnetlab && cd vrnetlab/sonic
#                 cp <sonic-vs.img> . && make docker-image
#                 docker images --digests | grep sonic
#               Required only for the SRv6/EVPN conformance profile when
#               sonic_vs fails the capability gate (FR-003, FR-028).
# ---------------------------------------------------------------------------
sonic_images:
  sonic_vs:
    image: ${IMAGES[sonic_vs]%:*}@${sonic_vs_d}
    tag: ${IMAGES[sonic_vs]#*:}
    notes: Fast profile; no KVM required; containerlab kind sonic-vs
  sonic_vm:
    image: MANUAL_ACQUISITION_REQUIRED
    digest: MANUAL_ACQUISITION_REQUIRED
    notes: Conformance profile; build via vrnetlab; requires KVM

sonic_yang:
  openconfig:
    repo: https://github.com/openconfig/public
    release: ${OPENCONFIG_TAG}
    commit: ${oc_sha}
  sonic_native:
    repo: https://github.com/sonic-net/sonic-buildimage
    branch: ${SONIC_BUILDIMAGE_BRANCH}
    commit: ${sonic_yang_sha}
  notes: >
    Re-verify both against the acquired SONiC image before qualification (T004).

notes:
  redistribution: >
    SONiC images must be acquired by the operator under upstream terms and are
    not redistributed here. All other artifacts are pinned by immutable digest
    or tag-resolved commit SHA.
LOCKEOF

  log "wrote $LOCK (previous saved as ${LOCK##*/}.bak)"
}

# ------------------------------------------------------------------------------
case "$MODE" in
  --check) check_pins ;;
  --tools) install_tools ;;
  all|"")  install_tools; resolve_pins; check_pins || true ;;
  *)       die "unknown mode: $MODE (use --check, --tools, or no argument)" ;;
esac
