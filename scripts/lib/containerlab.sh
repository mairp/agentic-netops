#!/usr/bin/env bash
# Idempotent containerlab deploy/inspect/destroy helpers (Phase 2)
set -euo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
MGMT_NET="agentic-netops-mgmt"
LABEL_OWNER="agentic-netops"

# Topology file depends on the active profile: the sonic-vm conformance profile
# deploys full SONiC VMs (containerlab native sonic-vm kind) and must not reuse
# the sonic-vs linux-kind topology. AGENTIC_NETOPS_PROFILE is exported by
# scripts/provision.sh, whose default is sonic-vm (T247); when the variable is
# unset this helper falls back to the same default, so only an explicit
# sonic-vs selects the fast-profile topology (T248).
clab::topo_file() {
  if [[ "${AGENTIC_NETOPS_PROFILE:-sonic-vm}" == "sonic-vs" ]]; then
    echo "${ROOT_DIR}/lab/topology.clab.yml"
  else
    echo "${ROOT_DIR}/lab/topology.sonic-vm.clab.yml"
  fi
}
TOPO_FILE=$(clab::topo_file)

clab::require() { command -v containerlab >/dev/null 2>&1 || { echo "missing containerlab" >&2; exit 1; }; }

clab::deploy() {
  clab::require
  TOPO_FILE=$(clab::topo_file)
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
    c="clab-agentic-netops-fabric-${node}"
    docker ps --format '{{.Names}}' | grep -qx "$c" || continue
    docker exec "$c" bash -c 'supervisorctl status >/dev/null 2>&1 || (nohup /usr/local/bin/supervisord -c /etc/supervisor/supervisord.conf >/var/log/supervisord-restart.log 2>&1 &)' || true
  done
}

clab::inspect() {
  clab::require
  TOPO_FILE=$(clab::topo_file)
  # containerlab >=0.7x uses -f/--format (not -o) for output format selection
  containerlab inspect -t "${TOPO_FILE}" --format json
}

