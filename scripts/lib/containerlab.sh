#!/usr/bin/env bash
# Idempotent containerlab deploy/inspect/destroy helpers (Phase 2)
set -euo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
TOPO_FILE="${ROOT_DIR}/lab/topology.clab.yml"
MGMT_NET="agentic-netops-mgmt"
LABEL_OWNER="agentic-netops"
CLAB_PREFIX="clab-agentic-netops-fabric-"
# containerlab generates a per-lab CA and per-node server certificates here. The
# directory is runtime state (gitignored) and is recreated on every deploy.
CLAB_CA="${ROOT_DIR}/lab/clab-agentic-netops-fabric/.tls/ca/ca.pem"
GNMIC_BIN=${GNMIC_BIN:-gnmic}
GNMI_PORT=${GNMI_PORT:-57400}
# Node name -> management address, mirroring lab/topology.clab.yml.
NODE_IPS=${NODE_IPS:-"spine01=172.31.0.11 spine02=172.31.0.12 leaf01=172.31.0.21 leaf02=172.31.0.22"}
# The SR Linux image default admin password. Read from the environment ONLY; it
# is used exactly once per node, to create the generated user, and is never
# written to a file, a Secret, this tree or a log line (FR-016). It is passed to
# gnmic through GNMIC_PASSWORD rather than -p so it never appears in argv either.
SRL_DEFAULT_USER=${SRLINUX_ADMIN_USER:-admin}
SRL_DEFAULT_PASS=${SRLINUX_ADMIN_PASSWORD:-NokiaSrl1!}

clab::require() { command -v containerlab >/dev/null 2>&1 || { echo "missing containerlab" >&2; exit 1; }; }

clab::deploy() {
  clab::require
  echo "[clab] ensuring external Docker network ${MGMT_NET} exists (subnet-correct)"
  # Delegate to the shared helper so the subnet is always user-configured
  # (172.31.0.0/16), which containerlab requires for explicit per-node mgmt IPs.
  "${ROOT_DIR}/scripts/lib/kind.sh" ensure-mgmt
  echo "[clab] deploying ${TOPO_FILE}"
  # containerlab >=0.7x: --skip-save was removed; --reconfigure regenerates config
  # artifacts AND re-applies each node's startup-config, which is exactly how the
  # underlay/overlay is (re)established. SR Linux is a containerlab-native kind
  # and boots its own init, so nothing has to be kicked after deploy and no
  # post-boot shell hook runs on any node.
  containerlab deploy -t "${TOPO_FILE}" --reconfigure
}

clab::inspect() {
  clab::require
  # containerlab >=0.7x uses -f/--format (not -o) for output format selection
  containerlab inspect -t "${TOPO_FILE}" --format json
}

# gnmic invocation against a node as the image-default admin user. The password
# travels in the environment, never in argv.
clab::_gnmic_admin() {
  local ip=$1; shift
  GNMIC_USERNAME="$SRL_DEFAULT_USER" GNMIC_PASSWORD="$SRL_DEFAULT_PASS" \
    "$GNMIC_BIN" --address "${ip}:${GNMI_PORT}" --timeout 10s \
      --encoding json_ietf --tls-ca "$CLAB_CA" "$@"
}

# gnmic invocation as the lab-generated user (GNMI_USER/GNMI_PASS from
# Secret gnmi-lab-creds, exported by lab_secrets::ensure).
clab::_gnmic_generated() {
  local ip=$1; shift
  GNMIC_USERNAME="${GNMI_USER:-}" GNMIC_PASSWORD="${GNMI_PASS:-}" \
    "$GNMIC_BIN" --address "${ip}:${GNMI_PORT}" --timeout 10s \
      --encoding json_ietf --tls-ca "$CLAB_CA" "$@"
}

