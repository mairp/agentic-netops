#!/usr/bin/env bash
# Persistence qualification helper: program a value over gNMI, save it, restart
# every SR Linux node container, verify the value is still there (FR-005).
#
# Re-expressed for SR Linux: the write goes through the SAME path the
# fabric-executor uses in production — a gNMI Set — followed by the same
# post-apply persist (`/tools/system/configuration/save`). Nothing here reaches
# into the node by another route, so a pass is evidence about the real write
# path and not about a side door.
#
# `docker restart` is usable on this platform. The previous fabric could not be
# restarted that way (the node came back with only lo+eth0 because containerlab's
# veth links were not re-attached and the image's init refused to boot without
# its ports); SR Linux is a containerlab-native kind, so the veth links are
# restored and the node re-reads its saved configuration. That is precisely the
# property under test — see NOTES item on `docker restart` in
# lab/profiles/srlinux/config/NOTES.md.
set -euo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
cd "$ROOT_DIR"
TARGETS=${TARGETS:-"172.31.0.11:57400,172.31.0.12:57400,172.31.0.21:57400,172.31.0.22:57400"}
GNMIC_BIN=${GNMIC_BIN:-gnmic}
GNMI_USER=${GNMI_USER:-admin}
GNMI_PASS=${GNMI_PASS:-admin}
GNMI_CACERT=${GNMI_CACERT:-./secrets/ca.crt}
GNMI_ENCODING=${GNMI_ENCODING:-json_ietf}
CLAB_PREFIX=${CLAB_PREFIX:-clab-agentic-netops-fabric-}
WITNESS_TAG=${WITNESS_TAG:-$(date +%s)}
WITNESS_PATH=${WITNESS_PATH:-/system/information/contact}
WITNESS_VALUE="agentic-netops-persist-${WITNESS_TAG}"
SAVE_PATH=${SAVE_PATH:-/tools/system/configuration/save}

die() { echo "[persist] FAIL: $*" >&2; exit 1; }
note() { echo "[persist] $*" >&2; }

tls_args() {
  printf '%s\n' --timeout 10s --username "$GNMI_USER" --password "$GNMI_PASS" \
    --encoding "$GNMI_ENCODING" --tls-ca "$GNMI_CACERT"
}

values_json() {
  jq -c '[.[].updates[].values] | map(to_entries[]) | map(.value)' <<<"$1" 2>/dev/null || echo "[]"
}

node_for_ip() {
  local ip=$1
  docker ps --format '{{.Names}}' | grep "^${CLAB_PREFIX}" | while read -r c; do
    local i
    i=$(docker inspect "$c" --format '{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}' 2>/dev/null)
    if grep -qw "$ip" <<<"$i"; then echo "$c"; fi
  done | head -n1
}

gnmi_get() {
  local t=$1
  "$GNMIC_BIN" --address "$t" $(tls_args) get --path "$WITNESS_PATH" 2>&1
}

gnmi_write() {
  local t=$1
  "$GNMIC_BIN" --address "$t" $(tls_args) set \
      --update-path "$WITNESS_PATH" --update-value "$WITNESS_VALUE" >/dev/null 2>&1 \
    || die "gNMI Set of the persistence witness failed on $t"
  # Persist: the running configuration must survive the restart, which is the
  # whole point of the test. This is the same save the executor issues after
  # every successful apply sequence (contracts/fabric-executor-api.md).
  "$GNMIC_BIN" --address "$t" $(tls_args) set \
      --update-path "$SAVE_PATH" --update-value '{}' >/dev/null 2>&1 \
    || die "configuration save ($SAVE_PATH) failed on $t"
}

gnmi_delete() {
  local t=$1
  "$GNMIC_BIN" --address "$t" $(tls_args) set --delete "$WITNESS_PATH" >/dev/null 2>&1 \
    || note "cleanup delete failed on $t (leftover witness tolerable)"
  "$GNMIC_BIN" --address "$t" $(tls_args) set \
      --update-path "$SAVE_PATH" --update-value '{}' >/dev/null 2>&1 || true
}

assert_witness_readable() {
  local label=$1 t=$2
  local out vals
  out=$(gnmi_get "$t")
  vals=$(values_json "$out")
  [[ "$vals" != "[]" ]] || die "$label $t: $WITNESS_PATH reply has no updates (got: $out)"
  grep -q "$WITNESS_VALUE" <<<"$vals" || die "$label $t: witness $WITNESS_VALUE not in the gNMI reply (got: $vals)"
}

# Wait until gNMI serves real content again. The port accepts connections before
# the management server is serving, so a TCP-only check races the boot window.
wait_for_gnmi() {
  local t=$1 i out
  for i in $(seq 1 90); do
    if out=$(gnmi_get "$t") && [[ "$(values_json "$out")" != "[]" ]]; then
      return 0
    fi
    sleep 4
  done
  return 1
}

restart_nodes() {
  local ids c
  ids=$(docker ps -q --filter "name=${CLAB_PREFIX}") || true
  if [[ -z "$ids" ]]; then echo "[persist] no Agentic NetOps fabric containers found" >&2; return 1; fi
  for c in $(docker ps --format '{{.Names}}' --filter "name=${CLAB_PREFIX}" | grep -E "${CLAB_PREFIX}(spine|leaf)[0-9]+$"); do
    note "restarting $c"
    docker restart "$c" >/dev/null || die "docker restart failed for $c"
  done
}

main() {
  # shellcheck source=lab_secrets.sh
  source "${ROOT_DIR}/scripts/lib/lab_secrets.sh"
  lab_secrets::ensure "kind-${AGENTIC_NETOPS_CLUSTER_NAME:-agentic-netops}" || die "could not materialize lab credentials/TLS"

  IFS=',' read -ra tgts <<<"$TARGETS"
  echo "[persist] writing witness (${WITNESS_VALUE}) over gNMI and saving on all targets"
  for t in "${tgts[@]}"; do
    gnmi_write "$t"
  done

  echo "[persist] pre-restart read-back over gNMI"
  for t in "${tgts[@]}"; do assert_witness_readable "pre-restart" "$t"; done

  echo "[persist] restarting SR Linux node containers"
  restart_nodes

  echo "[persist] waiting for gNMI to come back"
  for t in "${tgts[@]}"; do
    wait_for_gnmi "$t" || die "gNMI on $t did not come back after restart"
  done

  echo "[persist] post-restart read-back over gNMI"
  for t in "${tgts[@]}"; do
    assert_witness_readable "post-restart" "$t"
    note "$t persistence verified"
  done

  echo "[persist] cleaning up witness"
  for t in "${tgts[@]}"; do gnmi_delete "$t"; done
  echo "[persist] persistence verified"
}

if [[ ${1:-} == "--run" ]]; then
  shift
  main "$@"
fi