# Apply the selected profile's bootstrap to every SONiC node: copy generated
# gNMI TLS material into the node, merge the TELEMETRY config snippet (with the
# runtime-generated credentials) into /etc/sonic/config_db.json, reload, and
# restart the telemetry service. Idempotent per node via a marker file.
clab::bootstrap() {
  local profile=${1:-${AGENTIC_NETOPS_PROFILE:-sonic-vs}}
  local bdir="${ROOT_DIR}/lab/profiles/${profile}/bootstrap"
  if [[ ! -d "$bdir" ]]; then
    echo "[clab] no bootstrap dir for profile ${profile}; nothing to bootstrap" >&2
    return 0
  fi
  # Materialize lab TLS + credentials from the in-cluster generator Secrets
  # shellcheck source=lab_secrets.sh
  source "${ROOT_DIR}/scripts/lib/lab_secrets.sh"
  lab_secrets::ensure "kind-${AGENTIC_NETOPS_CLUSTER_NAME:-agentic-netops}"

  local node c
  for node in spine01 spine02 leaf01 leaf02; do
    c="clab-agentic-netops-fabric-${node}"
    if ! docker ps --format '{{.Names}}' | grep -qx "$c"; then
      echo "[clab] bootstrap: node container ${c} not running; skipping" >&2
      continue
    fi
    if docker exec "$c" test -f /etc/agentic-netops/.bootstrapped 2>/dev/null; then
      echo "[clab] bootstrap: ${node} already bootstrapped (marker present)"
      continue
    fi
    echo "[clab] bootstrap: ${node}"
    docker exec "$c" mkdir -p /etc/agentic-netops/gnmi /etc/sonic/bootstrap /etc/sonic/telemetry
    docker cp "${ROOT_DIR}/secrets/ca.crt"  "$c:/etc/agentic-netops/gnmi/ca.crt"
    docker cp "${ROOT_DIR}/secrets/gnmi.crt" "$c:/etc/agentic-netops/gnmi/gnmi.crt"
    docker cp "${ROOT_DIR}/secrets/gnmi.key" "$c:/etc/agentic-netops/gnmi/gnmi.key"
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
    # Inject runtime-generated credentials (not static; generated per lab).
    # Generated on the HOST and docker-cp'd: the sonic-vs image ships jq but
    # the vrnetlab sonic-vm launcher does not ("jq: command not found" made
    # the whole bootstrap fail there).
    local creds_tmp
    creds_tmp=$(mktemp)
    jq -n --arg u "${GNMI_USER}" --arg p "${GNMI_PASS}" '{username:$u,password:$p}' > "$creds_tmp"
    docker cp "$creds_tmp" "$c:/etc/sonic/bootstrap/gnmi_creds.json"
    rm -f "$creds_tmp"
    # start.sh generates /etc/sonic/config_db.json as the first step of its
    # boot chain; init-sonic-bootstrap merges into that file and would fail
    # (or merge into nothing) if it runs too early. Wait it out (observed
    # 2026-09-01 racing the boot by minutes).
    #
    # sonic-vm: this wait would burn 5 min per node — the docker-exec target is
    # the vrnetlab QEMU launcher, not the SONiC guest, and never has
    # /etc/sonic/config_db.json. The VM bootstrap waits for guest SSH itself.
    if [[ "$profile" != "sonic-vm" ]]; then
      local wi
      for wi in $(seq 1 60); do
        docker exec "$c" test -s /etc/sonic/config_db.json 2>/dev/null && break
        sleep 5
      done
      if ! docker exec "$c" test -s /etc/sonic/config_db.json; then
        echo "[clab] bootstrap: ${node} config_db.json never appeared; continuing anyway" >&2
      fi
    fi
    docker exec "$c" bash -lc "chmod +x /etc/sonic/bootstrap/*.sh && /etc/sonic/bootstrap/init-sonic-bootstrap.sh"
    # VERIFY the two things gNMI password auth actually needs, and repair them if
    # the bootstrap did not get there. init-sonic-bootstrap.sh runs under
    # `set -euo pipefail`, so ANY earlier failure aborts it silently -- and the two
    # steps at the END are the ones that matter: creating the local gNMI user and
    # having sshd listening (sonic-gnmi authenticates the user through PAM/sshd,
    # not through CONFIG_DB).
    #
    # When that abort happens the failure is invisible and total: no local user
    # exists, so EVERY gNMI request returns "Unauthenticated". Measured 2026-09-03
    # on a fresh lab: the creds file and the k8s Secret agreed exactly
    # (user 75bb9360), the TLS certs were installed, telemetry was listening on
    # :8080 -- and no node had any uid>=1000 user at all. gnmic could not subscribe,
    # Prometheus held only scrape metadata, and every Grafana panel read "No data".
    # The whole observability stack deployed green and showed nothing.
    # For sonic-vm the gNMI user/sshd live in the VM guest (provisioned over
    # SSH by init-sonic-bootstrap.sh); the launcher container has neither, so
    # the repair below would be a no-op at best and misleading at worst.
    if [[ "$profile" != "sonic-vm" ]]; then
    docker exec "$c" bash -lc '
      CREDS=/etc/sonic/bootstrap/gnmi_creds.json
      U=$(jq -r ".username // empty" "$CREDS" 2>/dev/null)
      P=$(jq -r ".password // empty" "$CREDS" 2>/dev/null)
      if [ -n "$U" ] && [ -n "$P" ]; then
        id -u "$U" >/dev/null 2>&1 || useradd -m -s /bin/bash "$U" 2>/dev/null || true
        echo "$U:$P" | chpasswd 2>/dev/null || true
        id -u "$U" >/dev/null 2>&1 || echo "[bootstrap] ERROR: gNMI user $U still missing" >&2
      fi
      if ! (exec 3<>/dev/tcp/127.0.0.1/22) 2>/dev/null; then
        ssh-keygen -A >/dev/null 2>&1 || true; mkdir -p /var/run/sshd
        supervisorctl start sshd >/dev/null 2>&1 || /usr/sbin/sshd >/dev/null 2>&1 || true
      fi
    ' || true
    fi
    docker exec "$c" touch /etc/agentic-netops/.bootstrapped
    echo "[clab] bootstrap: ${node} done"
  done

  # Executor transport key material (T173): the sonic-vm guests must accept
  # the fabric executor's BatchMode SSH before the executor is (re)started
  # with FABRIC_SSH_KEY/FABRIC_SSH_KNOWN_HOSTS by provision.sh. Once per
  # bring-up, fail-closed — a node without the key cannot carry writes and the
  # lab must not be reported ready.
  if [[ "$profile" == "sonic-vm" ]]; then
    if [[ ! -x "$bdir/install-executor-key.sh" ]]; then
      echo "[clab] ERROR: $bdir/install-executor-key.sh missing or not executable" >&2
      return 1
    fi
    echo "[clab] bootstrap: installing the executor SSH key material"
    if ! "$bdir/install-executor-key.sh"; then
      echo "[clab] ERROR: executor key installation failed; the fabric executor transport cannot come up" >&2
      return 1
    fi
  fi

  # Fabric-wide routing. Deliberately outside the per-node loop and not guarded
  # by the .bootstrapped marker: BGP peers reference each other, so every node
  # must exist first, and the step is idempotent so re-running is safe. Without
  # it the nodes come up with bgpd stopped and no underlay at all, which is what
  # tests/integration/fabric_verify.sh (T043 [US3]) reports.
  #
  # sonic-vm (T138): the same responsibility is carried by the profile's
  # configure-fabric.sh (identity -> underlay -> kernel -> locator ->
  # advertisement -> persistence), run from the HOST over SSH into the guests;
  # it does not exist for sonic-vs, whose configure-fabric-bgp.sh below runs
  # inside the containers. Fail closed: a lab without the underlay reports
  # success nowhere.
  if [[ "$profile" == "sonic-vm" ]]; then
    if [[ ! -x "$bdir/configure-fabric.sh" ]]; then
      echo "[clab] ERROR: $bdir/configure-fabric.sh missing or not executable" >&2
      return 1
    fi
    echo "[clab] bootstrap: sonic-vm fabric bootstrap (identity/underlay/kernel/locators/persistence)"
    if ! "$bdir/configure-fabric.sh"; then
      echo "[clab] ERROR: configure-fabric.sh failed; the sonic-vm lab has no underlay — see the FAIL lines above" >&2
      return 1
    fi
  fi

  if [[ -x "$bdir/configure-fabric-bgp.sh" ]]; then
    echo "[clab] bootstrap: configuring underlay BGP + EVPN across the fabric"
    # This used to downgrade a hook failure to a WARN and continue, which made
    # it the single break in the failure chain: configure-fabric-bgp.sh could
    # report a structurally dead overlay (e.g. bgpd never adopting the L2 VNI)
    # and provision.sh:176 would still see success and exit 0. The lab then
    # reached test-fabric with no possible forwarding path, where 100% packet
    # loss was misdiagnosed as slow convergence. Fail closed instead.
    if ! "$bdir/configure-fabric-bgp.sh"; then
      echo "[clab] ERROR: fabric BGP/EVPN configuration failed; the overlay cannot forward — see the [fabric-bgp] ERROR lines above" >&2
      return 1
    fi
  fi
}

