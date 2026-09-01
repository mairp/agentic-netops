#!/usr/bin/env bash
# Central deny-list policy (T074a) used by CI and local runs
# Enforces migration (FR-020), visualization (FR-032), and placement (FR-023) boundaries
# Allowed contexts only: spec.md Scope and interpretation and SC-010; research.md and REVERSE.md citations;
# README presentation-only mention of srl-telemetry-lab. Fails build on any match outside allowed contexts.
set -euo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
cd "$ROOT_DIR"

fail=0

# Helper: filter allowed contexts from search matches (works with rg or grep output)
filter_allowed() {
  local matches="$1"
  # Normalize leading ./ to ease anchored filters
  matches=$(printf "%s" "${matches}" | sed -E 's#^\./##')
  # Allow citations in research.md and REVERSE.md
  matches=$(printf "%s" "${matches}" | neg_filter '^specs/.+/research\.md:' | neg_filter '(^|.*/)REVERSE\.md:' || true)
  # Exclude enforcement/policy sources to avoid self-reference false positives
  matches=$(printf "%s" "${matches}" \
    | neg_filter '^\.github/workflows/denylist\.yml:' \
    | neg_filter '^scripts/ci/denylist_policy\.sh:' \
    | neg_filter '^scripts/ci/supply_chain\.sh:' \
    | neg_filter '^scripts/ci/denylist_runtime_scan\.sh:' \
    | neg_filter '^tests/integration/cycles_runner\.sh:' || true)

  # Allow mentions in spec.md "Scope and interpretation" section and SC-010 success criterion only
  local spec_path="specs/001-ainetops-sonic-evpn-fabric/spec.md"
  if [[ -f "$spec_path" ]]; then
    local start end sc010_start sc010_end
    start=$(awk '/^##\s+Scope and interpretation/{print NR; exit}' "$spec_path" || true)
    end=$(awk 'p && /^##\s+/{print NR; exit} /^##\s+Scope and interpretation/{p=1}' "$spec_path" || true)
    sc010_start=$(awk '/^- \*\*SC-010\*\*/{print NR; exit}' "$spec_path" || true)
    sc010_end=$(awk -v s="$sc010_start" 'NR > s && /^- \*\*SC-/{print NR; exit}' "$spec_path" || true)
    if [[ -z "$sc010_end" ]]; then sc010_end=999999; fi
    if [[ -n "${start}" && -n "${end}" ]]; then
      matches=$(printf "%s" "${matches}" | awk -v s="$start" -v e="$end" -v s2="$sc010_start" -v e2="$sc010_end" -F: '!( $1=="'"$spec_path"'" && ( ($2>=s && $2<=e) || ($2>=s2 && $2<=e2) ) )')
    fi
  fi

  printf "%s" "${matches}"
}

# Prefer ripgrep when present; otherwise fall back to grep -RinE
have_rg=0
if command -v rg >/dev/null 2>&1; then have_rg=1; fi

search_all() {
  local pattern=$1
  # Scan only tracked repository files to avoid session artifacts under .wiggum/**/attempts/**
  # and other untracked logs; this enforces the policy over the source tree.
  if command -v git >/dev/null 2>&1 && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    local files
    # Use nul-delimited to handle spaces; prefer ripgrep when present
    if [[ $have_rg -eq 1 ]]; then
      # Use ripgrep with explicit excludes to avoid vendor/, .wiggum/, and the policy files themselves
      rg -i -n --hidden --no-ignore \
        -g '!*/.git/*' -g '!vendor/**' -g '!.wiggum/**' -g '!scripts/ci/**' \
        -g '!.github/workflows/denylist.yml' -g '!scripts/ci/denylist_policy.sh' \
        -e "$pattern" . || true
    else
      # grep fallback with excludes
      grep -RinE --exclude-dir=.git --exclude-dir=vendor --exclude-dir=.wiggum \
        --exclude='.github/workflows/denylist.yml' --exclude='scripts/ci/denylist_policy.sh' \
        -I "$pattern" . || true
    fi
  else
    # Fallback: whole tree except .git
    if [[ $have_rg -eq 1 ]]; then
      rg -i -n --hidden --no-ignore \
        -g '!*/.git/*' -g '!vendor/**' -g '!.wiggum/**' -g '!scripts/ci/**' \
        -g '!.github/workflows/denylist.yml' -g '!scripts/ci/denylist_policy.sh' \
        -e "$pattern" . || true
    else
      grep -RinE --exclude-dir=.git --exclude-dir=vendor --exclude-dir=.wiggum \
        --exclude='.github/workflows/denylist.yml' --exclude='scripts/ci/denylist_policy.sh' \
        -I "$pattern" . || true
    fi
  fi
}

neg_filter() {
  local pattern=$1
  if [[ $have_rg -eq 1 ]]; then
    rg -v "$pattern"
  else
    grep -vE "$pattern"
  fi
}

