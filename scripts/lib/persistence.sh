#!/usr/bin/env bash
# Persistence qualification helper: restart SONiC containers and verify gNMI-set value persists (T014)
set -euo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
TARGETS=${TARGETS:-"172.31.0.21:8080,172.31.0.22:8080"}
GNMIC_BIN=${GNMIC_BIN:-gnmic}
GNMI_USER=${GNMI_USER:-admin}
GNMI_PASS=${GNMI_PASS:-admin}
GNMI_CACERT=${GNMI_CACERT:-./secrets/ca.crt}
GNMI_CERT=${GNMI_CERT:-./secrets/gnmi.crt}
GNMI_KEY=${GNMI_KEY:-./secrets/gnmi.key}
GNMI_ENCODING=${GNMI_ENCODING:-JSON_IETF}

# read current value for telemetry port via gNMI Get
get_port() {
  local addr=$1
  "$GNMIC_BIN" --address "$addr" --timeout 5s --username "$GNMI_USER" --password "$GNMI_PASS" \
    --tls --skip-verify --encoding "$GNMI_ENCODING" --cacert "$GNMI_CACERT" --cert "$GNMI_CERT" --key "$GNMI_KEY" \
    get --path "/sonic-telemetry:sonic-telemetry/TELEMETRY/SERVER[name=gnmi]/port" -o json | jq -r '..|.val? // empty' | tail -n1
}

# set port to a specific value
set_port() {
  local addr=$1 val=$2
  "$GNMIC_BIN" --address "$addr" --timeout 5s --username "$GNMI_USER" --password "$GNMI_PASS" \
    --tls --skip-verify --encoding "$GNMI_ENCODING" --cacert "$GNMI_CACERT" --cert "$GNMI_CERT" --key "$GNMI_KEY" \
    set --update-path "/sonic-telemetry:sonic-telemetry/TELEMETRY/SERVER[name=gnmi]/port" --update-value "$val"
}

# restart SONiC containers by containerlab label
restart_sonic_containers() {
  # Find containers with ainetops.owner=ainetops and sonic in image or name
  local ids; ids=$(docker ps -q --filter "label=ainetops.owner=ainetops") || true
  if [[ -z "$ids" ]]; then echo "[persist] no AINETOPS containers found" >&2; return 1; fi
  docker restart $ids >/dev/null
}

main() {
  IFS=',' read -ra tgts <<<"$TARGETS"
  # Choose a test value unlikely to be default
  local new_port=${GNMI_PERSIST_TEST_PORT:-8099}
  echo "[persist] setting telemetry port to $new_port on all targets"
  for t in "${tgts[@]}"; do set_port "$t" "$new_port"; done
  echo "[persist] restarting SONiC containers"
  restart_sonic_containers
  echo "[persist] verifying telemetry port persists after restart"
  for t in "${tgts[@]}"; do
    val=$(get_port "$t")
    echo "[persist] $t port=$val"
    [[ "$val" == "$new_port" ]] || { echo "[persist] persistence failed on $t: expected $new_port got $val" >&2; exit 1; }
  done
  echo "[persist] persistence verified"
}

if [[ ${1:-} == "--run" ]]; then
  shift
  main "$@"
fi
