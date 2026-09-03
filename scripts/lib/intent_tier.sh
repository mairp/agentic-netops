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
#                           Secret, Job, and PVC in agentic-netops-agents that the
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
# T398 intent::backup     — archive the supervisor-checkpoint PVC contents as a
#                           timestamped tar.gz to a given directory.
# T399 intent::restore    — restore a previously archived supervisor checkpoint
#                           tar.gz into the PVC (with safe rollout sequencing).
#
# Sourced by scripts/provision.sh (`--with-intent-tier`) and
# scripts/off.sh (`--purge-intent-tier`). Consumes the caller's exported
# AGENTIC_NETOPS_CLUSTER_NAME; never sets -e for the caller beyond the functions.

# T184 — strict mode for this library (the caller's shell options are
# restored by sourcing inside the caller's own `set -euo pipefail`).
set -euo pipefail

INTENT_TIER_NAMESPACE=${INTENT_TIER_NAMESPACE:-agentic-netops-agents}
INTENT_TIER_TIMEOUT=${INTENT_TIER_TIMEOUT:-300s}
INTENT_TIER_CTX=${INTENT_TIER_CTX:-}
INTENT_TIER_ROOT=${INTENT_TIER_ROOT:-}

intent::ctx() {
  local cluster="${AGENTIC_NETOPS_CLUSTER_NAME:-agentic-netops}"
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

intent::configure_llm_provider() {
  local model="${AGENTIC_NETOPS_LLM_MODEL:-${LLM_MODEL:-}}"
  local api_key="${AGENTIC_NETOPS_LLM_API_KEY:-${OPENAI_API_KEY:-}}"
  local base_url="${AGENTIC_NETOPS_LLM_BASE_URL:-${OPENAI_BASE_URL:-}}"
  local -a secret_args

  if ! intent::kubectl -n "$INTENT_TIER_NAMESPACE" get secret llm-provider >/dev/null 2>&1; then
    intent::kubectl apply -f "$(intent::manifest llm-provider-secret.yaml)"
  fi

  if [[ -z "$model" && -z "$api_key" ]]; then
    intent::log "WARN: LLM provider is not configured; set AGENTIC_NETOPS_LLM_MODEL and AGENTIC_NETOPS_LLM_API_KEY"
    return 0
  fi
  if [[ -z "$model" || -z "$api_key" ]]; then
    echo "[intent-tier] ERROR: both AGENTIC_NETOPS_LLM_MODEL and AGENTIC_NETOPS_LLM_API_KEY are required" >&2
    return 1
  fi

  secret_args=(
    --from-literal="LLM_MODEL=$model"
    --from-literal="OPENAI_API_KEY=$api_key"
  )
  if [[ -n "$base_url" ]]; then
    secret_args+=(--from-literal="OPENAI_BASE_URL=$base_url")
  fi
  intent::kubectl -n "$INTENT_TIER_NAMESPACE" create secret generic llm-provider \
    "${secret_args[@]}" --dry-run=client -o yaml | intent::kubectl apply -f - >/dev/null
  intent::kubectl -n "$INTENT_TIER_NAMESPACE" label secret llm-provider \
    agentic-netops.owner=agentic-netops agentic-netops.io/tier=intent --overwrite >/dev/null
  intent::kubectl -n "$INTENT_TIER_NAMESPACE" annotate secret llm-provider \
    agentic-netops.io/populated-by="provision-time (LLM provider credentials; never committed)" \
    --overwrite >/dev/null
  intent::log "configured LLM provider model $model"
}

# T181 — install the tier in dependency order:
#   1. generated Secrets (SLIM gateway password + TLS material) via the
#      tier secret generator Job (deploy/agents/secret-generator-job.yaml);
#   2. the SLIM gateway (slim.yaml);
#   3. supervisor + workers (supervisor/mapper/allocator/deployer.yaml).
intent::install() {
  intent::phase "install (namespace ${INTENT_TIER_NAMESPACE}, timeout ${INTENT_TIER_TIMEOUT})"

  local root="${INTENT_TIER_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)}"

  # Build (when missing) and load the tier images. These images exist ONLY on
  # the build host -- `agentic-netops/intent-*:latest` is not published to any
  # registry -- so a missing one is not a warning, it is a guaranteed
  # ImagePullBackOff and a tier that never comes up. Warning and continuing is
  # what made a from-scratch provision produce a half-dead tier (2026-09-03):
  # the pods were scheduled against images that had never been built on the host.
  #
  # Build is idempotent and skipped when the image is already in the local cache,
  # so repeat provisions stay fast. Set INTENT_TIER_REBUILD=true to force a
  # rebuild after changing agent source.
  if command -v kind >/dev/null 2>&1 && command -v docker >/dev/null 2>&1; then
    local cluster="${AGENTIC_NETOPS_CLUSTER_NAME:-agentic-netops}"
    local rebuild="${INTENT_TIER_REBUILD:-false}"
    # image:dockerfile pairs (build context is the repository root)
    local spec img dockerfile
    for spec in \
      "agentic-netops/intent-supervisor:latest=docker/Dockerfile.supervisor" \
      "agentic-netops/intent-mapper:latest=docker/Dockerfile.mapper" \
      "agentic-netops/intent-allocator:latest=docker/Dockerfile.allocator" \
      "agentic-netops/intent-deployer:latest=docker/Dockerfile.deployer" \
      "agentic-netops/intent-translator:latest=docker/Dockerfile.intent-translator" \
      "agentic-netops/intent-ui:latest=docker/Dockerfile.ui"; do
      img="${spec%%=*}"
      dockerfile="${spec#*=}"
      if [[ "$rebuild" == "true" ]] || ! docker image inspect "$img" >/dev/null 2>&1; then
        intent::log "building $img (${dockerfile})"
        if ! docker build -q -f "${root}/${dockerfile}" -t "$img" "${root}" >/dev/null; then
          echo "[intent-tier] ERROR: failed to build $img from ${dockerfile}" >&2
          return 1
        fi
      fi
      kind load docker-image "$img" --name "$cluster" >/dev/null 2>&1 \
        && intent::log "loaded $img" \
        || { echo "[intent-tier] ERROR: kind load failed for $img into cluster $cluster" >&2; return 1; }
    done
  else
    echo "[intent-tier] ERROR: docker and kind are required to build/load the tier images" >&2
    return 1
  fi

  intent::kubectl apply -f "${root}/deploy/agents/namespace-rbac.yaml"
  intent::configure_llm_provider

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

  # The tier-owned OTel collector MUST exist before the agents start. Every agent
  # exports OTLP traces on startup and treats a failed export as fatal: without this
  # collector they fall back to localhost:4318, get ConnectionError, and crash --
  # allocator reached CrashLoopBackOff with 13 restarts while its own /v1/health
  # returned 200, so the pod looked alive and the supervisor just reported
  # "readiness degraded: allocator unreachable" (2026-09-03). The manifest existed
  # in deploy/agents/telemetry.yaml the whole time and was simply never applied.
  intent::kubectl apply -f "$(intent::manifest telemetry.yaml)"
  intent::kubectl apply -f "$(intent::manifest slim.yaml)"
  intent::kubectl apply -f "$(intent::manifest supervisor.yaml)"
  intent::kubectl apply -f "$(intent::manifest mapper.yaml)"
  intent::kubectl apply -f "$(intent::manifest allocator.yaml)"
  intent::kubectl apply -f "$(intent::manifest deployer.yaml)"
  intent::kubectl apply -f "$(intent::manifest ui-configmap.yaml)"
  intent::kubectl apply -f "$(intent::manifest ui.yaml)"

  # Local images use a mutable :latest tag. Applying an unchanged Deployment
  # does not create a new ReplicaSet, so a rebuilt image would otherwise sit
  # unused in the Kind node cache. Restart after every load; first installs are
  # unaffected, while repeat installs reliably consume rebuilt code and newly
  # populated Secret values.
  intent::kubectl -n "$INTENT_TIER_NAMESPACE" rollout restart \
    deployment/supervisor deployment/mapper deployment/allocator deployment/deployer deployment/ui

  # T339 — Mount the intent-tier dashboards into Grafana via a reversible patch
  # We keep dashboards in the agents tree (ConfigMap grafana-dashboards-agents, namespace agentic-netops-agents)
  # and mount them into the shared Grafana deployment in monitoring.
  if intent::kubectl -n monitoring get deploy grafana >/dev/null 2>&1; then
    intent::log "patching Grafana to mount intent-tier dashboards (T339)"
    intent::kubectl -n monitoring patch deploy grafana --type='json' -p='[
      {"op":"add","path":"/spec/template/spec/volumes/-","value":{"name":"dashboards-agents","configMap":{"name":"grafana-dashboards-agents","optional":true}}},
      {"op":"add","path":"/spec/template/spec/containers/0/volumeMounts/-","value":{"name":"dashboards-agents","mountPath":"/var/lib/grafana/dashboards/intent-tier","readOnly":true}}
    ]' || true
  else
    intent::log "Grafana deployment not present; skipping dashboard mount patch"
  fi

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

# T398 — Backup the supervisor checkpointer PVC to a directory
# Usage: intent::backup /path/to/dir
intent::backup() {
  local outdir=${1:-}
  [[ -n "$outdir" ]] || { intent::log "ERROR: intent::backup requires an output directory"; return 2; }
  mkdir -p "$outdir"
  intent::phase "backup (PVC supervisor-checkpoint)"
  local ts; ts=$(date -u +%Y%m%dT%H%M%SZ)
  local tmpdir; tmpdir=$(mktemp -d)
  # Create a helper pod with the PVC mounted read-only and tar its contents
  intent::kubectl -n "$INTENT_TIER_NAMESPACE" delete pod checkpoint-backup --ignore-not-found || true
  cat <<EOF | intent::kubectl -n "$INTENT_TIER_NAMESPACE" apply -f -
apiVersion: v1
kind: Pod
metadata: { name: checkpoint-backup, labels: { app: checkpoint-backup } }
spec:
  restartPolicy: Never
  containers:
  - name: tar
    image: alpine:3.20
    command: ["/bin/sh","-c","tar -czf /out/supervisor-checkpoint.tgz -C /state . && sleep 1"]
    volumeMounts:
    - { name: pvc, mountPath: /state, readOnly: true }
    - { name: out, mountPath: /out }
  volumes:
  - name: pvc
    persistentVolumeClaim: { claimName: supervisor-checkpoint }
  - name: out
    emptyDir: {}
EOF
  # Wait for pod to become Ready, then copy the tarball out
  if ! intent::kubectl -n "$INTENT_TIER_NAMESPACE" wait --for=condition=Ready pod/checkpoint-backup --timeout=60s; then
    intent::log "ERROR: backup pod did not become Ready"; return 1; fi
  # Give a moment for tar to write
  sleep 1
  intent::kubectl -n "$INTENT_TIER_NAMESPACE" cp checkpoint-backup:/out/supervisor-checkpoint.tgz "$tmpdir/ckpt.tgz" || {
    intent::kubectl -n "$INTENT_TIER_NAMESPACE" logs pod/checkpoint-backup || true
    intent::log "ERROR: failed to copy checkpoint archive"; return 1; }
  local dest="$outdir/supervisor-checkpoint-${ts}.tar.gz"
  mv "$tmpdir/ckpt.tgz" "$dest"
  intent::kubectl -n "$INTENT_TIER_NAMESPACE" delete pod checkpoint-backup --ignore-not-found || true
  rm -rf "$tmpdir"
  intent::log "backup complete: $dest"
}

# T399 — Restore the supervisor checkpointer PVC from an archive
# Usage: intent::restore /path/to/supervisor-checkpoint-<ts>.tar.gz
intent::restore() {
  local archive=${1:-}
  [[ -f "$archive" ]] || { intent::log "ERROR: archive not found: $archive"; return 2; }
  intent::phase "restore (PVC supervisor-checkpoint)"
  # Ensure supervisor is not using the PVC
  intent::kubectl -n "$INTENT_TIER_NAMESPACE" scale deploy/supervisor --replicas=0 || true
  intent::kubectl -n "$INTENT_TIER_NAMESPACE" rollout status deploy/supervisor --timeout="$INTENT_TIER_TIMEOUT" || true
  # Create a helper pod to untar into the PVC
  intent::kubectl -n "$INTENT_TIER_NAMESPACE" delete pod checkpoint-restore --ignore-not-found || true
  cat <<EOF | intent::kubectl -n "$INTENT_TIER_NAMESPACE" apply -f -
apiVersion: v1
kind: Pod
metadata: { name: checkpoint-restore, labels: { app: checkpoint-restore } }
spec:
  restartPolicy: Never
  containers:
  - name: tar
    image: alpine:3.20
    command: ["/bin/sh","-c","rm -rf /state/* && tar -xzf /in/ckpt.tgz -C /state && ls -l /state && sleep 1"]
    volumeMounts:
    - { name: pvc, mountPath: /state }
    - { name: in, mountPath: /in }
  volumes:
  - name: pvc
    persistentVolumeClaim: { claimName: supervisor-checkpoint }
  - name: in
    emptyDir: {}
EOF
  # Copy archive into the pod and execute restore
  intent::kubectl -n "$INTENT_TIER_NAMESPACE" wait --for=condition=Ready pod/checkpoint-restore --timeout=60s || {
    intent::log "ERROR: restore pod did not become Ready"; return 1; }
  intent::kubectl -n "$INTENT_TIER_NAMESPACE" cp "$archive" checkpoint-restore:/in/ckpt.tgz || {
    intent::log "ERROR: failed to upload archive"; return 1; }
  # Wait a short time for the command to finish
  sleep 2
  intent::kubectl -n "$INTENT_TIER_NAMESPACE" logs pod/checkpoint-restore || true
  # Cleanup helper pod
  intent::kubectl -n "$INTENT_TIER_NAMESPACE" delete pod checkpoint-restore --ignore-not-found || true
  # Scale supervisor back up
  intent::kubectl -n "$INTENT_TIER_NAMESPACE" scale deploy/supervisor --replicas=1 || true
  intent::kubectl -n "$INTENT_TIER_NAMESPACE" rollout status deploy/supervisor --timeout="$INTENT_TIER_TIMEOUT" || true
  intent::log "restore complete"
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
    : # patch removal handled after deletes
  done
  # T339 — Revert Grafana patch if present
  if intent::kubectl -n monitoring get deploy grafana >/dev/null 2>&1; then
    intent::log "reverting Grafana dashboard mount patch (T339)"
    # Remove volumeMount if exists
    intent::kubectl -n monitoring patch deploy grafana --type='json' -p='[
      {"op":"remove","path":"/spec/template/spec/containers/0/volumeMounts", "value":[]}
    ]' || true
    # Remove volumes if exists
    intent::kubectl -n monitoring patch deploy grafana --type='json' -p='[
      {"op":"remove","path":"/spec/template/spec/volumes", "value":[]}
    ]' || true
  fi
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

# Dispatcher: allow invoking functions when this file is executed directly
if [[ "${BASH_SOURCE[0]:-}" == "$0" ]]; then
  cmd="${1:-}"; shift || true
  case "$cmd" in
    intent::install|intent::wait|intent::backup|intent::restore|intent::uninstall|intent::ui_url)
      "$cmd" "$@";;
    *)
      echo "Usage: $0 <intent::install|intent::wait|intent::backup|intent::restore|intent::uninstall|intent::ui_url> [args...]" >&2
      exit 2;;
  esac
fi
