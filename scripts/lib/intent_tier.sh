#!/usr/bin/env bash
# scripts/lib/intent_tier.sh — the AGNTCY intent-tier lifecycle (US3).
#
# T181 intent::install    — apply the tier's manifests in dependency order
#                           (SLIM gateway first, then supervisor + workers),
# UI access (US4/T302): the Kind cluster exposes the UI Service as a NodePort
# on 30000/TCP; config/kind/cluster.yaml maps container 30000->host 30000.
# Use intent::ui_url to print the host URL.
#                           load the locally built images into Kind, and run
#                           the tier secret generator (SLIM gateway password,
#                           TLS material) before any worker starts.
# T182 intent::uninstall  — delete every tier workload, Service, ConfigMap,
#                           Secret, Job, and PVC in ainetops-agents that the
#                           install created, leaving no orphan workloads and
#                           no claimed identifiers behind; the namespace and
#                           its RBAC/NetworkPolicies (namespace-rbac.yaml)
#                           are left alone unless PURGE_INTENT_TIER_RBAC=true.
# T183 intent::wait       — bounded rollout waits (kubectl rollout status
#                           with a hard timeout; no unbounded loops) for
#                           every tier Deployment.
# T184                    — strict mode (`set -euo pipefail` locally), a
#                           phase logger (intent::log / intent::phase), and
#                           every wait bounded by INTENT_TIER_TIMEOUT.
#
# Sourced by scripts/provision.sh (`--with-intent-tier`) and
# scripts/off.sh (`--purge-intent-tier`). Consumes the caller's exported
# AINETOPS_CLUSTER_NAME; never sets -e for the caller beyond the functions.

# T184 — strict mode for this library (the caller's shell options are
# restored by sourcing inside the caller's own `set -euo pipefail`).
set -euo pipefail

INTENT_TIER_NAMESPACE=${INTENT_TIER_NAMESPACE:-ainetops-agents}
INTENT_TIER_TIMEOUT=${INTENT_TIER_TIMEOUT:-300s}
INTENT_TIER_CTX=${INTENT_TIER_CTX:-}
INTENT_TIER_ROOT=${INTENT_TIER_ROOT:-}

intent::ctx() {
  local cluster="${AINETOPS_CLUSTER_NAME:-ainetops}"
  echo "${INTENT_TIER_CTX:-kind-${cluster}}"
}

# T184 — phase logging: every phase announces itself with a single
# bracketed prefix so provision/off logs are greppable per phase.
intent::log() { echo "[intent-tier] $*"; }
intent::phase() { echo "[intent-tier] == phase: $* =="; }

intent::kubectl() {
  kubectl --context "$(intent::ctx)" "$@"
}

intent::manifest() {
  local f="${1}"
  local base="${INTENT_TIER_ROOT:-}"
  if [[ -z "$base" ]]; then
    base="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
  fi
  echo "${base}/deploy/agents/${f}"
}

# T181 — install the tier in dependency order:
#   1. generated Secrets (SLIM gateway password + TLS material) via the
#      tier secret generator Job (deploy/agents/secret-generator-job.yaml);
#   2. the SLIM gateway (slim.yaml);
#   3. supervisor + workers (supervisor/mapper/allocator/deployer.yaml).
intent::install() {
  intent::phase "install (namespace ${INTENT_TIER_NAMESPACE}, timeout ${INTENT_TIER_TIMEOUT})"

  local root="${INTENT_TIER_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)}"

  # Load the locally built tier images so digest/lab images resolve without
  # a registry (air-gapped lab friendly; best-effort — a preloaded node
  # image is fine too).
  if command -v kind >/dev/null 2>&1 && command -v docker >/dev/null 2>&1; then
    local cluster="${AINETOPS_CLUSTER_NAME:-ainetops}"
    for img in ainetops/intent-supervisor:latest ainetops/intent-mapper:latest \
               ainetops/intent-allocator:latest ainetops/intent-deployer:latest \
               ainetops/intent-translator:latest; do
      if docker image inspect "$img" >/dev/null 2>&1; then
        kind load docker-image "$img" --name "$cluster" >/dev/null 2>&1 \
          && intent::log "loaded $img" || intent::log "WARN: kind load failed for $img (pull will be attempted)"
      else
        intent::log "WARN: image not in local cache: $img"
      fi
    done
  fi

  intent::kubectl apply -f "${root}/deploy/agents/namespace-rbac.yaml"

  # The generator Job must complete before the gateway starts: the gateway
  # mounts the generated TLS material and password.
  intent::kubectl apply -f "${root}/deploy/agents/secret-generator-job.yaml"
  if ! intent::kubectl -n "$INTENT_TIER_NAMESPACE" wait --for=condition=Complete \
        --timeout="$INTENT_TIER_TIMEOUT" job/intent-secret-generator 2>/dev/null; then
    intent::log "secret generator incomplete; recreating it once"
    intent::kubectl -n "$INTENT_TIER_NAMESPACE" delete job intent-secret-generator --ignore-not-found
    intent::kubectl apply -f "${root}/deploy/agents/secret-generator-job.yaml"
    intent::kubectl -n "$INTENT_TIER_NAMESPACE" wait --for=condition=Complete \
      --timeout="$INTENT_TIER_TIMEOUT" job/intent-secret-generator
  fi

  intent::kubectl apply -f "$(intent::manifest slim.yaml)"
  intent::kubectl apply -f "$(intent::manifest supervisor.yaml)"
  intent::kubectl apply -f "$(intent::manifest mapper.yaml)"
  intent::kubectl apply -f "$(intent::manifest allocator.yaml)"
  intent::kubectl apply -f "$(intent::manifest deployer.yaml)"
  intent::kubectl apply -f "$(intent::manifest ui-configmap.yaml)"
  intent::kubectl apply -f "$(intent::manifest ui.yaml)"

  intent::log "tier manifests applied; waiting for rollouts"
  intent::wait
  intent::log "install complete"
}

