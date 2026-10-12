#!/usr/bin/env bash
# T032 — derive the SRv6 capability assertions from the qualification gate
# report (contracts/capability-record.md §2).
#
# `cap-sai-srv6` is "true" if and only if ALL of:
#   1. the gate report for this bring-up has result "pass" — the report path
#      comes from scripts/lib/qualify.sh --print-report-path (never a literal
#      here, so the two cannot drift);
#   2. the checks SRv6-Underlay, End, End.DT46, H.Encaps.Red, SID-list and
#      Decapsulation are status "pass" and none is "skip";
#   3. lab/profiles/<active profile>/srv6-supported.yaml exists and lists at
#      least one variant as "proven".
# Otherwise both keys derive "false". The profile NAME is not an input: it is
# read from AGENTIC_NETOPS_PROFILE (default sonic-vs) at call time.
#
# CAPABILITY_PROFILES_DIR overrides the profiles root (unit-test seam); the
# contract surface (report path + profile name) stays as specified.
CAPABILITY_ROOT=${CAPABILITY_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)}

capability::default_report_path() {
  "$(dirname -- "${BASH_SOURCE[0]}")/qualify.sh" --print-report-path
}

capability::proven_variants() {
  local yaml=$1
  [[ -f "$yaml" ]] || return 0
  awk '
    /^[[:space:]]*-[[:space:]]*name:[[:space:]]*/ {
      if (cur != "" && st == "proven") prov = (prov == "" ? cur : prov "," cur)
      cur = $0
      sub(/^[[:space:]]*-[[:space:]]*name:[[:space:]]*/, "", cur)
      sub(/[[:space:]]+$/, "", cur)
      st = ""
      next
    }
    /^[[:space:]]*status:[[:space:]]*/ { st = $2 }
    END {
      if (cur != "" && st == "proven") prov = (prov == "" ? cur : prov "," cur)
      print prov
    }
  ' "$yaml"
}

capability::report_srw6_ok() {
  local report=$1 c
  [[ -s "$report" ]] || return 1
  command -v jq >/dev/null 2>&1 || return 1
  jq -e 'select(.result == "pass")' "$report" >/dev/null 2>&1 || return 1
  for c in SRv6-Underlay End End.DT46 H.Encaps.Red SID-list Decapsulation; do
    jq -e --arg n "$c" 'any(.tests[]; .name == $n and .status == "pass")' "$report" >/dev/null 2>&1 || return 1
    if jq -e --arg n "$c" 'any(.tests[]; .name == $n and .status == "skip")' "$report" >/dev/null 2>&1; then
      return 1
    fi
  done
  return 0
}

# capability::derive [report_path] — prints
#   cap-sai-srv6=<true|false>
#   srv6-supported=<proven,variants|false>
# The optional report_path exists for tests and re-derivation against a known
# report; production callers must omit it so the path always comes from
# qualify.sh.
capability::derive() {
  local report=${1:-}
  [[ -n "$report" ]] || report=$(capability::default_report_path)
  local profiles=${CAPABILITY_PROFILES_DIR:-${CAPABILITY_ROOT}/lab/profiles}
  local profile=${AGENTIC_NETOPS_PROFILE:-sonic-vs}
  local variants
  variants=$(capability::proven_variants "${profiles}/${profile}/srv6-supported.yaml")
  if [[ -n "$variants" ]] && capability::report_srw6_ok "$report"; then
    printf 'cap-sai-srv6=true\nsrv6-supported=%s\n' "$variants"
  else
    printf 'cap-sai-srv6=false\nsrv6-supported=false\n'
  fi
}
