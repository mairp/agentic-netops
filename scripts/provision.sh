#!/usr/bin/env bash
set -euo pipefail

# Agentic NetOps SR Linux EVPN/VXLAN Fabric — provision script
# Sole implementation of environment creation/convergence per contracts/crd-api.md
# Ordered workflow: preflight → network → Kind → containerlab → in-cluster apps → SDC/fabric intent
# → generated topology assets → lab bootstrap → fabric-executor → capability gate

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
REPO_ROOT=$(cd -- "${SCRIPT_DIR}/.." && pwd)
LIB_DIR="${SCRIPT_DIR}/lib"

# Defaults (overridable by flags)
AGENTIC_NETOPS_CLUSTER_NAME=${AGENTIC_NETOPS_CLUSTER_NAME:-agentic-netops}
AGENTIC_NETOPS_PROFILE=${AGENTIC_NETOPS_PROFILE:-srlinux}
AGENTIC_NETOPS_TIMEOUT=${AGENTIC_NETOPS_TIMEOUT:-180s}

usage() {
  cat <<EOF
Usage: $0 [--profile srlinux] [--cluster-name NAME] [--timeout DURATION] [--with-intent-tier]

Flags:
  --profile           Lab profile (default and only: srlinux — Nokia SR Linux,
                      containerlab kind nokia_srlinux, type ixrd2l)
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
  # Preflight validates versions.lock.yaml, host resources, privileges, MTU, address overlaps and the selected profile
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
# into Kind. The controller images are static distroless-style binaries: build
# them on the host from the pinned, vendored Go source (go.mod + vendor/) and
# import them as scratch images. This keeps the lifecycle reproducible without
# pulling a build base image from an external registry (air-gapped qualified
# host friendly).
if command -v docker >/dev/null 2>&1 && command -v kind >/dev/null 2>&1 && command -v kubectl >/dev/null 2>&1 && command -v go >/dev/null 2>&1; then
  echo "[provision] building controller binaries (pinned vendored Go source)"
  ( cd "${REPO_ROOT}" && CGO_ENABLED=0 GOOS=linux GOARCH=amd64 \
      go build -mod=vendor -tags agentic_netops_k8s -trimpath -ldflags='-s -w' \
      -o /tmp/agentic-netops-srlinux-provider-bin ./cmd/srlinux-provider )
  ( cd "${REPO_ROOT}" && CGO_ENABLED=0 GOOS=linux GOARCH=amd64 \
      go build -mod=vendor -tags agentic_netops_k8s -trimpath -ldflags='-s -w' \
      -o /tmp/agentic-netops-srv6-controller-bin ./cmd/srv6-controller )
  # The executor speaks gNMI to the nodes' management endpoints. It runs as a
  # HOST service (see below), not as a pod, so that the cluster's only route to
  # the fabric stays inside the system tier's netpol envelope. It holds no
  # docker socket: on this platform there is nothing to exec into.
  ( cd "${REPO_ROOT}" && CGO_ENABLED=0 GOOS=linux GOARCH=amd64 \
      go build -mod=vendor -tags agentic_netops_k8s -trimpath -ldflags='-s -w' \
      -o /tmp/agentic-netops-fabric-executor-bin ./cmd/fabric-executor )
  ( cd /tmp && tar -cf agentic-netops-srlinux-provider-bin.tar agentic-netops-srlinux-provider-bin \
      && docker import --change 'USER 65532:65532' --change 'ENTRYPOINT ["/agentic-netops-srlinux-provider-bin"]' agentic-netops-srlinux-provider-bin.tar agentic-netops-srlinux-provider:dev )
  ( cd /tmp && tar -cf agentic-netops-srv6-controller-bin.tar agentic-netops-srv6-controller-bin \
      && docker import --change 'USER 65532:65532' --change 'ENTRYPOINT ["/agentic-netops-srv6-controller-bin"]' agentic-netops-srv6-controller-bin.tar agentic-netops-srv6-controller:dev )
  echo "[provision] loading images into Kind"
  kind load docker-image agentic-netops-srlinux-provider:dev --name "${AGENTIC_NETOPS_CLUSTER_NAME}" || true
  kind load docker-image agentic-netops-srv6-controller:dev --name "${AGENTIC_NETOPS_CLUSTER_NAME}" || true
  echo "[provision] deploying controllers"
  kubectl --context "kind-${AGENTIC_NETOPS_CLUSTER_NAME}" -n agentic-netops-system apply -f "${REPO_ROOT}/deploy/agentic-netops/manifests/provider.yaml"
  kubectl --context "kind-${AGENTIC_NETOPS_CLUSTER_NAME}" -n agentic-netops-system apply -f "${REPO_ROOT}/deploy/agentic-netops/manifests/srv6-controller.yaml"
  kubectl --context "kind-${AGENTIC_NETOPS_CLUSTER_NAME}" -n agentic-netops-system set image deploy/agentic-netops-srlinux-provider provider=agentic-netops-srlinux-provider:dev || true
  kubectl --context "kind-${AGENTIC_NETOPS_CLUSTER_NAME}" -n agentic-netops-system set image deploy/agentic-netops-srv6-controller srv6-controller=agentic-netops-srv6-controller:dev || true
  echo "[provision] waiting for controller pods ready (timeout=${AGENTIC_NETOPS_TIMEOUT})"
  kubectl --context "kind-${AGENTIC_NETOPS_CLUSTER_NAME}" -n agentic-netops-system rollout status deploy/agentic-netops-srlinux-provider --timeout="${AGENTIC_NETOPS_TIMEOUT}"
  kubectl --context "kind-${AGENTIC_NETOPS_CLUSTER_NAME}" -n agentic-netops-system rollout status deploy/agentic-netops-srv6-controller --timeout="${AGENTIC_NETOPS_TIMEOUT}"
  # Capture independent observation proof
  mkdir -p "${REPO_ROOT}/.wiggum/features/001-agentic-netops-srlinux-evpn-fabric/gates/proofs"
  kubectl --context "kind-${AGENTIC_NETOPS_CLUSTER_NAME}" -n agentic-netops-system get deploy,po,svc -o wide \
    | nl -ba > "${REPO_ROOT}/.wiggum/features/001-agentic-netops-srlinux-evpn-fabric/gates/proofs/kubectl-get-agentic-netops-system.txt"
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
import re

lock = open("versions.lock.yaml").read()

def grab(pattern, default="", flags=0):
    m = re.search(pattern, lock, flags)
    return m.group(1).strip() if m else default

srlinux_image = grab(r"^\s*-\s*image:\s*(ghcr\.io/nokia/srlinux:\S+)$", "", re.M)
srlinux_yang = grab(r"^srlinux_yang:.*?^\s*release:\s*(\S+)", "", re.M | re.S)
kubenet = grab(r"^kubenet:.*?^\s*commit:\s*([0-9a-f]+)", "", re.M | re.S)
kuid = grab(r"^kuid:.*?^\s*commit:\s*([0-9a-f]+)", "", re.M | re.S)
sdc = grab(r"^sdc:.*?^\s*version:\s*(\S+)", "", re.M | re.S)

def shorten(sha, n=8):
    return sha[:n] if sha else ""

import json
cm = {"apiVersion": "v1", "kind": "ConfigMap",
    "metadata": {"name": "fabric-compat-pins", "namespace": "agentic-netops-system",
                 "labels": {"agentic-netops.owner": "agentic-netops"}},
    "data": {
        # ConfigMap keys cannot carry "/", so these are the short forms; the
        # pins loader (pkg/compat/pins.go) maps them to the agentic-netops.dev/*
        # annotation names (agentic-netops.dev/srlinux-image,
        # agentic-netops.dev/srlinux-yang).
        "srlinux-image": srlinux_image,
        "srlinux-yang": srlinux_yang,
        "mapping-version": "v0.1.0",
        "kubenet-commit": shorten(kubenet),
        "kuid-commit": shorten(kuid),
        "sdc-release": ("v" + sdc) if sdc and not sdc.startswith("v") else sdc,
        "topology-label-contract": "v0.1.0",
        "telemetry-label-contract": "v0.1.0",
        # A site capability assertion, not a guess: the SR Linux 7220 container
        # has no SRv6 data plane. scripts/lib/qualify.sh records every SRv6
        # entry as not-applicable with that reason, and pkg/compat requires the
        # capability only for SRv6Service objects — a Network never needs it.
        "cap-sai-srv6": "false",
    }}
}
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
  kubectl --context "$CTX" apply -f "${REPO_ROOT}/config/samples/agentic-netops_v1alpha1_srv6service.yaml"
  # The sample SRv6Service is applied for coverage but is NOT waited on: this
  # site declares cap-sai-srv6=false, so the controller reports
  # Ready=False/CapabilityMissing by design. Waiting for Ready here would burn
  # the timeout on an outcome the spec requires (constitution II).
  # Capture independent observation of applied Network resources
  kubectl --context "$CTX" -n kubenet-system get networkconfigs,networks 2>/dev/null | nl -ba > "${REPO_ROOT}/.wiggum/features/001-agentic-netops-srlinux-evpn-fabric/gates/proofs/kubectl-get-kubenet-networks.txt" || true
