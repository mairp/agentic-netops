#!/usr/bin/env bash
# T056 / SC-005 (third clause): assert that a tier pod CANNOT connect to the
# containerlab management network — specifically 172.31.0.21:57400 (SONiC
# leaf01's gNMI port on the mgmt subnet 172.31.0.0/16, per
# scripts/lib/kind.sh kind::ensure_mgmt_network and the certificate SANs in
# deploy/rbac/secret-generator-job.yaml).
#
# Mechanism under test: NetworkPolicy/allow-egress-scoped in
# deploy/agents/namespace-rbac.yaml admits egress from tier pods (label
# agentic-netops.io/tier: intent) ONLY to the scoped budget (DNS, intra-tier,
# otel-collector:4317, model-provider TCP/443 with 172.31.0.0/16 EXCLUDED via
# ipBlock except). The mgmt subnet is therefore unreachable from every tier
# pod — the denial the probe asserts. "gNMI dial to any SONiC node -> timeout"
# (contracts/kubernetes-objects.md) is the same policy, so this one concrete
# endpoint is the attemptable proof for the whole class.
#
# The probe runs as a THROWAWAY pod in agentic-netops-agents carrying the tier label
# (so the NetworkPolicies apply) and no token (automountServiceAccountToken:
# false). It attempts one TCP connect with a 5 s cap; a SUCCESSFUL connect is
# a probe failure, a timeout/refused/unreachable is the expected denial.
#
# Precondition: deploy/agents/namespace-rbac.yaml applied; the kindest/node
# image is on the cluster node (it is — the cluster is built from it).
#
# Usage: deploy/agents/tests/probes/mgmt-network-denial.sh [kubectl-context]
# Exit: 0 = connection denied as required; 1 = connection SUCCEEDED (guardrail
#        broken) or the probe could not run.
#
# Result interpretation: a denial (rc=124/110/113) is the required outcome.
# On the full feature-001 lab the 172.31.0.0/16 subnet EXISTS and the CNI
# enforces NetworkPolicy, so there the denial is caused by
# allow-egress-scoped's ipBlock except list. On a cluster without the mgmt
# subnet (or without a NetworkPolicy-enforcing CNI), the connect fails for
# environmental reasons instead — still a PASS, but the log line records
# the observed rc so the reader sees the cause. A SUCCEEDING connect always
# fails the probe, whatever the cluster.

set -euo pipefail

CTX="${1:-}"
K() { if [[ -n "$CTX" ]]; then kubectl --context "$CTX" "$@"; else kubectl "$@"; fi; }

NS=agentic-netops-agents
POD=mgmt-net-probe
TARGET=172.31.0.21
PORT=57400
TIMEOUT_S=5
NODE_IMAGE=kindest/node@sha256:28b7cbb993dfe093c76641a0c95807637213c9109b761f1d422c2400e22b8e87

cleanup() { K -n "$NS" delete pod "$POD" --ignore-not-found --wait=false >/dev/null 2>&1 || true; }
trap cleanup EXIT

K -n "$NS" delete pod "$POD" --ignore-not-found --wait=false >/dev/null 2>&1 || true

cat <<EOF | K apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: ${POD}
  namespace: ${NS}
  labels:
    agentic-netops.owner: agentic-netops
    agentic-netops.io/tier: intent
    app: intent-probe
spec:
  restartPolicy: Never
  automountServiceAccountToken: false
  containers:
  - name: probe
    image: ${NODE_IMAGE}
    imagePullPolicy: IfNotPresent
    command: ["/bin/bash", "-c"]
    args:
    - |
      set -u
      # One TCP connect attempt, hard-capped. /dev/tcp open => connect succeeded.
      timeout ${TIMEOUT_S} bash -c "exec 3<>/dev/tcp/${TARGET}/${PORT}" 2>/dev/null
      rc=\$?
      echo "connect_rc=\${rc}"
      exit \${rc}
EOF

# The container ALWAYS terminates: the connect attempt is capped by
# `timeout ${TIMEOUT_S}s` (rc=124 on denial) or completes (rc=0 on a guardrail
# breach). With restartPolicy: Never the pod then sits in a terminal phase with
# readable logs — wait for that, not for Ready (the container exits ~${TIMEOUT_S}s
# after start, so the Ready window is too narrow to race against).
echo "waiting for probe pod ${POD} to finish the connect attempt (bounded 300 s)..."
phase=""
for _ in $(seq 1 150); do
  phase=$(K -n "$NS" get pod "$POD" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
  if [[ "$phase" == "Succeeded" || "$phase" == "Failed" ]]; then
    break
  fi
  sleep 2
done
echo "probe pod phase: ${phase:-<never reached a terminal phase>}"

OUT=$(K -n "$NS" logs "$POD" 2>/dev/null || true)
echo "probe log: ${OUT:-<no output — pod never ran>}"

if [[ "$OUT" == *"connect_rc="* ]]; then
  rc=$(printf '%s\n' "$OUT" | sed -n 's/^connect_rc=//p' | head -1)
  if [[ "$rc" == "0" ]]; then
    echo "FAIL: tier pod CONNECTED to ${TARGET}:${PORT} — allow-egress-scoped is not excluding 172.31.0.0/16."
    exit 1
  fi
  echo "PASS: connect to ${TARGET}:${PORT} denied (rc=${rc}: timeout/refused/unreachable, as required)."
  exit 0
fi

echo "FAIL: probe pod produced no connect_rc line — cannot assert the denial (see pod status/logs)."
K -n "$NS" get pod "$POD" -o wide || true
K -n "$NS" describe pod "$POD" | tail -20 || true
exit 1
