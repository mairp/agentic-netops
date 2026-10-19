#!/usr/bin/env bash
# T031 — unit test for scripts/lib/capability.sh (contracts/capability-record.md §2).
#
# The derivation is `true` ONLY for the all-pass fixture (report result pass,
# every SRv6 check pass with none skipped, and the active profile's
# srv6-supported.yaml listing at least one proven variant). A skipped check,
# a failed check, a missing verdict file, or a profile with no
# srv6-supported.yaml must all derive "false".
#
# Run: bash tests/unit/capability_derive_test.sh
set -uo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
# shellcheck source=scripts/lib/capability.sh
source "${ROOT_DIR}/scripts/lib/capability.sh"

FIXTURES="${ROOT_DIR}/tests/fixtures/qualify"
FAILURES=0

check() {
  local label=$1 fixture=$2 exp_cap=$3 exp_supported=$4
  local out cap supported
  out=$(AGENTIC_NETOPS_PROFILE=testprof CAPABILITY_PROFILES_DIR="${TMP_PROFILES}" capability::derive "${FIXTURES}/${fixture}/qualify.report.json")
  cap=$(sed -n 's/^cap-sai-srv6=//p' <<<"$out")
  supported=$(sed -n 's/^srv6-supported=//p' <<<"$out")
  if [[ "$cap" != "$exp_cap" || "$supported" != "$exp_supported" ]]; then
    echo "FAIL ${label}: expected cap-sai-srv6=${exp_cap} srv6-supported=${exp_supported}, got cap-sai-srv6=${cap:-<unset>} srv6-supported=${supported:-<unset>}" >&2
    FAILURES=$((FAILURES + 1))
  else
    echo "ok   ${label}: cap-sai-srv6=${cap} srv6-supported=${supported}"
  fi
}

# Temp profiles tree: the "testprof" profile declares two proven variants —
# the shape lab/profiles/<profile>/srv6-supported.yaml must have for a "true".
TMP_PROFILES=$(mktemp -d)
mkdir -p "${TMP_PROFILES}/testprof"
cat > "${TMP_PROFILES}/testprof/srv6-supported.yaml" <<'EOF'
variants:
  - name: ip-vrf/vpn
    status: proven
  - name: steering
    status: proven
EOF
trap 'rm -rf "${TMP_PROFILES}"' EXIT

check "all-pass + proven variants" all-pass true "ip-vrf/vpn,steering"
check "one-skip is not proven"     one-skip false false
check "one-fail is not proven"     one-fail false false
check "missing verdict file"       no-verdict false false

# Sonic-vs-shaped case: nothing proven because no srv6-supported.yaml exists
# (US7 scenario 4) — bare profile dir, no yaml at all.
EMPTY_PROFILES=$(mktemp -d)
mkdir -p "${EMPTY_PROFILES}/bare"
out=$(AGENTIC_NETOPS_PROFILE=bare CAPABILITY_PROFILES_DIR="${EMPTY_PROFILES}" capability::derive "${FIXTURES}/all-pass/qualify.report.json")
cap=$(sed -n 's/^cap-sai-srv6=//p' <<<"$out")
supported=$(sed -n 's/^srv6-supported=//p' <<<"$out")
if [[ "$cap" != "false" || "$supported" != "false" ]]; then
  echo "FAIL no-yaml profile: expected false/false, got cap=${cap:-<unset>} supported=${supported:-<unset>}" >&2
  FAILURES=$((FAILURES + 1))
else
  echo "ok   no-yaml profile: cap-sai-srv6=false srv6-supported=false"
fi
rm -rf "${EMPTY_PROFILES}"

# The default report path must come from qualify.sh, never a literal.
if [[ "$(capability::default_report_path)" != "$(bash "${ROOT_DIR}/scripts/lib/qualify.sh" --print-report-path)" ]]; then
  echo "FAIL: default report path diverges from qualify.sh --print-report-path" >&2
  FAILURES=$((FAILURES + 1))
else
  echo "ok   default report path matches qualify.sh --print-report-path"
fi

if (( FAILURES != 0 )); then
  echo "capability_derive_test: ${FAILURES} failure(s)" >&2
  exit 1
fi
echo "capability_derive_test: all green"
