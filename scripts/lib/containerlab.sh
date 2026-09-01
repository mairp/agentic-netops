#!/usr/bin/env bash
# Idempotent containerlab deploy/inspect/destroy helpers (Phase 2)
set -euo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
TOPO_FILE="${ROOT_DIR}/lab/topology.clab.yml"
MGMT_NET="ainetops-mgmt"
LABEL_OWNER="ainetops"

clab::require() { command -v containerlab >/dev/null 2>&1 || { echo "missing containerlab" >&2; exit 1; }; }

clab::deploy() {
  clab::require
  echo "[clab] ensuring external Docker network ${MGMT_NET} exists (subnet-correct)"
  # Delegate to the shared helper so the subnet is always user-configured
  # (172.31.0.0/16), which containerlab requires for explicit per-node mgmt IPs.
  "${ROOT_DIR}/scripts/lib/kind.sh" ensure-mgmt
  echo "[clab] deploying ${TOPO_FILE}"
  # containerlab >=0.7x: --skip-save was removed; --reconfigure regenerates config artifacts
  containerlab deploy -t "${TOPO_FILE}" --reconfigure
  # containerlab keeps the SONiC nodes (linux kind) at an idle `bash` PID1 —
  # the image's real init (supervisord → start.sh boot chain) never runs on
  # its own (observed 2026-09-01: without this kick every later bootstrap
  # step finds no supervisor and no CONFIG_DB). Idempotent.
  sleep 2
  local node c
  for node in spine01 spine02 leaf01 leaf02; do
    c="clab-ainetops-fabric-${node}"
    docker ps --format '{{.Names}}' | grep -qx "$c" || continue
    docker exec "$c" bash -c 'supervisorctl status >/dev/null 2>&1 || (nohup /usr/local/bin/supervisord -c /etc/supervisor/supervisord.conf >/var/log/supervisord-restart.log 2>&1 &)' || true
  done
}

clab::inspect() {
  clab::require
  # containerlab >=0.7x uses -f/--format (not -o) for output format selection
  containerlab inspect -t "${TOPO_FILE}" --format json
}

# Apply the selected profile's bootstrap to every SONiC node: copy generated
# gNMI TLS material into the node, merge the TELEMETRY config snippet (with the
# runtime-generated credentials) into /etc/sonic/config_db.json, reload, and
# restart the telemetry service. Idempotent per node via a marker file.
clab::bootstrap() {
  local profile=${1:-${AINETOPS_PROFILE:-sonic-vs}}
  local bdir="${ROOT_DIR}/lab/profiles/${profile}/bootstrap"
  if [[ ! -d "$bdir" ]]; then
    echo "[clab] no bootstrap dir for profile ${profile}; nothing to bootstrap" >&2
    return 0
  fi
  # Materialize lab TLS + credentials from the in-cluster generator Secrets
  # shellcheck source=lab_secrets.sh
  source "${ROOT_DIR}/scripts/lib/lab_secrets.sh"
  lab_secrets::ensure "kind-${AINETOPS_CLUSTER_NAME:-ainetops}"

  local node c
  for node in spine01 spine02 leaf01 leaf02; do
    c="clab-ainetops-fabric-${node}"
    if ! docker ps --format '{{.Names}}' | grep -qx "$c"; then
      echo "[clab] bootstrap: node container ${c} not running; skipping" >&2
      continue
    fi
    if docker exec "$c" test -f /etc/ainetops/.bootstrapped 2>/dev/null; then
      echo "[clab] bootstrap: ${node} already bootstrapped (marker present)"
      continue
    fi
    echo "[clab] bootstrap: ${node}"
    docker exec "$c" mkdir -p /etc/ainetops/gnmi /etc/sonic/bootstrap /etc/sonic/telemetry
    docker cp "${ROOT_DIR}/secrets/ca.crt"  "$c:/etc/ainetops/gnmi/ca.crt"
    docker cp "${ROOT_DIR}/secrets/gnmi.crt" "$c:/etc/ainetops/gnmi/gnmi.crt"
    docker cp "${ROOT_DIR}/secrets/gnmi.key" "$c:/etc/ainetops/gnmi/gnmi.key"
    docker cp "$bdir/install-gnmi-certs.sh"  "$c:/etc/sonic/bootstrap/install-gnmi-certs.sh"
    docker cp "$bdir/init-sonic-bootstrap.sh" "$c:/etc/sonic/bootstrap/init-sonic-bootstrap.sh"
    # Inject runtime-generated credentials (not static; generated per lab).
    # IMPORTANT: creds go to a separate file, NOT into gnmi_config_db.json —
    # a TELEMETRY|CLIENTS table in CONFIG_DB breaks GCU whole-config validation
    # (sonic-telemetry YANG models no CLIENTS list: "All Keys are not parsed in
    # TELEMETRY"), which made every config apply-patch fail. sonic-gnmi
    # authenticates via the local user + sshd (see init-sonic-bootstrap.sh 2b),
    # so the CONFIG_DB table was never needed.
    docker cp "$bdir/gnmi_config_db.json" "$c:/etc/sonic/bootstrap/gnmi_config_db.json"
    docker exec "$c" bash -lc "jq -n --arg u '${GNMI_USER}' --arg p '${GNMI_PASS}' '{username:\$u,password:\$p}' > /etc/sonic/bootstrap/gnmi_creds.json"
    # start.sh generates /etc/sonic/config_db.json as the first step of its
    # boot chain; init-sonic-bootstrap merges into that file and would fail
    # (or merge into nothing) if it runs too early. Wait it out (observed
    # 2026-09-01 racing the boot by minutes).
    local wi
    for wi in $(seq 1 60); do
      docker exec "$c" test -s /etc/sonic/config_db.json 2>/dev/null && break
      sleep 5
    done
    if ! docker exec "$c" test -s /etc/sonic/config_db.json; then
      echo "[clab] bootstrap: ${node} config_db.json never appeared; continuing anyway" >&2
    fi
    docker exec "$c" bash -lc "chmod +x /etc/sonic/bootstrap/*.sh && /etc/sonic/bootstrap/init-sonic-bootstrap.sh"
    docker exec "$c" touch /etc/ainetops/.bootstrapped
    echo "[clab] bootstrap: ${node} done"
  done

  # Fabric-wide routing. Deliberately outside the per-node loop and not guarded
  # by the .bootstrapped marker: BGP peers reference each other, so every node
  # must exist first, and the step is idempotent so re-running is safe. Without
  # it the nodes come up with bgpd stopped and no underlay at all, which is what
  # tests/integration/fabric_verify.sh (T043 [US3]) reports.
  if [[ -x "$bdir/configure-fabric-bgp.sh" ]]; then
    echo "[clab] bootstrap: configuring underlay BGP + EVPN across the fabric"
    if ! "$bdir/configure-fabric-bgp.sh"; then
      echo "[clab] WARN: fabric BGP/EVPN configuration reported a problem; fabric_verify.sh has the detail" >&2
    fi
  fi
}

