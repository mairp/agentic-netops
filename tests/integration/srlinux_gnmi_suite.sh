#!/usr/bin/env bash
# SR Linux gNMI qualification suite: Capabilities/Get/Set/Subscribe over TLS with
# JSON_IETF against the native srl_nokia-* models (FR-005, research D8).
#
# Design note (inherited discipline, unchanged): every test asserts the *content*
# of the reply, never just a zero exit code. A gNMI Get that answers with an empty
# body must never read as a pass. The Set test is a write -> read-back -> delete
# witness on a leaf that is unset in the lab's startup-config
# (/system/information/contact), so it cannot pass vacuously and it leaves the
# node exactly as it found it.
#
# Unlike the previous fabric, the write path under test IS the production write
# path: the fabric-executor issues the same gNMI Set against the same endpoint.
# There is no container exec, no CLI scraping and no database side door here.
set -euo pipefail

GNMIC_BIN=${GNMIC_BIN:-gnmic}
GNMI_USER=${GNMI_USER:-admin}
GNMI_PASS=${GNMI_PASS:-admin}
GNMI_CACERT=${GNMI_CACERT:-./secrets/ca.crt}
GNMI_ENCODING=${GNMI_ENCODING:-json_ietf}
TARGETS=${TARGETS:-"172.31.0.21:57400,172.31.0.22:57400"}
CLAB_PREFIX=${CLAB_PREFIX:-clab-agentic-netops-fabric-}
# Unique witness value so repeated runs never collide with leftover state
WITNESS_TAG=${WITNESS_TAG:-$(date +%s)}
WITNESS_PATH="/system/information/contact"
WITNESS_VALUE="agentic-netops-gate-${WITNESS_TAG}"
SUB_IF=${SUB_IF:-ethernet-1/1}

die() { echo "[gnmi-suite] FAIL: $*" >&2; exit 1; }
note() { echo "[gnmi-suite] $*" >&2; }

# TLS args identical for every gnmic invocation. No client certificate: the
# SR Linux gNMI server authenticates username/password over a server-authenticated
# TLS channel, so ca.crt is the whole client-side trust story.
tls_args() {
  printf '%s\n' --timeout 10s --username "$GNMI_USER" --password "$GNMI_PASS" \
    --encoding "$GNMI_ENCODING" --tls-ca "$GNMI_CACERT"
}

# gnmi_get <target> <path> — capture a Get reply (JSON), stderr folded in so an
# rpc error is visible to the caller instead of vanishing.
gnmi_get() {
  local t=$1 path=$2
  "$GNMIC_BIN" --address "$t" $(tls_args) get --path "$path" 2>&1
}

# values_json <get-output> — concatenated values of all updates, or [] when the
# reply carried none (or was not JSON at all).
values_json() {
  jq -c '[.[].updates[].values] | map(to_entries[]) | map(.value)' <<<"$1" 2>/dev/null || echo "[]"
}

assert_values_nonempty() {
  local label=$1 out=$2
  [[ "$(values_json "$out")" != "[]" ]] || die "$label: gNMI Get returned no updates (vacuous reply): $out"
}

# --- Capabilities -------------------------------------------------------------
# Assert the model list really carries the SR Linux native models and that a gNMI
# version is advertised. A bare exit code would pass against any gRPC server.
capabilities() {
  local out
  IFS=',' read -ra tgts <<<"$TARGETS"
  for t in "${tgts[@]}"; do
    out=$("$GNMIC_BIN" --address "$t" $(tls_args) capabilities 2>&1) \
      || die "$t: Capabilities RPC failed: $out"
    grep -q 'srl_nokia-system' <<<"$out" || die "$t: Capabilities does not advertise srl_nokia-system"
    grep -q 'srl_nokia-interfaces' <<<"$out" || die "$t: Capabilities does not advertise srl_nokia-interfaces"
    grep -q 'srl_nokia-network-instance' <<<"$out" || die "$t: Capabilities does not advertise srl_nokia-network-instance"
    grep -qi 'JSON_IETF' <<<"$out" || die "$t: Capabilities does not advertise the JSON_IETF encoding"
    grep -qE '0\.[0-9]+\.[0-9]+' <<<"$out" || die "$t: Capabilities missing gNMI version"
    note "$t: capabilities content asserted (srl_nokia-{system,interfaces,network-instance}, JSON_IETF, gNMI version)"
  done
}

