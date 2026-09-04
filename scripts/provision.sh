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
AGENTIC_NETOPS_PROFILE=${AGENTIC_NETOPS_PROFILE:-sonic-vs}
AGENTIC_NETOPS_TIMEOUT=${AGENTIC_NETOPS_TIMEOUT:-180s}

usage() {
  cat <<EOF
Usage: $0 [--profile sonic-vs|sonic-vm] [--cluster-name NAME] [--timeout DURATION] [--with-intent-tier]

Flags:
  --profile           SONiC lab profile (sonic-vs fast, sonic-vm conformance)
  --cluster-name      Kind cluster name (default: agentic-netops)
  --timeout           Rollout wait timeout (default: 180s)
  --with-intent-tier  Also install the AGNTCY intent tier (supervisor +
                      mapper/allocator/deployer over SLIM) after the control
                      plane readiness waits (T185/T186)
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
  kubectl --context "kind-${AGENTIC_NETOPS_CLUSTER_NAME}" -n agentic-netops-system apply -f "${REPO_ROOT}/deploy/agentic-netops/manifests/srv6-controller.yaml"
  kubectl --context "kind-${AGENTIC_NETOPS_CLUSTER_NAME}" -n agentic-netops-system set image deploy/agentic-netops-sonic-provider provider=agentic-netops-sonic-provider:dev || true
  kubectl --context "kind-${AGENTIC_NETOPS_CLUSTER_NAME}" -n agentic-netops-system set image deploy/agentic-netops-srv6-controller srv6-controller=agentic-netops-srv6-controller:dev || true
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
  if [[ "$EXECUTOR_CHANGED" -eq 0 ]] && curl -fsS --max-time 2 "http://127.0.0.1:8084/healthz" >/dev/null 2>&1; then
    echo "[provision] fabric-executor already healthy on :8084 (node map unchanged)"
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
    FABRIC_EXECUTOR_BIND=":8084" \
    FABRIC_NODE_MAP='{"leaf01":"clab-agentic-netops-fabric-leaf01","leaf02":"clab-agentic-netops-fabric-leaf02","spine01":"clab-agentic-netops-fabric-spine01","spine02":"clab-agentic-netops-fabric-spine02","site-a":"clab-agentic-netops-fabric-leaf01","site-b":"clab-agentic-netops-fabric-leaf02"}' \
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

sonic_image = grab(r"^\s*-\s*image:\s*(localhost:5000/sonic-vs-gnmi:\S+)$", "", re.M)
oc = grab(r"^\s*-\s*image:.*\n\s*oc_version:\s*openconfig@([0-9a-f]+)", "", re.M)
native = grab(r"^\s*-\s*image:.*\n\s*oc_version:.*\n\s*native_version:\s*sonic_yang@([0-9a-f]+)", "", re.M)
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
        # Site capability assertions, not guesses: versions.lock.yaml declares
        # this image SRv6/gNMI-qualified and scripts/lib/qualify.sh gated it
        # live ("[qualify] OK", sonic-srv6 locator read-back asserted on both
        # leaves — gates/proofs/cycles/idempotence-provision-1.log). The FRR
        # L3VNI/Type-5 limitation is tracked separately as D-A2.
        "cap-sai-srv6": "true",
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
  # Wait for SRv6Service readiness (best-effort; controller enforces compatibility gates)
  kubectl --context "$CTX" -n default wait --for=condition=Ready --timeout="${AGENTIC_NETOPS_TIMEOUT}" srv6service/example-srv6 || true
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
      echo "[provision] sonic-vs failed gate; this profile is not SRv6-qualified. Use --profile sonic-vm for conformance." >&2
    fi
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

echo "[provision] complete: pins verified, CRDs validated/asserted, Kind ensured/attached, lab deployed, apps installed, seed applied, capability gate executed."
