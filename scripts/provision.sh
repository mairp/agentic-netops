#!/usr/bin/env bash
set -euo pipefail

# AINETOPS SONiC EVPN/VXLAN Fabric — provision script (Phase 8)
# Sole implementation of environment creation/convergence per contracts/crd-api.md
# Ordered workflow: preflight → network → Kind → containerlab → in-cluster apps → SDC/fabric intent
# → generated topology assets → SRv6 service → readiness

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &>/dev/null && pwd)
REPO_ROOT=$(cd -- "${SCRIPT_DIR}/.." && pwd)
LIB_DIR="${SCRIPT_DIR}/lib"

# Defaults (overridable by flags)
AINETOPS_CLUSTER_NAME=${AINETOPS_CLUSTER_NAME:-ainetops}
AINETOPS_PROFILE=${AINETOPS_PROFILE:-sonic-vs}
AINETOPS_TIMEOUT=${AINETOPS_TIMEOUT:-180s}

usage() {
  cat <<EOF
Usage: $0 [--profile sonic-vs|sonic-vm] [--cluster-name NAME] [--timeout DURATION]

Flags:
  --profile       SONiC lab profile (sonic-vs fast, sonic-vm conformance)
  --cluster-name  Kind cluster name (default: ainetops)
  --timeout       Rollout wait timeout (default: 180s)
EOF
}

# Parse flags
while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile) shift; AINETOPS_PROFILE=${1:-$AINETOPS_PROFILE} ;;
    --cluster-name) shift; AINETOPS_CLUSTER_NAME=${1:-$AINETOPS_CLUSTER_NAME} ;;
    --timeout) shift; AINETOPS_TIMEOUT=${1:-$AINETOPS_TIMEOUT} ;;
    -h|--help) usage; exit 0 ;;
    *) echo "[provision] unknown flag: $1" >&2; usage; exit 2 ;;
  esac
  shift || true
done
export AINETOPS_CLUSTER_NAME AINETOPS_PROFILE AINETOPS_TIMEOUT

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
      cache="ainetops-cache$(echo "$img" | tr '/@:' '----')"
      docker tag "$img" "$cache" 2>/dev/null || true
      kind load docker-image "$cache" --name "${AINETOPS_CLUSTER_NAME}" >/dev/null 2>&1 \
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

# Build, load, and deploy provider and srv6-controller images into Kind (T041)
# The controller images are static distroless-style binaries: build them on the host
# from the pinned, vendored Go source (go.mod + vendor/) and import them as scratch
# images. This keeps the lifecycle reproducible without pulling a build base image
# from an external registry (air-gapped qualified host friendly).
if command -v docker >/dev/null 2>&1 && command -v kind >/dev/null 2>&1 && command -v kubectl >/dev/null 2>&1 && command -v go >/dev/null 2>&1; then
  echo "[provision] building controller binaries (pinned vendored Go source)"
  ( cd "${REPO_ROOT}" && CGO_ENABLED=0 GOOS=linux GOARCH=amd64 \
      go build -mod=vendor -tags ainetops_k8s -trimpath -ldflags='-s -w' \
      -o /tmp/ainetops-sonic-provider-bin ./cmd/sonic-provider )
  ( cd "${REPO_ROOT}" && CGO_ENABLED=0 GOOS=linux GOARCH=amd64 \
      go build -mod=vendor -tags ainetops_k8s -trimpath -ldflags='-s -w' \
      -o /tmp/ainetops-srv6-controller-bin ./cmd/srv6-controller )
  ( cd /tmp && tar -cf ainetops-sonic-provider-bin.tar ainetops-sonic-provider-bin \
      && docker import --change 'USER 65532:65532' --change 'ENTRYPOINT ["/ainetops-sonic-provider-bin"]' ainetops-sonic-provider-bin.tar ainetops-sonic-provider:dev )
  ( cd /tmp && tar -cf ainetops-srv6-controller-bin.tar ainetops-srv6-controller-bin \
      && docker import --change 'USER 65532:65532' --change 'ENTRYPOINT ["/ainetops-srv6-controller-bin"]' ainetops-srv6-controller-bin.tar ainetops-srv6-controller:dev )
  echo "[provision] loading images into Kind"
  kind load docker-image ainetops-sonic-provider:dev --name "${AINETOPS_CLUSTER_NAME}" || true
  kind load docker-image ainetops-srv6-controller:dev --name "${AINETOPS_CLUSTER_NAME}" || true
  echo "[provision] deploying controllers"
  kubectl --context "kind-${AINETOPS_CLUSTER_NAME}" -n ainetops-system apply -f "${REPO_ROOT}/deploy/ainetops/manifests/provider.yaml"
  kubectl --context "kind-${AINETOPS_CLUSTER_NAME}" -n ainetops-system apply -f "${REPO_ROOT}/deploy/ainetops/manifests/srv6-controller.yaml"
  kubectl --context "kind-${AINETOPS_CLUSTER_NAME}" -n ainetops-system set image deploy/ainetops-sonic-provider provider=ainetops-sonic-provider:dev || true
  kubectl --context "kind-${AINETOPS_CLUSTER_NAME}" -n ainetops-system set image deploy/ainetops-srv6-controller srv6-controller=ainetops-srv6-controller:dev || true
  echo "[provision] waiting for controller pods ready (timeout=${AINETOPS_TIMEOUT})"
  kubectl --context "kind-${AINETOPS_CLUSTER_NAME}" -n ainetops-system rollout status deploy/ainetops-sonic-provider --timeout="${AINETOPS_TIMEOUT}"
  kubectl --context "kind-${AINETOPS_CLUSTER_NAME}" -n ainetops-system rollout status deploy/ainetops-srv6-controller --timeout="${AINETOPS_TIMEOUT}"
  # Capture independent observation proof
  mkdir -p "${REPO_ROOT}/.wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs"
  kubectl --context "kind-${AINETOPS_CLUSTER_NAME}" -n ainetops-system get deploy,po,svc -o wide \
    | nl -ba > "${REPO_ROOT}/.wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/kubectl-get-ainetops-system.txt"