clab::destroy() {
  clab::require
  TOPO_FILE=$(clab::topo_file)
  echo "[clab] destroying ${TOPO_FILE}"
  containerlab destroy -t "${TOPO_FILE}" --cleanup || true
  # Remove the per-node named volumes that persist SONiC config. Containerlab
  # does not always reclaim topology-declared named volumes, so we drop them
  # explicitly by their deterministic names (only the ones this lab owns):
  # -etc-sonic for the sonic-vs profile, -vm-config for sonic-vm.
  local v
  for v in agentic-netops-spine01-etc-sonic agentic-netops-spine02-etc-sonic agentic-netops-leaf01-etc-sonic agentic-netops-leaf02-etc-sonic \
           agentic-netops-spine01-vm-config agentic-netops-spine02-vm-config agentic-netops-leaf01-vm-config agentic-netops-leaf02-vm-config; do
    docker volume rm "$v" >/dev/null 2>&1 || true
  done
  # Verify teardown leaves no owned lab containers or volumes
  local leftovers
  leftovers=$(docker ps -a --format '{{.Names}} {{.Labels}}' | awk '/agentic-netops.owner=agentic-netops/ {print $1}') || true
  if [[ -n "$leftovers" ]]; then
    echo "[clab] WARN: leftover Agentic NetOps containers not removed:\n$leftovers" >&2
    exit 1
  fi
  # Check for owned volumes (persistent /etc/sonic)
  local vol_left
  vol_left=$(docker volume ls -q | grep -E '^agentic-netops-.*-(etc-sonic|vm-config)$' || true)
  if [[ -n "$vol_left" ]]; then
    echo "[clab] WARN: leftover Agentic NetOps volumes not removed:\n$vol_left" >&2
    exit 1
  fi
  # Check for generated lab credentials under repo secrets/
  if [[ -e "${ROOT_DIR}/secrets/gnmi.key" || -e "${ROOT_DIR}/secrets/gnmi.crt" || -e "${ROOT_DIR}/secrets/ca.crt" ]]; then
    echo "[clab] WARN: leftover lab-generated gNMI credentials under ${ROOT_DIR}/secrets" >&2
    exit 1
  fi
  # T174: the executor transport material is per-lab (fresh guest host keys
  # every bring-up), so destroy removes it and a leftover must be reported —
  # stale host keys would make every executor SSH fail with a host-key
  # mismatch named after the node.
  local kf
  for kf in fabric-executor.key fabric-executor.key.pub known_hosts_executor; do
    rm -f "${ROOT_DIR}/secrets/${kf}"
  done
  if compgen -G "${ROOT_DIR}/secrets/fabric-executor.*" >/dev/null \
    || [[ -e "${ROOT_DIR}/secrets/known_hosts_executor" ]]; then
    echo "[clab] WARN: leftover executor SSH material under ${ROOT_DIR}/secrets" >&2
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