# --- Get ----------------------------------------------------------------------
# /system/information/version must come back with a real version string.
get_version() {
  local out vals
  IFS=',' read -ra tgts <<<"$TARGETS"
  for t in "${tgts[@]}"; do
    out=$(gnmi_get "$t" /system/information/version)
    assert_values_nonempty "Get $t" "$out"
    vals=$(values_json "$out")
    grep -qE 'v?[0-9]+\.[0-9]+\.[0-9]+' <<<"$vals" \
      || die "$t: /system/information/version reply carries no version string: $vals"
    note "$t: Get content asserted (/system/information/version = $(jq -r '.[0] // ""' <<<"$vals"))"
  done
}

# --- Set ----------------------------------------------------------------------
# Write a witness, read it back, delete it, assert it is gone. The leaf is unset
# in the startup-config, so the delete restores the node exactly.
set_witness() {
  local out vals
  IFS=',' read -ra tgts <<<"$TARGETS"
  for t in "${tgts[@]}"; do
    "$GNMIC_BIN" --address "$t" $(tls_args) set \
        --update-path "$WITNESS_PATH" --update-value "$WITNESS_VALUE" >/dev/null 2>&1 \
      || die "Set $t: gNMI Set of the witness at $WITNESS_PATH was rejected"
    out=$(gnmi_get "$t" "$WITNESS_PATH")
    assert_values_nonempty "Set $t (read-back)" "$out"
    vals=$(values_json "$out")
    grep -q "$WITNESS_VALUE" <<<"$vals" \
      || die "$t: witness read-back does not carry $WITNESS_VALUE (got: $vals)"
    "$GNMIC_BIN" --address "$t" $(tls_args) set --delete "$WITNESS_PATH" >/dev/null 2>&1 \
      || die "Set $t: gNMI delete of the witness failed"
    out=$(gnmi_get "$t" "$WITNESS_PATH")
    if grep -q "$WITNESS_VALUE" <<<"$out"; then
      die "$t: witness still present after delete"
    fi
    note "$t: write→read-back→delete witness asserted ($WITNESS_PATH = $WITNESS_VALUE)"
  done
}

# --- Subscribe ----------------------------------------------------------------
# A ONCE subscription must deliver actual counter content and terminate.
subscribe_statistics() {
  local out
  IFS=',' read -ra tgts <<<"$TARGETS"
  for t in "${tgts[@]}"; do
    out=$(timeout 30 "$GNMIC_BIN" --address "$t" $(tls_args) \
      sub --path "/interface[name=${SUB_IF}]/statistics" --mode once 2>&1) \
      || die "$t: ONCE subscription on /interface[name=${SUB_IF}]/statistics failed: $out"
    grep -q 'in-octets' <<<"$out" || die "$t: subscribe reply carries no in-octets counter: $out"
    grep -q 'out-octets' <<<"$out" || die "$t: subscribe reply carries no out-octets counter: $out"
    note "$t: subscribe content asserted (${SUB_IF} statistics delivered)"
  done
}

main() {
  local test=$1
  shift || true
  case "$test" in
    Capabilities) capabilities ;;
    Get) get_version ;;
    Set) set_witness ;;
    Subscribe) subscribe_statistics ;;
    *) echo "unknown test $test" >&2; exit 2 ;;
  esac
}

if [[ ${1:-} == "--run" ]]; then
  shift
  main "$@"
fi