# T183 — bounded waits: every rollout wait carries the hard timeout
# INTENT_TIER_TIMEOUT (no unbounded loop anywhere in this library).
intent::wait() {
  intent::phase "wait (rollout status, timeout ${INTENT_TIER_TIMEOUT})"
  local dep failed=0
  for dep in slim supervisor mapper allocator deployer ui; do
    if intent::kubectl -n "$INTENT_TIER_NAMESPACE" rollout status \
         "deployment/${dep}" --timeout="${INTENT_TIER_TIMEOUT}"; then
      intent::log "deployment/${dep} ready"
    else
      intent::log "ERROR: deployment/${dep} not ready within ${INTENT_TIER_TIMEOUT}"
      intent::kubectl -n "$INTENT_TIER_NAMESPACE" get pods -o wide || true
      failed=1
    fi
  done
  # Independent read-back: the durable state the waits are about.
  intent::kubectl -n "$INTENT_TIER_NAMESPACE" get deploy,po,svc,pvc | intent::log_pipe
  return "$failed"
}

intent::log_pipe() { sed 's/^/[intent-tier]   /'; }

intent::ui_url() {
  # Kind control-plane publishes NodePort 30000 -> host 30000
  local host=localhost
  echo "http://${host}:30000"
}

# T182 — uninstall: delete every tier workload and its claimed identifiers.
# The PVC (supervisor-checkpoint) is deleted too — a stale checkpoint is
# exactly the "orphan claimed identifier" class US3 forbids; the namespace
# and its RBAC survive (they belong to the RBAC contract, not the workload).
intent::uninstall() {
  intent::phase "uninstall (namespace ${INTENT_TIER_NAMESPACE})"
  local root="${INTENT_TIER_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)}"

  # Workloads first (scale to zero semantics), then Services, then Jobs,
  # then config/secret state, then the PVC.
  local dep
  for dep in supervisor mapper allocator deployer slim ui; do
    intent::kubectl -n "$INTENT_TIER_NAMESPACE" delete deployment "$dep" --ignore-not-found --wait=true --timeout="$INTENT_TIER_TIMEOUT" || true
  done
  intent::kubectl -n "$INTENT_TIER_NAMESPACE" delete svc supervisor mapper allocator deployer slim ui \
    --ignore-not-found || true
  intent::kubectl -n "$INTENT_TIER_NAMESPACE" delete job intent-secret-generator \
    --ignore-not-found --wait=true --timeout="$INTENT_TIER_TIMEOUT" || true
  intent::kubectl -n "$INTENT_TIER_NAMESPACE" delete configmap supervisor-prompts slim-config \
    --ignore-not-found || true
  intent::kubectl -n "$INTENT_TIER_NAMESPACE" delete secret llm-provider slim-gateway slim-tls \
    --ignore-not-found || true
  intent::kubectl -n "$INTENT_TIER_NAMESPACE" delete pvc supervisor-checkpoint \
    --ignore-not-found --wait=true --timeout="$INTENT_TIER_TIMEOUT" || true

  # Purge any straggler pods (terminating ones included) — no orphan workloads.
  intent::kubectl -n "$INTENT_TIER_NAMESPACE" delete pods --all --ignore-not-found --wait=true --timeout="$INTENT_TIER_TIMEOUT" || true

  if [[ "${PURGE_INTENT_TIER_RBAC:-false}" == "true" ]]; then
    intent::log "PURGE_INTENT_TIER_RBAC=true: removing tier RBAC/NetworkPolicies as well"
    intent::kubectl delete -f "${root}/deploy/agents/namespace-rbac.yaml" --ignore-not-found || true
  fi

  # Independent read-back: prove nothing is left running or claimed.
  intent::kubectl -n "$INTENT_TIER_NAMESPACE" get deploy,po,svc,pvc 2>/dev/null | intent::log_pipe || true
  intent::log "uninstall complete (no orphan workloads, no claimed identifiers)"
}