clab::destroy() {
  clab::require
  echo "[clab] destroying ${TOPO_FILE}"
  containerlab destroy -t "${TOPO_FILE}" --cleanup || true
  # Remove the per-node named volumes that persist SONiC /etc/sonic. Containerlab
  # does not always reclaim topology-declared named volumes, so we drop them
  # explicitly by their deterministic names (only the ones this lab owns).
  local v
  for v in ainetops-spine01-etc-sonic ainetops-spine02-etc-sonic ainetops-leaf01-etc-sonic ainetops-leaf02-etc-sonic; do
    docker volume rm "$v" >/dev/null 2>&1 || true
  done
  # Verify teardown leaves no owned lab containers or volumes
  local leftovers
  leftovers=$(docker ps -a --format '{{.Names}} {{.Labels}}' | awk '/ainetops.owner=ainetops/ {print $1}') || true
  if [[ -n "$leftovers" ]]; then
    echo "[clab] WARN: leftover AINETOPS containers not removed:\n$leftovers" >&2
    exit 1
  fi
  # Check for owned volumes (persistent /etc/sonic)
  local vol_left
  vol_left=$(docker volume ls -q | grep -E '^ainetops-.*-etc-sonic$' || true)
  if [[ -n "$vol_left" ]]; then
    echo "[clab] WARN: leftover AINETOPS volumes not removed:\n$vol_left" >&2
    exit 1
  fi
  # Check for generated lab credentials under repo secrets/
  if [[ -e "${ROOT_DIR}/secrets/gnmi.key" || -e "${ROOT_DIR}/secrets/gnmi.crt" || -e "${ROOT_DIR}/secrets/ca.crt" ]]; then
    echo "[clab] WARN: leftover lab-generated gNMI credentials under ${ROOT_DIR}/secrets" >&2
    exit 1
  fi
  echo "[clab] destroy complete"
}

case "${1:-}" in
  deploy) shift; clab::deploy "$@" ;;
  inspect) shift; clab::inspect "$@" ;;
  bootstrap) shift; clab::bootstrap "$@" ;;
  destroy) shift; clab::destroy "$@" ;;
  *) echo "usage: $0 {deploy|inspect|bootstrap|destroy}" >&2; exit 2 ;;
esac