fi

# Seed SDC schema/profile/discovery
if command -v kubectl >/dev/null 2>&1; then
  CTX="kind-${AGENTIC_NETOPS_CLUSTER_NAME}"
  kubectl --context "$CTX" apply -f "${REPO_ROOT}/deploy/sdc/seed/srlinux-schema.yaml"
  kubectl --context "$CTX" apply -f "${REPO_ROOT}/deploy/sdc/seed/discovery-rule.yaml"
fi

# T185/T186 — optional AGNTCY intent tier. Install it after the Kubernetes
# control plane and tier-owned dependencies are present, but before the
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

# Apply the profile bootstrap to the SR Linux nodes before qualification so the
# capability gate has a live, authenticated gNMI endpoint: wait for gNMI, create
# the generated user, publish the containerlab CA into gnmi-lab-tls. The
# underlay/overlay is already up from the per-node startup-config. The
# in-cluster secret generator must already have run (earlier phase).
if [[ -x "${LIB_DIR}/containerlab.sh" ]]; then
  "${LIB_DIR}/containerlab.sh" bootstrap "${AGENTIC_NETOPS_PROFILE}" || { echo "[provision] lab bootstrap failed" >&2; exit 1; }
fi

# ---------------------------------------------------------------------------
# fabric-executor host service: the southbound write path.
#
# It speaks gNMI (TLS, JSON_IETF) to each node's management endpoint on 57400
# and serves the provider pods on the kind bridge gateway, so the cluster's only
# fabric control route stays inside the system tier's netpol envelope. It holds
# NO docker socket: SR Linux is configured over gNMI and there is nothing to
# exec into. That is why this block runs AFTER the lab bootstrap — the CA it
# trusts (./secrets/ca.crt) and the credentials it authenticates with are
# published by `containerlab.sh bootstrap`, not before it.
# ---------------------------------------------------------------------------
start_fabric_executor() {
  [[ -f /tmp/agentic-netops-fabric-executor-bin ]] || { echo "[provision] WARN: no fabric-executor binary built; skipping host service" >&2; return 0; }
  command -v docker >/dev/null 2>&1 || return 0

  # Credentials and trust anchor, from the lab Secrets the bootstrap published.
  # shellcheck source=./lib/lab_secrets.sh
  source "${LIB_DIR}/lab_secrets.sh"
  if ! lab_secrets::ensure "kind-${AGENTIC_NETOPS_CLUSTER_NAME}"; then
    echo "[provision] ERROR: cannot start the fabric-executor without the lab CA and credentials" >&2
    return 1
  fi
  local CA_FILE="${REPO_ROOT}/secrets/ca.crt"
  [[ -s "$CA_FILE" ]] || { echo "[provision] ERROR: ${CA_FILE} missing after lab_secrets::ensure" >&2; return 1; }

  local KIND_GW
  KIND_GW=$(docker network inspect kind --format '{{range .IPAM.Config}}{{.Gateway}}
{{end}}' | head -1 | tr -d ' ')
  KIND_GW=${KIND_GW:-172.30.0.1}
  local RUN_DIR=/var/local/agentic-netops
  mkdir -p "$RUN_DIR"
  local EXECUTOR_CHANGED=1
  if [[ -f "$RUN_DIR/agentic-netops-fabric-executor" ]] && \
     cmp -s /tmp/agentic-netops-fabric-executor-bin "$RUN_DIR/agentic-netops-fabric-executor"; then
    EXECUTOR_CHANGED=0
  fi
  install -m 0755 /tmp/agentic-netops-fabric-executor-bin "$RUN_DIR/agentic-netops-fabric-executor"
  if [[ "$EXECUTOR_CHANGED" -eq 0 ]] && curl -fsS --max-time 2 "http://127.0.0.1:8084/healthz" >/dev/null 2>&1; then
    echo "[provision] fabric-executor already healthy on :8084 (binary and node map unchanged)"
  else
    # A healthy process can still execute an older, unlinked inode after
    # `install` replaces the binary. Restart whenever bytes changed. Resolve the
    # actual executable as well as the pidfile because interrupted prior
    # launches can leave the pidfile stale.
    local EXECUTOR_PIDS EXECUTOR_PID
    EXECUTOR_PIDS=$(pgrep -f "^$RUN_DIR/agentic-netops-fabric-executor$" 2>/dev/null || true)
    for EXECUTOR_PID in $EXECUTOR_PIDS; do
      kill "$EXECUTOR_PID" 2>/dev/null || true
    done
    [[ -z "$EXECUTOR_PIDS" ]] || sleep 1
    echo "[provision] starting fabric-executor host service on ${KIND_GW}:8084 (gNMI 57400, TLS)"
    # The node map addresses the gNMI endpoints from lab/topology.clab.yml. The
    # credentials come from the environment set here and never from a request
    # (contracts/fabric-executor-api.md).
    FABRIC_EXECUTOR_BIND=":8084" \
    FABRIC_NODE_MAP='{"leaf01":"172.31.0.21:57400","leaf02":"172.31.0.22:57400","spine01":"172.31.0.11:57400","spine02":"172.31.0.12:57400","site-a":"172.31.0.21:57400","site-b":"172.31.0.22:57400"}' \
    FABRIC_GNMI_USER="${GNMI_USER}" \
    FABRIC_GNMI_PASS="${GNMI_PASS}" \
    FABRIC_GNMI_CA="${CA_FILE}" \
      setsid nohup "$RUN_DIR/agentic-netops-fabric-executor" >>"$RUN_DIR/fabric-executor.log" 2>&1 &
    echo $! > "$RUN_DIR/fabric-executor.pid"
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
}

# Start the southbound write path now that the lab CA and credentials exist.
start_fabric_executor || { echo "[provision] fabric-executor could not be started" >&2; exit 1; }


# Run lab capability qualification. There is no fallback profile to select: the
# SR Linux container is the fabric, so a failed gate is a defect to fix in the
# tree (startup-config, gNMI path, bootstrap), not a reason to switch images.
# The gate names the failing check and stops the pipeline (constitution II).
if [[ -x "${LIB_DIR}/qualify.sh" ]]; then
  if ! "${LIB_DIR}/qualify.sh"; then
    echo "[provision] capability gate failed for profile ${AGENTIC_NETOPS_PROFILE}" >&2
    echo "[provision] see the failing check above and the report at .wiggum/features/001-agentic-netops-srlinux-evpn-fabric/gates/proofs/qualify.report.json" >&2
    exit 1
  fi
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

echo "[provision] complete: pins verified, CRDs validated/asserted, Kind ensured/attached, SR Linux lab deployed and bootstrapped, apps installed, seed applied, fabric-executor running, capability gate executed."