# Publish the containerlab CA into Secret gnmi-lab-tls (key ca.crt). Patches the
# existing Secret so the generator's tls.crt/tls.key stay untouched — the SR Linux
# gNMI server needs no client certificate, but the Secret's shape is API for the
# executor and the observability stack.
clab::_publish_ca() {
  local ctx="kind-${AGENTIC_NETOPS_CLUSTER_NAME:-agentic-netops}"
  if [[ ! -s "$CLAB_CA" ]]; then
    echo "[clab] ERROR: containerlab CA not found at ${CLAB_CA}; the lab was never deployed or --reconfigure did not regenerate TLS material" >&2
    return 1
  fi
  command -v kubectl >/dev/null 2>&1 || { echo "[clab] kubectl unavailable; cannot publish the CA" >&2; return 1; }
  local b64
  b64=$(base64 -w0 < "$CLAB_CA")
  if ! kubectl --context "$ctx" -n agentic-netops-system get secret gnmi-lab-tls >/dev/null 2>&1; then
    echo "[clab] ERROR: Secret gnmi-lab-tls absent; the in-cluster secret generator must run before bootstrap" >&2
    return 1
  fi
  kubectl --context "$ctx" -n agentic-netops-system patch secret gnmi-lab-tls \
    --type merge -p "{\"data\":{\"ca.crt\":\"${b64}\"}}" >/dev/null
  echo "[clab] published containerlab CA into Secret gnmi-lab-tls (ca.crt)"
}

# Wait until a node answers gNMI Capabilities. The port accepts connections
# before the management server is serving, so a TCP probe races the boot; assert
# on the reply content instead.
clab::_wait_gnmi() {
  local node=$1 ip=$2 i out
  for i in $(seq 1 90); do
    if out=$(clab::_gnmic_admin "$ip" capabilities 2>&1) && grep -q 'srl_nokia' <<<"$out"; then
      echo "[clab] bootstrap: ${node} answering gNMI Capabilities on ${ip}:${GNMI_PORT}"
      return 0
    fi
    sleep 4
  done
  echo "[clab] ERROR: ${node} (${ip}:${GNMI_PORT}) never answered gNMI Capabilities" >&2
  echo "[clab] last reply: ${out:-<none>}" >&2
  return 1
}

# Create the generated user over gNMI. Idempotent, and the marker is the node's
# own state: if the generated user can already authenticate, there is nothing to
# do. A marker file inside the container would survive a config loss and lie.
clab::_ensure_user() {
  local node=$1 ip=$2
  if clab::_gnmic_generated "$ip" capabilities >/dev/null 2>&1; then
    echo "[clab] bootstrap: ${node} already carries user ${GNMI_USER} (authenticated over gNMI)"
    return 0
  fi
  echo "[clab] bootstrap: ${node} creating generated gNMI user"
  # The value goes through a 0600 temp file rather than --update-value so the
  # generated password never appears in argv.
  local vf
  vf=$(mktemp)
  chmod 600 "$vf"
  # shellcheck disable=SC2064
  trap "rm -f '$vf'" RETURN
  GNMI_PASS_VALUE="$GNMI_PASS" python3 -c 'import json,os,sys; sys.stdout.write(json.dumps({"password": os.environ["GNMI_PASS_VALUE"], "role": ["admin"]}))' > "$vf"
  if ! clab::_gnmic_admin "$ip" set \
        --update-path "/system/aaa/authentication/user[username=${GNMI_USER}]" \
        --update-file "$vf" >/dev/null; then
    echo "[clab] ERROR: ${node} rejected the gNMI Set creating user ${GNMI_USER}" >&2
    return 1
  fi
  # Fail closed: prove the user works before calling the node bootstrapped.
  local i
  for i in 1 2 3 4 5; do
    if clab::_gnmic_generated "$ip" capabilities >/dev/null 2>&1; then
      echo "[clab] bootstrap: ${node} user ${GNMI_USER} created and verified"
      return 0
    fi
    sleep 2
  done
  echo "[clab] ERROR: ${node} accepted the Set but user ${GNMI_USER} cannot authenticate over gNMI" >&2
  return 1
}

