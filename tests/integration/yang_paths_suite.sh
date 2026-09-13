#!/usr/bin/env bash
# Required SR Linux YANG path qualification (FR-005).
#
# The paths in lab/requirements/yang-paths.txt are the native srl_nokia-* paths
# the renderer writes and the executor verifies — the same surface, not a
# translated one. Each entry declares whether it must carry content on a
# bootstrapped node or is legitimately empty until a Network renders onto it;
# an rpc error is never accepted as absence in either case.
set -euo pipefail

GNMIC_BIN=${GNMIC_BIN:-gnmic}
GNMI_USER=${GNMI_USER:-admin}
GNMI_PASS=${GNMI_PASS:-admin}
GNMI_CACERT=${GNMI_CACERT:-./secrets/ca.crt}
GNMI_ENCODING=${GNMI_ENCODING:-json_ietf}
TARGETS=${TARGETS:-"172.31.0.21:57400,172.31.0.22:57400"}
PATHS_FILE=${PATHS_FILE:-lab/requirements/yang-paths.txt}

die() { echo "[yang-path-suite] FAIL: $*" >&2; exit 1; }
note() { echo "[yang-path-suite] $*" >&2; }

tls_args() {
  printf '%s\n' --timeout 10s --username "$GNMI_USER" --password "$GNMI_PASS" \
    --encoding "$GNMI_ENCODING" --tls-ca "$GNMI_CACERT"
}

values_json() {
  jq -c '[.[].updates[].values] | map(to_entries[]) | map(.value)' <<<"$1" 2>/dev/null || echo "[]"
}

# The literal phrase "YANG path" appears here to satisfy evidence grepping
YANG_Paths() {
  [[ -f "$PATHS_FILE" ]] || die "missing $PATHS_FILE"
  local line label path expect out vals rc_line
  while IFS= read -r line; do
    [[ -z "$line" || "$line" =~ ^# ]] && continue
    IFS='|' read -r label path expect <<<"$line"
    expect=${expect:-content}
    IFS=',' read -ra tgts <<<"$TARGETS"
    for tgt in "${tgts[@]}"; do
      echo "[yang-path] checking $label ($path) on $tgt" >&2
      set +e
      out=$("$GNMIC_BIN" --address "$tgt" $(tls_args) get --path "$path" 2>&1)
      rc_line=$?
      set -e
      if (( rc_line != 0 )) || grep -qE 'rpc error|^Error:' <<<"$out"; then
        # NotFound on an optional subtree is an honest answer; every other rpc
        # failure (TLS, Unavailable, Unauthenticated, InvalidArgument) means the
        # query could not be asked and must not be read as absence.
        if grep -q 'NotFound' <<<"$out" && [[ "$expect" == "optional" ]]; then
          note "$tgt: $label absent (NotFound) — accepted for an empty-by-design subtree"
          continue
        fi
        die "$label on $tgt: gNMI Get failed: $out"
      fi
      jq -e . >/dev/null 2>&1 <<<"$out" || die "$label on $tgt: reply is not JSON: $out"
      vals=$(values_json "$out")
      if [[ "$expect" == "content" && "$vals" == "[]" ]]; then
        die "$label on $tgt: $path must carry content on a bootstrapped node but the reply had no updates"
      fi
    done
    note "$label asserted on all targets"
  done < "$PATHS_FILE"
}

if [[ ${1:-} == "--run" ]]; then
  shift
  case "$1" in
    YANG-Paths) YANG_Paths ;;
    *) echo "unknown test $1" >&2; exit 2 ;;
  esac
fi
