#!/usr/bin/env bash
# srv6_force_clean <container> — remove all SRv6 witness keys directly and save.
# Leftover SRv6 rows wedge GCU whole-config validation (a SID row whose locator
# leafref cannot be resolved makes every patch fail with Data Loading Failed), so
# tests force-clean before writing and guarantee cleanliness after — the assertion
# itself still goes through GCU apply/remove patches.
srv6_force_clean() {
  local c=$1
  docker exec "$c" bash -c 'redis-cli -n 4 --scan --pattern "SRV6_MY_LOCATORS*" | xargs -r redis-cli -n 4 del >/dev/null; redis-cli -n 4 --scan --pattern "SRV6_MY_SIDS*" | xargs -r redis-cli -n 4 del >/dev/null; config save -y >/dev/null 2>&1'
}

# Persistence qualification helper: program a value, restart SONiC containers,
# verify it persists (T014).
#
# Re-expressed per docs/SRV6_GNMI_CAPABILITY_FINDINGS.md §5.1: the gNMI→GCU Set bridge
# is broken in this sonic-gnmi build, so the persisted write is made through GCU
# (the programmable path that provably works) and verified over gNMI — a witness that
# cannot pass vacuously because the reply content, not the exit code, is asserted.
set -euo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
cd "$ROOT_DIR"
TARGETS=${TARGETS:-"172.31.0.21:8080,172.31.0.22:8080"}
GNMIC_BIN=${GNMIC_BIN:-gnmic}
GNMI_USER=${GNMI_USER:-admin}
GNMI_PASS=${GNMI_PASS:-admin}
GNMI_CACERT=${GNMI_CACERT:-./secrets/ca.crt}
GNMI_CERT=${GNMI_CERT:-./secrets/gnmi.crt}
GNMI_KEY=${GNMI_KEY:-./secrets/gnmi.key}
GNMI_ENCODING=${GNMI_ENCODING:-JSON_IETF}
CLAB_PREFIX=${CLAB_PREFIX:-clab-agentic-netops-fabric-}
WITNESS_TAG=${WITNESS_TAG:-$(date +%s)}
LOC_NAME="persist-loc-${WITNESS_TAG}"
LOC_PREFIX="fc00:0:73::"
SID_KEY="${LOC_NAME}|fc00:0:73:1::/64"

die() { echo "[persist] FAIL: $*" >&2; exit 1; }
note() { echo "[persist] $*" >&2; }

tls_args() {
  printf '%s\n' --timeout 5s --username "$GNMI_USER" --password "$GNMI_PASS" \
    --encoding "$GNMI_ENCODING" --tls-ca "$GNMI_CACERT" --tls-cert "$GNMI_CERT" --tls-key "$GNMI_KEY"
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

gcu_apply() {
  local c=$1 patch=$2
  printf '%s' "$patch" | docker exec -i "$c" bash -c 'cat > /tmp/.persist_patch.json && config apply-patch -f CONFIGDB -p /tmp/.persist_patch.json 2>/dev/null >/dev/null'
}

gcu_write() {
  local node=$1
  local patch
  patch=$(python3 - "$LOC_NAME" "$LOC_PREFIX" "$SID_KEY" <<'PY'
import json,sys
loc,pfx,sid=sys.argv[1:4]
print(json.dumps([
 {"op":"add","path":"/SRV6_MY_LOCATORS","value":{loc:{"prefix":pfx}}},
 {"op":"add","path":"/SRV6_MY_SIDS","value":{sid:{"action":"uN"}}}]))
PY
)
  gcu_apply "$node" "$patch" || die "GCU write of persistence witness failed on $node"
  # Persist to /etc/sonic/config_db.json: start.sh reloads CONFIG_DB from the file
  # on every boot (configdb-load.sh), so a redis-only write would be lost — the
  # persisted file is exactly what T014 is about ("Ensure /etc/sonic persists").
  docker exec "$node" bash -c 'config save -y >/dev/null 2>&1' || die "config save failed on $node"
}

gcu_delete() {
  local node=$1
  # Whole-table removal: GCU cannot address keys containing "/" (findings §4.1)
  local patch='[
  {"op":"remove","path":"/SRV6_MY_SIDS"},
  {"op":"remove","path":"/SRV6_MY_LOCATORS"}
]'
  gcu_apply "$node" "$patch" || note "cleanup patch failed on $node (leftover ${LOC_NAME} tolerable)"
  docker exec "$node" bash -c 'config save -y >/dev/null 2>&1' || true
}

gnmi_get() {
  local t=$1
  "$GNMIC_BIN" --address "$t" $(tls_args) get --path /SRV6_MY_SIDS --target CONFIG_DB 2>&1
}