# Apply the selected profile's bootstrap to every SR Linux node. The underlay,
# overlay and bootstrap tenants already came up from the per-node startup-config
# (lab/profiles/srlinux/config/*.cfg) applied by containerlab, so bootstrap is
# identity and trust only: wait for gNMI, create the generated user, publish the
# containerlab CA into the gnmi-lab-tls Secret.
clab::bootstrap() {
  local profile=${1:-${AGENTIC_NETOPS_PROFILE:-srlinux}}
  local pdir="${ROOT_DIR}/lab/profiles/${profile}"
  if [[ ! -d "$pdir" ]]; then
    echo "[clab] ERROR: unknown profile ${profile} (no ${pdir})" >&2
    return 1
  fi

  # The CA must reach the cluster Secret before anything materializes ./secrets.
  clab::_publish_ca || return 1

  # Materialize lab TLS + credentials from the in-cluster generator Secrets.
  # Drop any local copy first: containerlab regenerates its CA on every deploy,
  # so a ./secrets/ca.crt left by a previous lab is a DIFFERENT trust anchor and
  # lab_secrets::ensure would happily keep it (it returns early when the file is
  # already there). Every gNMI call afterwards would then fail TLS verification
  # against a freshly deployed fabric.
  rm -f "${ROOT_DIR}/secrets/ca.crt"
  unset GNMI_USER GNMI_PASS
  # shellcheck source=lab_secrets.sh
  source "${ROOT_DIR}/scripts/lib/lab_secrets.sh"
  lab_secrets::ensure "kind-${AGENTIC_NETOPS_CLUSTER_NAME:-agentic-netops}" || return 1
  if [[ -z "${GNMI_USER:-}" || -z "${GNMI_PASS:-}" ]]; then
    echo "[clab] ERROR: no generated gNMI credentials (Secret gnmi-lab-creds); cannot bootstrap" >&2
    return 1
  fi

  local entry node ip rc=0
  for entry in $NODE_IPS; do
    node=${entry%%=*}; ip=${entry#*=}
    local c="${CLAB_PREFIX}${node}"
    if ! docker ps --format '{{.Names}}' | grep -qx "$c"; then
      echo "[clab] ERROR: node container ${c} not running" >&2
      rc=1
      continue
    fi
    clab::_wait_gnmi "$node" "$ip" || { rc=1; continue; }
    clab::_ensure_user "$node" "$ip" || { rc=1; continue; }
    echo "[clab] bootstrap: ${node} done"
  done

  if (( rc != 0 )); then
    echo "[clab] ERROR: bootstrap failed on at least one node; the fabric has no usable gNMI write path" >&2
    return 1
  fi
  echo "[clab] bootstrap complete for profile ${profile}"
}

clab::destroy() {
  clab::require
  echo "[clab] destroying ${TOPO_FILE}"
  containerlab destroy -t "${TOPO_FILE}" --cleanup || true
  # No named volumes to reclaim: SR Linux keeps its configuration in the
  # container filesystem and the startup-config in this tree is the only source
  # of node state, so `containerlab destroy --cleanup` is a complete teardown.
  # Verify teardown leaves no owned lab containers.
  local leftovers
  leftovers=$(docker ps -a --format '{{.Names}} {{.Labels}}' | awk '/agentic-netops.owner=agentic-netops/ {print $1}') || true
  if [[ -n "$leftovers" ]]; then
    echo "[clab] WARN: leftover Agentic NetOps containers not removed:\n$leftovers" >&2
    exit 1
  fi
  # Check for generated lab credentials under repo secrets/
  if [[ -e "${ROOT_DIR}/secrets/tls.key" || -e "${ROOT_DIR}/secrets/tls.crt" || -e "${ROOT_DIR}/secrets/ca.crt" ]]; then
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
