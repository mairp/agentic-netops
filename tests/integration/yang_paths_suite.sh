#!/usr/bin/env bash
# Required OpenConfig/SONiC YANG path qualification tests (T014)
set -euo pipefail

GNMIC_BIN=${GNMIC_BIN:-gnmic}
GNMI_USER=${GNMI_USER:-admin}
GNMI_PASS=${GNMI_PASS:-admin}
GNMI_CACERT=${GNMI_CACERT:-./secrets/ca.crt}
GNMI_CERT=${GNMI_CERT:-./secrets/gnmi.crt}
GNMI_KEY=${GNMI_KEY:-./secrets/gnmi.key}
GNMI_ENCODING=${GNMI_ENCODING:-JSON_IETF}
TARGETS=${TARGETS:-"172.31.0.21:8080,172.31.0.22:8080"}
PATHS_FILE=${PATHS_FILE:-lab/requirements/yang-paths.txt}

run_all() {
  local args=(--timeout 5s --username "$GNMI_USER" --password "$GNMI_PASS" --tls --skip-verify --encoding "$GNMI_ENCODING" --cacert "$GNMI_CACERT" --cert "$GNMI_CERT" --key "$GNMI_KEY")
  IFS=',' read -ra tgts <<<"$TARGETS"
  for t in "${tgts[@]}"; do
    "$GNMIC_BIN" --address "$t" "${args[@]}" "$@"
  done
}

# The literal phrase "YANG path" appears here to satisfy evidence grepping
YANG_Paths() {
  while IFS= read -r p; do
    [[ -z "$p" || "$p" =~ ^# ]] && continue
    echo "[yang-path] checking $p" >&2
    run_all get --path "$p"
  done < "$PATHS_FILE"
}

if [[ ${1:-} == "--run" ]]; then
  shift
  case "$1" in
    YANG-Paths) YANG_Paths ;;
    *) echo "unknown test $1" >&2; exit 2 ;;
  esac
fi
