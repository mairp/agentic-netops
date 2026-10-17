#!/usr/bin/env bash
set -euo pipefail

# Agentic NetOps SONiC EVPN/VXLAN Fabric — provision script (Phase 8)
# Sole implementation of environment creation/convergence per contracts/crd-api.md
# Ordered workflow: preflight → network → Kind → containerlab → in-cluster apps → SDC/fabric intent
# → generated topology assets → SRv6 service → readiness

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
REPO_ROOT=$(cd -- "${SCRIPT_DIR}/.." && pwd)
LIB_DIR="${SCRIPT_DIR}/lib"

# Defaults (overridable by flags)
AGENTIC_NETOPS_CLUSTER_NAME=${AGENTIC_NETOPS_CLUSTER_NAME:-agentic-netops}
# T247 (FR-007 flip): sonic-vm is the default profile — the SONiC VM lab carries
# today's services (phase 004). sonic-vs stays available as the explicit fast
# container profile: --profile sonic-vs (or AGENTIC_NETOPS_PROFILE=sonic-vs).
AGENTIC_NETOPS_PROFILE=${AGENTIC_NETOPS_PROFILE:-sonic-vm}
AGENTIC_NETOPS_TIMEOUT=${AGENTIC_NETOPS_TIMEOUT:-180s}

usage() {
  cat <<EOF
Usage: $0 [--profile sonic-vm|sonic-vs] [--cluster-name NAME] [--timeout DURATION] [--with-intent-tier]

Flags:
  --profile           SONiC lab profile. Default: sonic-vm — four SONiC VM
                      guests under containerlab (conformance; the profile the
                      capability gate qualifies and the default bring-up uses).
                      sonic-vs is the explicit fast container profile
                      (no KVM; use it when the sonic-vm guest image is absent).
  --cluster-name      Kind cluster name (default: agentic-netops)
  --timeout           Rollout wait timeout (default: 180s)
  --with-intent-tier  Also install the AGNTCY intent tier (supervisor +
                      mapper/allocator/deployer over SLIM) after the control
                      plane readiness waits (T185/T186). LLM provider settings
                      are read from .env at the repo root (copy .env.example;
                      LLM_MODEL plus the provider's own key variables).
EOF
}

# Flags
WITH_INTENT_TIER=${AGENTIC_NETOPS_WITH_INTENT_TIER:-false}

# Parse flags
while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile) shift; AGENTIC_NETOPS_PROFILE=${1:-$AGENTIC_NETOPS_PROFILE} ;;
    --cluster-name) shift; AGENTIC_NETOPS_CLUSTER_NAME=${1:-$AGENTIC_NETOPS_CLUSTER_NAME} ;;
    --timeout) shift; AGENTIC_NETOPS_TIMEOUT=${1:-$AGENTIC_NETOPS_TIMEOUT} ;;
    --with-intent-tier) WITH_INTENT_TIER=true ;;
    -h|--help) usage; exit 0 ;;
    *) echo "[provision] unknown flag: $1" >&2; usage; exit 2 ;;
  esac
  shift || true
done
export AGENTIC_NETOPS_CLUSTER_NAME AGENTIC_NETOPS_PROFILE AGENTIC_NETOPS_TIMEOUT
# Export the parsed WITH_INTENT_TIER for preflight headroom checks (Phase 10)
export AGENTIC_NETOPS_WITH_INTENT_TIER="$WITH_INTENT_TIER"

# shellcheck source=./lib/preflight.sh
if [[ -f "${LIB_DIR}/preflight.sh" ]]; then
  # Preflight validates versions.lock.yaml, host resources, privileges, MTU, address overlaps, KVM (when sonic-vm)
  source "${LIB_DIR}/preflight.sh"
  preflight::run
fi

# Ordered phases: verify pins and CRDs/register
if [[ -f "${REPO_ROOT}/Makefile" ]]; then
  make -C "${REPO_ROOT}" verify-compat
fi

# Ensure external management network exists, labeled, and subnet-correct (idempotent).
# The subnet MUST be user-configured (172.31.0.0/16) so containerlab can assign the
# explicit per-node mgmt IPs; see scripts/lib/kind.sh kind::ensure_mgmt_network.
if command -v docker >/dev/null 2>&1 && [[ -x "${LIB_DIR}/kind.sh" ]]; then
  "${LIB_DIR}/kind.sh" ensure-mgmt
fi

# Ensure Kind cluster exists and is using pinned image; attach nodes to mgmt network
if [[ -x "${LIB_DIR}/kind.sh" ]]; then
  "${LIB_DIR}/kind.sh" ensure
  "${LIB_DIR}/kind.sh" attach-mgmt
  "${LIB_DIR}/kind.sh" verify-context
else
  echo "[provision] WARN: kind helper not found; skipping Kind cluster ensure" >&2
fi