assert_witness_readable() {
  local label=$1 t=$2
  local out vals
  out=$(gnmi_get "$t")
  vals=$(values_json "$out")
  [[ "$vals" != "[]" ]] || die "$label $t: SRV6_MY_SIDS reply has no updates"
  grep -q "$LOC_NAME" <<<"$vals" || die "$label $t: witness $LOC_NAME not in gNMI reply"
  grep -q '"action":"uN"' <<<"$vals" || die "$label $t: witness SID lost action uN"
}

# Wait until gNMI serves real content: the port can accept connections before
# configdb-load.sh has finished reloading CONFIG_DB at boot, and a TCP-only
# check races that window (observed 2026-08-31 as empty Get replies).
wait_for_gnmi() {
  local t=$1 i
  for i in $(seq 1 90); do
    if out=$(gnmi_get "$t") && [[ "$(values_json "$out")" != "[]" ]]; then
      return 0
    fi
    sleep 2
  done
  return 1
}

# restart the SONiC fabric stack inside the containerlab containers.
# A plain `docker restart` is NOT usable here: it recreates the container
# network namespace and containerlab's veth links are NOT re-attached (the
# node comes back with only lo+eth0, start.sh exits 1 on missing ports and
# the whole fabric is gone — observed 2026-09-01). Restarting supervisord
# instead exercises the same persistence surface (configdb-load from the
# saved /etc/sonic/config_db.json, manager daemons, agentic-netops-fabric-init
# boot hook, durable /etc/frr/bgpd.conf) while keeping the network namespace
# and topology links intact.
restart_sonic_containers() {
  local ids; ids=$(docker ps -q --filter "name=${CLAB_PREFIX}") || true
  if [[ -z "$ids" ]]; then echo "[persist] no Agentic NetOps fabric containers found" >&2; return 1; fi
  local c
  # stop supervisord cleanly inside every node: all programs (redis, swss,
  # bgpd, telemetry) go down — this is the destructive part of the restart.
  # Wait for the old process to fully release its HTTP socket before any
  # re-kick: a new supervisord started while the old one still holds the port
  # dies instantly with "Another program is already listening" (observed
  # 2026-09-01), leaving the node with no supervisor at all.
  for c in $(docker ps -q --filter "name=${CLAB_PREFIX}"); do
    docker exec "$c" bash -c 'supervisorctl shutdown >/dev/null 2>&1 || true; for i in $(seq 1 30); do pgrep -x supervisord >/dev/null 2>&1 || break; sleep 1; done; pgrep -x supervisord >/dev/null 2>&1 && pkill -x supervisord; sleep 2' || true
  done
  # bring supervisord back: start.sh re-runs (configdb-load + daemons) and the
  # agentic-netops-fabric-init boot hook restores the fabric
  for c in $(docker ps -q --filter "name=${CLAB_PREFIX}"); do
    docker exec "$c" bash -c 'supervisorctl status >/dev/null 2>&1 || (nohup /usr/local/bin/supervisord -c /etc/supervisor/supervisord.conf >/var/log/supervisord-restart.log 2>&1 &)' || true
    # sshd: sonic-gnmi's user_auth path (UserPwAuth) dials 127.0.0.1:22; sshd is
    # started once by the bootstrap and is not a supervisord program, so a restart
    # silently breaks gNMI auth (every RPC then returns Unauthenticated)
    docker exec "$c" bash -c 'pgrep -x sshd >/dev/null 2>&1 || /usr/sbin/sshd' || true
  done
}

main() {
  # shellcheck source=lab_secrets.sh
  source "${ROOT_DIR}/scripts/lib/lab_secrets.sh"
  lab_secrets::ensure "kind-${AGENTIC_NETOPS_CLUSTER_NAME:-agentic-netops}" || die "could not materialize lab credentials/TLS"

  IFS=',' read -ra tgts <<<"$TARGETS"
  echo "[persist] writing SRv6 witness (${LOC_NAME}) via GCU on all targets"
  for t in "${tgts[@]}"; do
    local node
    node=$(node_for_ip "${t%%:*}")
    [[ -n "$node" ]] || die "cannot resolve containerlab node for $t"
    srv6_force_clean "$node"
    gcu_write "$node"
  done

  echo "[persist] pre-restart read-back over gNMI"
  for t in "${tgts[@]}"; do assert_witness_readable "pre-restart" "$t"; done

  echo "[persist] restarting SONiC containers"
  restart_sonic_containers

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
  for t in "${tgts[@]}"; do
    local node
    node=$(node_for_ip "${t%%:*}") || true
    [[ -n "$node" ]] && gcu_delete "$node" || true
  done
  echo "[persist] persistence verified"
}

if [[ ${1:-} == "--run" ]]; then
  shift
  main "$@"
fi