# Output path for proofs
PROOFS_DIR="$ROOT_DIR/.wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs"
mkdir -p "$PROOFS_DIR"

{
  echo "::group::Migration boundary terms (FR-020)"
  MIG_PATTERN='\\b(cisco|crosswork|nso|cnc|proprietary\\s+ned|proprietary\\s+neds|ai-network-services-devnet-2606|devnet-2606)\\b'
  MIG_MATCHES=$(search_all "$MIG_PATTERN")
  MIG_VIOLATIONS=$(filter_allowed "$MIG_MATCHES")
  if [[ -n "$MIG_VIOLATIONS" ]]; then
    echo "::error title=Migration boundary term(s) found outside allowed contexts::${MIG_VIOLATIONS}"
    fail=1
  fi
  echo "::endgroup::"

  echo "::group::Visualization boundary terms (FR-032)"
  VIS_PATTERN='\\b(sr[ -]?linux|nokia_srlinux)\\b|ghcr\\.io/nokia/srlinux'
  VIS_MATCHES=$(search_all "$VIS_PATTERN")
  VIS_VIOLATIONS=$(filter_allowed "$VIS_MATCHES")
  if [[ -n "$VIS_VIOLATIONS" ]]; then
    echo "::error title=SR Linux mention(s) found outside allowed contexts::${VIS_VIOLATIONS}"
    fail=1
  fi
  echo "::endgroup::"

  echo "::group::Placement boundary (FR-023): Compose/standalone indicators"
  PL_PATTERN='(docker-compose|docker\\s+compose|compose\\.ya?ml|standalone\\s+container|standalone\\s+deployment)'
  PL_MATCHES=$(search_all "$PL_PATTERN")
  PL_VIOLATIONS=$(filter_allowed "$PL_MATCHES")
  if [[ -n "$PL_VIOLATIONS" ]]; then
    echo "::error title=Disallowed placement mention(s) found outside allowed contexts::${PL_VIOLATIONS}"
    fail=1
  fi
  echo "::endgroup::"

  echo "::group::Visualization reference repository exception (srl-telemetry-lab only in allowed contexts)"
  SRLTL_PATTERN='srl-telemetry-lab'
  SRLTL_MATCHES=$(search_all "$SRLTL_PATTERN" | sed -E 's#^\./##')
  # Allowed contexts: spec.md Scope, SC-010 in spec.md, specs/**/research.md, REVERSE.md, README presentation-only line
  ALLOWED_SPECS_SCOPE=$(awk '/^##\s+Scope and interpretation/{print NR; exit}' specs/001-ainetops-sonic-evpn-fabric/spec.md || true)
  ALLOWED_SPECS_SCOPE_END=$(awk 'p && /^##\s+/{print NR; exit} /^##\s+Scope and interpretation/{p=1}' specs/001-ainetops-sonic-evpn-fabric/spec.md || true)
  ALLOWED_SC010_START=$(awk '/^- \*\*SC-010\*\*/{print NR; exit}' specs/001-ainetops-sonic-evpn-fabric/spec.md || true)
  ALLOWED_SC010_END=$(awk -v s="$ALLOWED_SC010_START" 'NR > s && /^- \*\*SC-/{print NR; exit}' specs/001-ainetops-sonic-evpn-fabric/spec.md || true)
  if [[ -z "$ALLOWED_SC010_END" ]]; then ALLOWED_SC010_END=999999; fi
  SRLTL_VIOLATIONS=$(printf "%s" "${SRLTL_MATCHES}" \
    | awk -F: -v s="$ALLOWED_SPECS_SCOPE" -v e="$ALLOWED_SPECS_SCOPE_END" -v s2="$ALLOWED_SC010_START" -v e2="$ALLOWED_SC010_END" '!( $1 ~ /^specs\/001-ainetops-sonic-evpn-fabric\/spec.md$/ && ( ($2>=s && $2<=e) || ($2>=s2 && $2<=e2) ) )' \
    | neg_filter '^specs/.+/research\.md:' \
    | neg_filter '(^|.*/)REVERSE\.md:' \
    | neg_filter '^README\.md:.*visualization/presentation reference only' \
    | neg_filter '^\.github/workflows/denylist\.yml:' \
    | neg_filter '^scripts/ci/denylist_policy\.sh:' \
    | neg_filter '^scripts/ci/denylist_runtime_scan\.sh:' \
    | neg_filter '^tests/integration/cycles_runner\.sh:' || true)
  if [[ -n "$SRLTL_VIOLATIONS" ]]; then
    echo "::error title=srl-telemetry-lab mention(s) found outside allowed contexts::${SRLTL_VIOLATIONS}"
    fail=1
  fi
  echo "::endgroup::"

  if [[ "$fail" -ne 0 ]]; then
    echo "Deny-list checks failed" >&2
    exit 1
  fi
  echo "All deny-list checks passed"
} 2>&1 | tee "$PROOFS_DIR/denylist.run.log"