# T023/T598 (FR-009): the sonic-vm topology names its image by TAG because
# containerlab cannot resolve a local image by digest without a registry
# (proof p1-image-by-digest: clab normalizes name@sha256:<digest> to a
# registry reference and pulls). So the sonic-vm bring-up asserts, BEFORE
# deploy, that the tagged image's ID equals the digest pinned in
# versions.lock.yaml (sonic_vm, one image@sha256:<digest> line) and fails
# otherwise — the tag is the known exception, the digest is still the pin.
if [[ "${AGENTIC_NETOPS_PROFILE}" == "sonic-vm" ]]; then
  pinned_svm=$(awk '
    $1=="sonic_images:" {sec=1; next}
    sec && /^[^[:space:]]/ {exit}
    sec && $1=="sonic_vm:" {vm=1; next}
    sec && vm && /^[^[:space:]]/ {vm=0}
    sec && vm && $1=="image:" {print $2; exit}
  ' "${REPO_ROOT}/versions.lock.yaml")
  if [[ ! "$pinned_svm" =~ ^local/sonic-vm@sha256:[0-9a-f]{64}$ ]]; then
    echo "[provision] versions.lock.yaml sonic_vm must pin one line local/sonic-vm@sha256:<digest>; got: ${pinned_svm:-<missing>}" >&2
    exit 1
  fi
  pinned_svm_digest=${pinned_svm##*@}
  live_svm_id=$(docker image inspect local/sonic-vm:202505 --format '{{.Id}}' 2>/dev/null || true)
  if [[ -z "$live_svm_id" ]]; then
    echo "[provision] local image local/sonic-vm:202505 not found; build it per lab/profiles/sonic-vm/README.md before provisioning this profile" >&2
    exit 1
  fi
  if [[ "$live_svm_id" != "$pinned_svm_digest" ]]; then
    echo "[provision] local/sonic-vm:202505 image ID ${live_svm_id} != pinned ${pinned_svm_digest} (versions.lock.yaml sonic_vm); refusing to bring up the sonic-vm lab against an unpinned image" >&2
    exit 1
  fi
  echo "[provision] sonic-vm image pin verified: local/sonic-vm:202505 == ${pinned_svm}"
  echo "[provision] WARN: known exception to the one-form image rule: lab/topology.sonic-vm.clab.yml names the image by TAG (local/sonic-vm:202505) because containerlab cannot resolve a local image by digest without a registry (proof p1-image-by-digest); asserted this bring-up against ${pinned_svm}" >&2
fi

# Deploy lab topology with containerlab
if [[ -x "${LIB_DIR}/containerlab.sh" ]]; then
  "${LIB_DIR}/containerlab.sh" deploy || { echo "[provision] containerlab deploy failed" >&2; exit 1; }
  "${LIB_DIR}/containerlab.sh" inspect || true
else
  echo "[provision] WARN: containerlab helper not found; skipping lab deploy" >&2
fi

# Install least-privilege RBAC base
if [[ -x "${LIB_DIR}/rbac.sh" ]]; then
  "${LIB_DIR}/rbac.sh"
fi
# Install pinned Kubenet/KUID and SDC into Kind and wait basic readiness
if [[ -x "${REPO_ROOT}/deploy/kubenet/install.sh" ]]; then
  "${REPO_ROOT}/deploy/kubenet/install.sh"
fi
if [[ -x "${REPO_ROOT}/deploy/sdc/install.sh" ]]; then
  "${REPO_ROOT}/deploy/sdc/install.sh"
fi
# Install observability stack (OTel Collector, gNMIc, Prometheus, Grafana)
# Preload pinned observability images from the local Docker cache into Kind so
# digest-pinned pod specs do not depend on a live registry pull at rollout time.
if command -v docker >/dev/null 2>&1 && command -v kind >/dev/null 2>&1 && [[ -f versions.lock.yaml ]]; then
  echo "[provision] preloading pinned observability images into Kind"
  for img in $(awk '/^tooling:/{f=1;next} f && /^[^ ]/{f=0} f && /: .*@sha256:/{print $2}' versions.lock.yaml); do
    if docker image inspect "$img" >/dev/null 2>&1; then
      cache="agentic-netops-cache$(echo "$img" | tr '/@:' '----')"
      docker tag "$img" "$cache" 2>/dev/null || true
      kind load docker-image "$cache" --name "${AGENTIC_NETOPS_CLUSTER_NAME}" >/dev/null 2>&1 \
        && echo "[provision] preloaded $img" || echo "[provision] WARN: preload failed for $img" >&2
      docker rmi "$cache" >/dev/null 2>&1 || true
    else
      echo "[provision] WARN: pinned image not in local cache: $img" >&2
    fi
  done
fi
if [[ -x "${LIB_DIR}/observability.sh" ]]; then
  "${LIB_DIR}/observability.sh" install || true
fi

# Build, load, and deploy provider, srv6-controller, and fabric-executor images
# into Kind (T041). The controller images are static distroless-style binaries:
# build them on the host from the pinned, vendored Go source (go.mod + vendor/)
# and import them as scratch images. This keeps the lifecycle reproducible
# without pulling a build base image from an external registry (air-gapped
# qualified host friendly).
if command -v docker >/dev/null 2>&1 && command -v kind >/dev/null 2>&1 && command -v kubectl >/dev/null 2>&1 && command -v go >/dev/null 2>&1; then
  echo "[provision] building controller binaries (pinned vendored Go source)"
  ( cd "${REPO_ROOT}" && CGO_ENABLED=0 GOOS=linux GOARCH=amd64 \
      go build -mod=vendor -tags agentic_netops_k8s -trimpath -ldflags='-s -w' \
      -o /tmp/agentic-netops-sonic-provider-bin ./cmd/sonic-provider )
  ( cd "${REPO_ROOT}" && CGO_ENABLED=0 GOOS=linux GOARCH=amd64 \
      go build -mod=vendor -tags agentic_netops_k8s -trimpath -ldflags='-s -w' \
      -o /tmp/agentic-netops-srv6-controller-bin ./cmd/srv6-controller )
  ( cd "${REPO_ROOT}" && CGO_ENABLED=0 GOOS=linux GOARCH=amd64 \
      go build -mod=vendor -tags agentic_netops_k8s -trimpath -ldflags='-s -w' \
      -o /tmp/agentic-netops-fabric-executor-bin ./cmd/fabric-executor )
  ( cd /tmp && tar -cf agentic-netops-sonic-provider-bin.tar agentic-netops-sonic-provider-bin \
      && docker import --change 'USER 65532:65532' --change 'ENTRYPOINT ["/agentic-netops-sonic-provider-bin"]' agentic-netops-sonic-provider-bin.tar agentic-netops-sonic-provider:dev )
  ( cd /tmp && tar -cf agentic-netops-srv6-controller-bin.tar agentic-netops-srv6-controller-bin \
      && docker import --change 'USER 65532:65532' --change 'ENTRYPOINT ["/agentic-netops-srv6-controller-bin"]' agentic-netops-srv6-controller-bin.tar agentic-netops-srv6-controller:dev )
  # The executor execs into the sonic-vs containers through the host docker
  # socket; it runs as a HOST service (see below), not as a pod — kind nodes
  # cannot share the host's docker socket, and the pod route would require
  # exposing a docker API over TCP. Building it here keeps the binary fresh;
  # the host runner section below owns its lifecycle.
  ( cd "${REPO_ROOT}" && CGO_ENABLED=0 GOOS=linux GOARCH=amd64 \
      go build -mod=vendor -tags agentic_netops_k8s -trimpath -ldflags='-s -w' \
      -o /tmp/agentic-netops-fabric-executor-bin ./cmd/fabric-executor )
  ( cd /tmp && tar -cf agentic-netops-sonic-provider-bin.tar agentic-netops-sonic-provider-bin \
      && docker import --change 'USER 65532:65532' --change 'ENTRYPOINT ["/agentic-netops-sonic-provider-bin"]' agentic-netops-sonic-provider-bin.tar agentic-netops-sonic-provider:dev )
  ( cd /tmp && tar -cf agentic-netops-srv6-controller-bin.tar agentic-netops-srv6-controller-bin \
      && docker import --change 'USER 65532:65532' --change 'ENTRYPOINT ["/agentic-netops-srv6-controller-bin"]' agentic-netops-srv6-controller-bin.tar agentic-netops-srv6-controller:dev )
  echo "[provision] loading images into Kind"
  kind load docker-image agentic-netops-sonic-provider:dev --name "${AGENTIC_NETOPS_CLUSTER_NAME}" || true
  kind load docker-image agentic-netops-srv6-controller:dev --name "${AGENTIC_NETOPS_CLUSTER_NAME}" || true
  echo "[provision] deploying controllers"
  kubectl --context "kind-${AGENTIC_NETOPS_CLUSTER_NAME}" -n agentic-netops-system apply -f "${REPO_ROOT}/deploy/agentic-netops/manifests/provider.yaml"
  # The provider's port map is profile data (T187): inject it from the active
  # profile's port-map.json, replacing whatever the manifest carries, so the
  # provider env always matches the profile.
  PROVIDER_PORT_MAP_FILE="${REPO_ROOT}/lab/profiles/${AGENTIC_NETOPS_PROFILE}/port-map.json"
  if [[ -f "$PROVIDER_PORT_MAP_FILE" ]] && command -v python3 >/dev/null 2>&1; then
    PROVIDER_PORT_MAP=$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); d.pop("_comment", None); print(json.dumps(d, sort_keys=True, separators=(",", ":")))' "$PROVIDER_PORT_MAP_FILE")
    kubectl --context "kind-${AGENTIC_NETOPS_CLUSTER_NAME}" -n agentic-netops-system set env deploy/agentic-netops-sonic-provider "FABRIC_PORT_MAP=${PROVIDER_PORT_MAP}" >/dev/null
  else
    echo "[provision] WARN: ${PROVIDER_PORT_MAP_FILE} missing — provider port map not set from profile" >&2
  fi
  # The node kind is profile data too (T192): the provider renders plans for
  # the guests it actually faces, per kind (p4-*-trial evidence).
  kubectl --context "kind-${AGENTIC_NETOPS_CLUSTER_NAME}" -n agentic-netops-system set env deploy/agentic-netops-sonic-provider "FABRIC_NODE_KIND=${AGENTIC_NETOPS_PROFILE}" >/dev/null
  kubectl --context "kind-${AGENTIC_NETOPS_CLUSTER_NAME}" -n agentic-netops-system apply -f "${REPO_ROOT}/deploy/agentic-netops/manifests/srv6-controller.yaml"
  # The SRv6 controller consumes the same profile data the provider does
  # (T399): the logical->kernel port map for attachment validation and the
  # node kind the plans render for. Injected, never baked into the manifest.
  if [[ -f "$PROVIDER_PORT_MAP_FILE" ]] && command -v python3 >/dev/null 2>&1; then
    kubectl --context "kind-${AGENTIC_NETOPS_CLUSTER_NAME}" -n agentic-netops-system set env deploy/agentic-netops-srv6-controller "FABRIC_PORT_MAP=${PROVIDER_PORT_MAP}" >/dev/null
  else
    echo "[provision] WARN: ${PROVIDER_PORT_MAP_FILE} missing — srv6-controller port map not set from profile" >&2
  fi
  kubectl --context "kind-${AGENTIC_NETOPS_CLUSTER_NAME}" -n agentic-netops-system set env deploy/agentic-netops-srv6-controller "FABRIC_NODE_KIND=${AGENTIC_NETOPS_PROFILE}" >/dev/null
  kubectl --context "kind-${AGENTIC_NETOPS_CLUSTER_NAME}" -n agentic-netops-system set image deploy/agentic-netops-sonic-provider provider=agentic-netops-sonic-provider:dev || true
  kubectl --context "kind-${AGENTIC_NETOPS_CLUSTER_NAME}" -n agentic-netops-system set image deploy/agentic-netops-srv6-controller srv6-controller=agentic-netops-srv6-controller:dev || true
  # Both images ride the SAME :dev tag across rebuilds, so "set image" is a
  # no-op whenever the tag string is unchanged — the deployment keeps the OLD
  # pod and the stale binary (verified 2026-10-16: a re-provision loaded a new
  # image ID while the 39h-old pod kept running, and the bring-up sample never
  # reached Ready). rollout restart always mints a new ReplicaSet, and the
  # fresh pod resolves the tag to the just-loaded image.
  kubectl --context "kind-${AGENTIC_NETOPS_CLUSTER_NAME}" -n agentic-netops-system rollout restart deploy/agentic-netops-sonic-provider deploy/agentic-netops-srv6-controller
  echo "[provision] waiting for controller pods ready (timeout=${AGENTIC_NETOPS_TIMEOUT})"
  kubectl --context "kind-${AGENTIC_NETOPS_CLUSTER_NAME}" -n agentic-netops-system rollout status deploy/agentic-netops-sonic-provider --timeout="${AGENTIC_NETOPS_TIMEOUT}"
  kubectl --context "kind-${AGENTIC_NETOPS_CLUSTER_NAME}" -n agentic-netops-system rollout status deploy/agentic-netops-srv6-controller --timeout="${AGENTIC_NETOPS_TIMEOUT}"
  # Capture independent observation proof
  mkdir -p "${REPO_ROOT}/.wiggum/features/001-agentic-netops-sonic-evpn-fabric/gates/proofs"
  kubectl --context "kind-${AGENTIC_NETOPS_CLUSTER_NAME}" -n agentic-netops-system get deploy,po,svc -o wide \
    | nl -ba > "${REPO_ROOT}/.wiggum/features/001-agentic-netops-sonic-evpn-fabric/gates/proofs/kubectl-get-agentic-netops-system.txt"
fi

# fabric-executor host service: the southbound write path. It execs fabric
# changes into the sonic-vs containers through the host's docker socket — the
# same vantage point every qualified lab script (lab/profiles/sonic-vs/
# bootstrap/configure-fabric-bgp.sh) writes from — and serves the SONiC
# provider pods on the kind bridge gateway so the cluster's only fabric
# control route stays inside the system tier's netpol envelope. kind nodes
# cannot mount the host docker socket, so a pod deployment would force a
# docker-API-over-TCP exposure; the host service keeps the socket unix-only.
if [[ -f /tmp/agentic-netops-fabric-executor-bin ]] && command -v docker >/dev/null 2>&1; then
  KIND_GW=$(docker network inspect kind --format '{{range .IPAM.Config}}{{.Gateway}}
{{end}}' | head -1 | tr -d ' ')
  KIND_GW=${KIND_GW:-172.30.0.1}
  RUN_DIR=/var/local/agentic-netops
  mkdir -p "$RUN_DIR"
  EXECUTOR_CHANGED=1
  if [[ -f "$RUN_DIR/agentic-netops-fabric-executor" ]] && \
     cmp -s /tmp/agentic-netops-fabric-executor-bin "$RUN_DIR/agentic-netops-fabric-executor"; then
    EXECUTOR_CHANGED=0
  fi
  install -m 0755 /tmp/agentic-netops-fabric-executor-bin "$RUN_DIR/agentic-netops-fabric-executor"
  # Transport per node (contracts/executor-transport.md §2, T175). On the
  # sonic-vm profile the fabric nodes are SONiC guests inside launcher
  # containers: docker-exec lands in the launcher, not the guest, so every
  # node uses the executor's ssh transport — keyed by the SAME pinned
  # launcher mgmt addresses install-executor-key.sh wrote into
  # secrets/known_hosts_executor (lab/topology.sonic-vm.clab.yml pins them).
  # site-a/site-b are aliases of leaf01/leaf02 in FABRIC_NODE_MAP and get the
  # same transport (a mapped node absent from the transport map silently
  # falls back to docker). sonic-vs keeps the docker default: empty map.
  FABRIC_NODE_TRANSPORT_JSON=""
  FABRIC_SSH_KEY_PATH=""
  FABRIC_SSH_KNOWN_HOSTS_PATH=""
  if [[ "${AGENTIC_NETOPS_PROFILE}" == "sonic-vm" ]]; then
    SECRETS_DIR="${REPO_ROOT}/secrets"
    FABRIC_SSH_KEY_PATH="${SECRETS_DIR}/fabric-executor.key"
    FABRIC_SSH_KNOWN_HOSTS_PATH="${SECRETS_DIR}/known_hosts_executor"
    # The 0600 material is installed by install-executor-key.sh (T173), which runs
    # from the lab bootstrap AFTER this executor step within one provision run — and
    # a teardown removes the per-lab keys (T174), leaving a fresh run nothing to
    # find: measured 2026-10-15, the chain's final sonic-vm provision exited here
    # because the q3-teardown suite had run containerlab destroy beforehand.
    # Materialize the transport here once (idempotent: skips generation when the
    # keypair exists, rescans host keys, verifies BatchMode SSH per node), then
    # keep the fail-closed 0600 enforcement below unchanged.
    if [[ ! -f "$FABRIC_SSH_KEY_PATH" || ! -f "$FABRIC_SSH_KNOWN_HOSTS_PATH" ]]; then
      EXEC_KEY_SH="${REPO_ROOT}/lab/profiles/sonic-vm/bootstrap/install-executor-key.sh"
      if [[ ! -x "$EXEC_KEY_SH" ]]; then
        echo "[provision] ERROR: $EXEC_KEY_SH missing or not executable; cannot materialize the executor SSH transport" >&2
        exit 1
      fi
      echo "[provision] executor SSH material missing; running install-executor-key.sh (waits for guest SSH)"
      "$EXEC_KEY_SH" || { echo "[provision] ERROR: install-executor-key.sh failed; the executor ssh transport cannot come up" >&2; exit 1; }
    fi
    for f in "$FABRIC_SSH_KEY_PATH" "$FABRIC_SSH_KNOWN_HOSTS_PATH"; do
      if [[ ! -f "$f" || "$(stat -c %a "$f" 2>/dev/null)" != "600" ]]; then
        echo "[provision] ERROR: $f missing or not 0600 — bring the lab up via containerlab.sh first (it runs install-executor-key.sh); the executor's ssh transport refuses wider permissions" >&2
        exit 1
      fi
    done
    declare -A EXEC_ADDR=( [spine01]=172.31.0.11 [spine02]=172.31.0.12 [leaf01]=172.31.0.21 [leaf02]=172.31.0.22 )
    TRANSPORT_ROWS=()
    for n in spine01 spine02 leaf01 leaf02; do
      TRANSPORT_ROWS+=("\"$n\":{\"kind\":\"ssh\",\"addr\":\"${EXEC_ADDR[$n]}\",\"user\":\"admin\"}")
    done
    TRANSPORT_ROWS+=("\"site-a\":{\"kind\":\"ssh\",\"addr\":\"${EXEC_ADDR[leaf01]}\",\"user\":\"admin\"}")
    TRANSPORT_ROWS+=("\"site-b\":{\"kind\":\"ssh\",\"addr\":\"${EXEC_ADDR[leaf02]}\",\"user\":\"admin\"}")
    FABRIC_NODE_TRANSPORT_JSON="{$(IFS=,; echo "${TRANSPORT_ROWS[*]}")}"
  fi
  # Probe hosts (contracts/executor-transport.md §4, T330): the SRv6 client
  # containers of lab/topology.sonic-vm.clab.yml, one per leaf, reachable
  # over their wan1 attachment. The executor refuses a probe-ping naming an
  # attachment absent from this map ("no probe host for <attachment>"), so
  # the map is exactly the set of attachments a first-activation data-path
  # check can be run from — the same set published below as
  # srv6-probe-attachments in fabric-compat-pins (T605, capability-record §1).
  FABRIC_PROBE_MAP='{"leaf01/wan1":"clab-agentic-netops-fabric-srv6-client01","leaf02/wan1":"clab-agentic-netops-fabric-srv6-client02"}'
  # Exported so the compat-pins generation below can publish the same set as
  # srv6-probe-attachments (T605).
  export FABRIC_PROBE_MAP
  # The executor resolves its transport ONCE at start: a still-healthy process
  # from a previous profile would keep the wrong transport. Restart whenever
  # the transport configuration differs from the running one.
  TRANSPORT_STAMP=$(printf '%s' "$FABRIC_NODE_TRANSPORT_JSON|$FABRIC_SSH_KEY_PATH|$FABRIC_SSH_KNOWN_HOSTS_PATH|$FABRIC_PROBE_MAP" | sha256sum | cut -d' ' -f1)
  if [[ "$EXECUTOR_CHANGED" -eq 0 ]] && \
     [[ "$(cat "$RUN_DIR/fabric-executor.transport" 2>/dev/null)" == "$TRANSPORT_STAMP" ]] && \
     curl -fsS --max-time 2 "http://127.0.0.1:8084/healthz" >/dev/null 2>&1; then
    echo "[provision] fabric-executor already healthy on :8084 (node map and transport unchanged)"
  else
    # A healthy process can still execute an older, unlinked inode after
    # `install` replaces the binary. Restart whenever bytes changed. Resolve
    # the actual executable as well as the pidfile because interrupted prior
    # launches can leave the pidfile stale.
    EXECUTOR_PIDS=$(pgrep -f "^$RUN_DIR/agentic-netops-fabric-executor$" 2>/dev/null || true)
    for EXECUTOR_PID in $EXECUTOR_PIDS; do
      kill "$EXECUTOR_PID" 2>/dev/null || true
    done
    [[ -z "$EXECUTOR_PIDS" ]] || sleep 1
    echo "[provision] starting fabric-executor host service on ${KIND_GW}:8084"
    (
      export FABRIC_EXECUTOR_BIND=":8084"
      export FABRIC_NODE_MAP='{"leaf01":"clab-agentic-netops-fabric-leaf01","leaf02":"clab-agentic-netops-fabric-leaf02","spine01":"clab-agentic-netops-fabric-spine01","spine02":"clab-agentic-netops-fabric-spine02","site-a":"clab-agentic-netops-fabric-leaf01","site-b":"clab-agentic-netops-fabric-leaf02"}'
      if [[ -n "$FABRIC_NODE_TRANSPORT_JSON" ]]; then
        export FABRIC_NODE_TRANSPORT="$FABRIC_NODE_TRANSPORT_JSON"
        export FABRIC_SSH_KEY="$FABRIC_SSH_KEY_PATH"
        export FABRIC_SSH_KNOWN_HOSTS="$FABRIC_SSH_KNOWN_HOSTS_PATH"
      fi
      setsid nohup "$RUN_DIR/agentic-netops-fabric-executor" >>"$RUN_DIR/fabric-executor.log" 2>&1 &
      echo $! > "$RUN_DIR/fabric-executor.pid"
    )
    printf '%s\n' "$TRANSPORT_STAMP" > "$RUN_DIR/fabric-executor.transport"
    sleep 1
  fi
  if curl -fsS --max-time 2 "http://127.0.0.1:8084/healthz" >/dev/null 2>&1; then
    echo "[provision] fabric-executor healthy; provider reaches it at http://${KIND_GW}:8084"
  else
    echo "[provision] WARN: fabric-executor not healthy — see $RUN_DIR/fabric-executor.log" >&2
  fi
  # Host INPUT is DROP-by-default; admit the bridge traffic to the executor
  # only (docker bridges, port 8084). Idempotent.
  if command -v iptables >/dev/null 2>&1; then
    iptables -C INPUT -i br-+ -p tcp --dport 8084 -j ACCEPT 2>/dev/null \
      || iptables -I INPUT 1 -i br-+ -p tcp --dport 8084 -j ACCEPT
  fi
fi

# Site compatibility pins: versions.lock.yaml is authoritative for the fabric's
# schema identity, and pkg/compat resolves its defaults from this ConfigMap
# (keys are the agentic-netops.dev/* annotation names the validators read).
# Regenerated on every provision so a versions.lock bump cannot drift from the
# cluster's notion of its own fabric.
if command -v kubectl >/dev/null 2>&1 && [[ -f versions.lock.yaml ]]; then
  CTX="kind-${AGENTIC_NETOPS_CLUSTER_NAME}"
  echo "[provision] generating fabric-compat-pins ConfigMap from versions.lock.yaml"
  python3 - <<'PY' | kubectl --context "$CTX" -n agentic-netops-system apply -f - >/dev/null 2>&1 || echo "[provision] WARN: compat-pins generation failed" >&2
import json
import os
import re

lock = open("versions.lock.yaml").read()

def grab(pattern, default="", flags=0):
    m = re.search(pattern, lock, flags)
    return m.group(1).strip() if m else default

def image_of(entry_name):
    # T024 (FR-009): the sonic-image pin comes from the ACTIVE PROFILE's lock
    # entry (sonic_images.sonic_vm for --profile sonic-vm, sonic_vs otherwise)
    # — never from a sonic-vs-only literal. The entry body is the slice up to
    # the next 2-space key or a column-0 comment, so comments inside the entry
    # and sibling entries cannot confuse it.
    m = re.search(rf"^  {entry_name}:[^\n]*\n(.*?)(?=^  \S|^#|\Z)", lock, re.M | re.S)
    if not m:
        return ""
    im = re.search(r"^    image:\s*(\S+)", m.group(1), re.M)
    return im.group(1) if im else ""

profile = os.environ.get("AGENTIC_NETOPS_PROFILE", "sonic-vs")
# T605 (capability-record §1): srv6-probe-attachments lists the keys of the
# executor's FABRIC_PROBE_MAP set above — the attachments a first-activation
# data-path check can be run from (spec KL-009). Empty when the executor
# never came up (no probe hosts); rule C8 then refuses any SRv6Service whose
# attachments cannot be verified.
probe_map = os.environ.get("FABRIC_PROBE_MAP", "")
try:
    probe_attachments = ",".join(sorted(json.loads(probe_map).keys())) if probe_map else ""
except ValueError:
    probe_attachments = ""
sonic_image = image_of("sonic_vm" if profile == "sonic-vm" else "sonic_vs")
if not sonic_image:
    raise SystemExit(f"versions.lock.yaml sonic_images has no image for profile {profile}")
oc = grab(r"^\s*-\s*image:.*\n\s*oc_version:\s*openconfig@([0-9a-f]+)", "", re.M)
native = grab(r"^\s*-\s*image:.*\n\s*oc_version:.*\n\s*native_version:\s*sonic_yang@([0-9a-f]+)", "", re.M)
kubenet = grab(r"^kubenet:.*?^\s*commit:\s*([0-9a-f]+)", "", re.M | re.S)
kuid = grab(r"^kuid:.*?^\s*commit:\s*([0-9a-f]+)", "", re.M | re.S)
sdc = grab(r"^sdc:.*?^\s*version:\s*(\S+)", "", re.M | re.S)

def shorten(sha, n=8):
    return sha[:n] if sha else ""

cm = {"apiVersion": "v1", "kind": "ConfigMap",
    "metadata": {"name": "fabric-compat-pins", "namespace": "agentic-netops-system",
                 "labels": {"agentic-netops.owner": "agentic-netops"}},
    "data": {
        # ConfigMap keys cannot carry "/", so these are the short forms; the
        # pins loader (pkg/compat/pins.go) maps them to the agentic-netops.dev/*
        # annotation names.
        "sonic-image": sonic_image,
        "openconfig-commit": shorten(oc),
        "sonic-native-commit": shorten(native),
        "mapping-version": "v0.1.0",
        "kubenet-commit": shorten(kubenet),
        "kuid-commit": shorten(kuid),
        "sdc-release": ("v" + sdc) if sdc and not sdc.startswith("v") else sdc,
        "topology-label-contract": "v0.1.0",
        "telemetry-label-contract": "v0.1.0",
        # T025 (FR-007): capability assertions are DERIVED, never guessed.
        # Generation writes the honest default "false"; the post-gate
        # derivation step (scripts/lib/capability.sh, T033) patches the
        # ConfigMap from the qualification gate report and the profile's
        # srv6-supported.yaml. A failed or skipped gate leaves "false".
        "cap-sai-srv6": "false",
        # T605 (capability-record §1, spec KL-009): the keys of the
        # executor's FABRIC_PROBE_MAP — controller rule C8 reads this key to
        # refuse an SRv6Service whose attachments cannot be verified.
        "srv6-probe-attachments": probe_attachments,
        # Informational (T025): which profile this generation served, so a
        # reader of the live ConfigMap can trace the pins back to the lab
        # profile without asking the provisioner.
        "lab-profile": profile,
    }}
print(json.dumps(cm, indent=1))
PY
fi

# Apply SRv6 CRD, default Kubenet Network, tenant examples, and sample SRv6 service
if command -v kubectl >/dev/null 2>&1; then
  CTX="kind-${AGENTIC_NETOPS_CLUSTER_NAME}"
  echo "[provision] applying SRv6Service CRD and Kubenet default/tenant networks"
  kubectl --context "$CTX" apply -f "${REPO_ROOT}/config/crd/bases/agentic-netops.io_srv6services.yaml"
  # Assert CRD set per FR-006 (T079a)
  if [[ -x "${LIB_DIR}/assert_crds.sh" ]]; then "${LIB_DIR}/assert_crds.sh" || { echo "[provision] CRD assertion failed" >&2; exit 1; }; fi
  kubectl --context "$CTX" apply -f "${REPO_ROOT}/deploy/kubenet/topology.yaml"
  kubectl --context "$CTX" apply -f "${REPO_ROOT}/deploy/kubenet/topology-and-indices.yaml"
  kubectl --context "$CTX" apply -f "${REPO_ROOT}/deploy/kubenet/claims.yaml"
  kubectl --context "$CTX" apply -f "${REPO_ROOT}/deploy/kubenet/srv6-pools.yaml"
  kubectl --context "$CTX" apply -f "${REPO_ROOT}/deploy/kubenet/networks/default.yaml"
  kubectl --context "$CTX" apply -f "${REPO_ROOT}/deploy/kubenet/networks/tenants/l2-bridged.yaml"
  kubectl --context "$CTX" apply -f "${REPO_ROOT}/deploy/kubenet/networks/tenants/l3-routed.yaml"
  kubectl --context "$CTX" apply -f "${REPO_ROOT}/deploy/kubenet/networks/tenants/irb-symmetric.yaml"
  # T034: no sample SRv6Service here. Provisioning an SRv6 service is a
  # deliberate, tier-mediated act (refusal R1/R4 semantics, capability gates);
  # an unconditional sample apply would either claim capability this site has
  # not proven or dead-lock the bring-up on a refused Ready condition.
  # Capture independent observation of applied Network resources
  kubectl --context "$CTX" -n kubenet-system get networkconfigs,networks 2>/dev/null | nl -ba > "${REPO_ROOT}/.wiggum/features/001-agentic-netops-sonic-evpn-fabric/gates/proofs/kubectl-get-kubenet-networks.txt" || true
fi

# Seed SDC schema/profile/discovery
if command -v kubectl >/dev/null 2>&1; then
  CTX="kind-${AGENTIC_NETOPS_CLUSTER_NAME}"
  kubectl --context "$CTX" apply -f "${REPO_ROOT}/deploy/sdc/seed/sonic-schema.yaml"
  kubectl --context "$CTX" apply -f "${REPO_ROOT}/deploy/sdc/seed/discovery-rule.yaml"
fi

# T185/T186 — optional AGNTCY intent tier. Install it after the Kubernetes
# control plane and tier-owned dependencies are present, but before the SONiC
# fabric gate. That keeps the operator UI/control tier recoverable even when a
# data-plane overlay race fails closed later in this script.
TIER_FAILED=false
if [[ "$WITH_INTENT_TIER" == "true" ]]; then
  # shellcheck source=./lib/intent_tier.sh
  source "${LIB_DIR}/intent_tier.sh"
  INTENT_TIER_TIMEOUT=${AGENTIC_NETOPS_TIMEOUT}
  if ! intent::install; then
    TIER_FAILED=true
    echo "[provision] WARN: intent tier install failed; continuing to run fabric bootstrap/gate for diagnostics" >&2
  fi
else
  echo "[provision] skipping intent tier (pass --with-intent-tier to install it)"
fi

# Apply the profile bootstrap (gNMI TLS + TELEMETRY config) to the SONiC nodes
# before qualification so the capability gate has a live gNMI endpoint. The
# in-cluster secret generator must already have run (earlier phase).
if [[ -x "${LIB_DIR}/containerlab.sh" ]]; then
  "${LIB_DIR}/containerlab.sh" bootstrap "${AGENTIC_NETOPS_PROFILE}" || { echo "[provision] lab bootstrap failed" >&2; exit 1; }
fi

# Run lab capability qualification; select conformance fallback when sonic-vs fails
if [[ -x "${LIB_DIR}/qualify.sh" ]]; then
  if ! "${LIB_DIR}/qualify.sh"; then
    echo "[provision] capability gate failed for profile ${AGENTIC_NETOPS_PROFILE}" >&2
    if [[ "${AGENTIC_NETOPS_PROFILE}" == "sonic-vs" ]]; then
      # T035: worded to match versions.lock.yaml — sonic_vs is gNMI/SRv6
      # gate-qualified (core capability checks run against its telemetry
      # server); full EVPN/SRv6 conformance runs on sonic_vm.
      echo "[provision] sonic-vs failed the capability gate; per versions.lock.yaml sonic_vs runs the core gNMI gate and full EVPN/SRv6 conformance runs on sonic_vm (use --profile sonic-vm)" >&2
    fi
    exit 1
  fi
fi

# T223/T224 (q3-fabric/q3-traffic) root-cause fix: the capability gate's
# persistence witness (qualify.sh) reloads every guest AFTER the bootstrap
# hook's own save+reload+re-assert, and the sonic-vm guest keeps the CONFIG_DB
# rows but loses the live vtysh (advertise-all-vni, EVPN AF activation, vrf
# VrfBlue binding) and kernel vtep/SVI/VRF joins on every reload. Without a
# post-gate re-assert the provision completes with no adopted VNI — measured
# 2026-10-15: the chain's q3-fabric saw `show evpn vni` empty on both leaves
# minutes after the hook's own Pass-4 adoption gate had passed. The hook's
# --reassert mode is the same idempotent Pass-3 re-assert plus the Pass-4
# session/adoption gate, with NO second save/reload (no StartLimitBurst risk).
# sonic-vs needs none of this: its bootstrap overlay rides bgpcfgd-rendered
# durable FRR config and survives the same reload (p3-vs fabric_verify green).
vm_hook="${REPO_ROOT}/lab/profiles/sonic-vm/bootstrap/configure-fabric-bgp.sh"
# Gate on the ACTIVE profile, not on file existence: the hook hardcodes sonic-vm
# expectations (IPv6 underlay session counts, SRv6 locator rows, kernel seg6) the
# sonic-vs fabric cannot satisfy. Measured 2026-10-15: the chain's --profile
# sonic-vs provision ran it on the vs lab and its Pass-4 gate failed with 30
# failures (locator row missing after GCU + direct write, spine ipv6
# ESTABLISHED < 3, VNI adoption 0) on a lab whose own bootstrap overlay was
# healthy. sonic-vs needs none of this (see above).
if [[ "${AGENTIC_NETOPS_PROFILE}" == "sonic-vm" && -x "$vm_hook" ]]; then
  "$vm_hook" --reassert || { echo "[provision] post-qualify fabric re-assert failed" >&2; exit 1; }
fi

# T033 (contracts/capability-record.md §2): the ConfigMap was generated with
# the honest default cap-sai-srv6: "false" BEFORE the gate (the Network
# controller needs its pins before the gate runs). Now that the gate has
# passed, derive the capability keys from the gate report (path via
# qualify.sh --print-report-path) plus the profile's srv6-supported.yaml and
# patch them in. A failed gate exits above and leaves "false"; the derivation
# itself only yields "true" from a passing, non-skipped SRv6 check set.
# The existence guard is -f, not -x: capability.sh is a sourced library (like
# the other scripts/lib helpers), and the repo tracks it mode 644. A -x guard
# on a 644 lib silently skipped this whole block (observed 2026-10-15: the
# ConfigMap kept the honest default "false" with no srv6-supported key after a
# fully green bring-up — T270 caught it).
if command -v kubectl >/dev/null 2>&1 && [[ -f "${LIB_DIR}/capability.sh" ]]; then
  CTX="kind-${AGENTIC_NETOPS_CLUSTER_NAME}"
  # shellcheck source=./lib/capability.sh
  source "${LIB_DIR}/capability.sh"
  capability_kv=$(capability::derive)
  capability_cap=$(sed -n 's/^cap-sai-srv6=//p' <<<"$capability_kv")
  capability_supported=$(sed -n 's/^srv6-supported=//p' <<<"$capability_kv")
  kubectl --context "$CTX" -n agentic-netops-system patch configmap fabric-compat-pins \
    --type merge -p "{\"data\":{\"cap-sai-srv6\":\"${capability_cap}\",\"srv6-supported\":\"${capability_supported}\"}}" \
    || echo "[provision] WARN: capability patch failed" >&2
  echo "[provision] capability derived from gate report: cap-sai-srv6=${capability_cap} srv6-supported=${capability_supported}"
fi

# T400: one PROVEN sample SRv6 service at bring-up — only when the site
# actually qualifies. T034 keeps the sample OUT of the unconditional path
# (provisioning an SRv6 service is a deliberate, capability-gated act); this
# block is the capability-true complement: a site whose gate derived
# cap-sai-srv6=true runs the ip-vrf/vpn sample end to end and the bring-up
# FAILS if the service never reaches Ready — a green gate that cannot deliver
# a proven service is not a green bring-up. The sample is the same file the
# live acceptance proofs use, so a bring-up failure reproduces outside
# provisioning.
if command -v kubectl >/dev/null 2>&1 && [[ "${capability_cap:-false}" == "true" ]]; then
  CTX="kind-${AGENTIC_NETOPS_CLUSTER_NAME}"
  echo "[provision] cap-sai-srv6=true: applying the proven ip-vrf/vpn sample at bring-up"
  kubectl --context "$CTX" -n agentic-netops-intent apply -f "${REPO_ROOT}/config/samples/srv6service-ip-vrf-vpn.yaml" \
    || { echo "[provision] sample SRv6 service apply failed" >&2; exit 1; }
  if ! kubectl --context "$CTX" -n agentic-netops-intent wait --for=condition=Ready=True --timeout=300s srv6service/srv6-ip-vrf-vpn; then
    kubectl --context "$CTX" -n agentic-netops-intent get srv6service/srv6-ip-vrf-vpn -o jsonpath='{.status.conditions}' >&2 || true
    echo "[provision] bring-up FAILED: the proven SRv6 sample never reached Ready" >&2
    exit 1
  fi
  echo "[provision] sample SRv6 service srv6-ip-vrf-vpn is Ready"
fi

if [[ "$TIER_FAILED" == "true" ]]; then
  echo "[provision] intent tier failed to install" >&2
  exit 1
fi

# Topology asset generation: ensure the ConfigMap is applied now for Grafana Flow
if command -v kubectl >/dev/null 2>&1; then
  CTX="kind-${AGENTIC_NETOPS_CLUSTER_NAME}"
  kubectl --context "$CTX" apply -f "${REPO_ROOT}/deploy/observability/topology-configmap.yaml"
fi

echo "[provision] complete: pins verified, CRDs validated/asserted, Kind ensured/attached, lab deployed, apps installed, seed applied, capability gate executed."