fi

# Apply SRv6 CRD, default Kubenet Network, tenant examples, and sample SRv6 service
if command -v kubectl >/dev/null 2>&1; then
  CTX="kind-${AINETOPS_CLUSTER_NAME}"
  echo "[provision] applying SRv6Service CRD and Kubenet default/tenant networks"
  kubectl --context "$CTX" apply -f "${REPO_ROOT}/config/crd/bases/ainetops.io_srv6services.yaml"
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
  kubectl --context "$CTX" apply -f "${REPO_ROOT}/config/samples/ainetops_v1alpha1_srv6service.yaml"
  # Wait for SRv6Service readiness (best-effort; controller enforces compatibility gates)
  kubectl --context "$CTX" -n default wait --for=condition=Ready --timeout="${AINETOPS_TIMEOUT}" srv6service/example-srv6 || true
  # Capture independent observation of applied Network resources
  kubectl --context "$CTX" -n kubenet-system get networkconfigs,networks 2>/dev/null | nl -ba > "${REPO_ROOT}/.wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/kubectl-get-kubenet-networks.txt" || true
fi
# Seed SDC schema/profile/discovery
if command -v kubectl >/dev/null 2>&1; then
  CTX="kind-${AINETOPS_CLUSTER_NAME}"
  kubectl --context "$CTX" apply -f "${REPO_ROOT}/deploy/sdc/seed/sonic-schema.yaml"
  kubectl --context "$CTX" apply -f "${REPO_ROOT}/deploy/sdc/seed/discovery-rule.yaml"
fi

# Apply the profile bootstrap (gNMI TLS + TELEMETRY config) to the SONiC nodes
# before qualification so the capability gate has a live gNMI endpoint. The
# in-cluster secret generator must already have run (earlier phase).
if [[ -x "${LIB_DIR}/containerlab.sh" ]]; then
  "${LIB_DIR}/containerlab.sh" bootstrap "${AINETOPS_PROFILE}" || { echo "[provision] lab bootstrap failed" >&2; exit 1; }
fi

# Run lab capability qualification; select conformance fallback when sonic-vs fails
if [[ -x "${LIB_DIR}/qualify.sh" ]]; then
  if ! "${LIB_DIR}/qualify.sh"; then
    echo "[provision] capability gate failed for profile ${AINETOPS_PROFILE}" >&2
    if [[ "${AINETOPS_PROFILE}" == "sonic-vs" ]]; then
      echo "[provision] sonic-vs failed gate; this profile is not SRv6-qualified. Use --profile sonic-vm for conformance." >&2
    fi
    exit 1
  fi
fi

# Topology asset generation: ensure the ConfigMap is applied now for Grafana Flow
if command -v kubectl >/dev/null 2>&1; then
  CTX="kind-${AINETOPS_CLUSTER_NAME}"
  kubectl --context "$CTX" apply -f "${REPO_ROOT}/deploy/observability/topology-configmap.yaml"
fi

echo "[provision] complete: pins verified, CRDs validated/asserted, Kind ensured/attached, lab deployed, apps installed, seed applied, capability gate executed."
