#!/usr/bin/env bash
# Supply-chain advisory checks for the fully open-source distribution (T074)
# - Dependency licenses: best-effort collection (advisory)
# - Vulnerabilities: run govulncheck when available (advisory)
# - Image provenance: require pinned digests for platform images (enforced)
# - SBOM: run syft when available to generate repository SBOM (advisory)
# - Enforce SR Linux absence from dependency graph/runtime manifests per FR-020 (enforced)
set -euo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
REPORT_DIR="${ROOT_DIR}/.wiggum/features/001-agentic-netops-sonic-evpn-fabric/gates/proofs"
mkdir -p "$REPORT_DIR"

fail=0

log() { echo "[supply-chain] $*" >&2; }

# 1) Enforce SR Linux absence in go dependency graph and manifests (FR-020)
log "Checking SR Linux absence in go.mod/go.sum, Dockerfiles, and Kubernetes manifests"
SR_PAT='\bsr[ -]?linux\b|ghcr\.io/nokia/srlinux|nokia_srlinux'
if command -v rg >/dev/null 2>&1; then
  SR_MATCHES=$(rg -i -n --hidden \
    -g '!**/.git/**' \
    -g '!**/vendor/**' \
    -e "$SR_PAT" \
    go.mod go.sum cmd config deploy || true)
else
  # Fallback to grep when ripgrep is unavailable (CI/minimal envs)
  SR_MATCHES=$(grep -RinE -I \
    --exclude-dir=.git \
    --exclude-dir=vendor \
    -e "$SR_PAT" \
    go.mod go.sum cmd config deploy 2>/dev/null || true)
fi
if [[ -n "$SR_MATCHES" ]]; then
  echo "::error title=SR Linux mention(s) in dependency graph/manifests::${SR_MATCHES}" | tee "$REPORT_DIR/supply-chain.srlinux.matches.txt"
  fail=1
else
  echo "No SR Linux artifacts detected in dependency graph/manifests" | tee "$REPORT_DIR/supply-chain.srlinux.ok.txt"
fi

# 2) Image provenance: require pinned digests for platform images in deploy/**.yaml
log "Verifying platform images are pinned by immutable digests"
if command -v rg >/dev/null 2>&1; then
  IMG_LINES=$(rg -n '^\s*image:\s*[^#]+' deploy || true)
else
  IMG_LINES=$(grep -RinE '^\s*image:\s*[^#]+' deploy 2>/dev/null || true)
fi
MISSING_DIGEST=$(printf "%s" "$IMG_LINES" | awk -F: 'BEGIN{ok=1} {line=$0; if ($0 !~ /@sha256:[0-9a-f]{64}/) {print line; ok=0}} END{exit ok==1 ? 0 : 1}') || {
  echo "::error title=Unpinned images found::The following image lines are not pinned by digest:" | tee "$REPORT_DIR/supply-chain.unpinned-images.txt"
  printf "%s\n" "$IMG_LINES" | awk '$0 !~ /@sha256:[0-9a-f]{64}/' | tee -a "$REPORT_DIR/supply-chain.unpinned-images.txt"
  fail=1
}
# Positive artifact when all images are pinned by digest
if [[ -z "${MISSING_DIGEST:-}" ]]; then
  printf "%s\n" "$IMG_LINES" | tee "$REPORT_DIR/supply-chain.images-pinned.ok.txt" >/dev/null
fi

# 3) Vulnerabilities: govulncheck (advisory)
if command -v govulncheck >/dev/null 2>&1; then
  log "Running govulncheck (advisory)"
  (cd "$ROOT_DIR" && govulncheck ./... || true) | tee "$REPORT_DIR/supply-chain.govulncheck.txt"
else
  log "govulncheck not installed; skipping (advisory)"
fi

# 4) SBOM: syft (advisory)
if command -v syft >/dev/null 2>&1; then
  log "Generating SBOM with syft (advisory)"
  syft packages dir:"$ROOT_DIR" -o json > "$REPORT_DIR/syft.sbom.json" || true
else
  log "syft not installed; skipping SBOM generation (advisory)"
fi

# 5) Licenses: go-licenses (advisory)
if command -v go-licenses >/dev/null 2>&1; then
  log "Collecting dependency licenses with go-licenses (advisory)"
  (cd "$ROOT_DIR" && go-licenses report ./... || true) | tee "$REPORT_DIR/supply-chain.licenses.txt"
else
  log "go-licenses not installed; skipping license report (advisory)"
fi

if [[ "$fail" -ne 0 ]]; then
  log "Supply-chain checks failed"
  exit 1
fi
log "Supply-chain checks passed (enforced: SR Linux absence, image digests; advisory: others)"
