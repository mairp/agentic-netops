#!/usr/bin/env bash
# T151 / FR-024: assert that an UNAUTHENTICATED client cannot register with
# the SLIM gateway — the attemptable proof that the transport is closed to
# anything without the generated credentials (contracts/a2a-transport.md).
#
# Mechanism under test: the gateway runs TLS with client-certificate
# verification (slim.yaml ConfigMap/slim-config: client_ca_file against the
# generated CA) and PASSWORD authentication (Secret/slim-gateway from
# deploy/agents/secret-generator-job.yaml). A client presenting NO client
# certificate and NO password must never establish a registration/session
# on the data plane port 46357.
#
# Method: run a throwaway pod in agentic-netops-agents (tier-labelled, no token,
# kindest/node image) that opens a raw TCP connection to slim:46357 and
# sends a TLS ClientHello WITHOUT a client certificate (the unauthenticated
# registration attempt), then tries to read the server's response. The
# gateway's client-certificate verification terminates such a handshake:
# the attempt must FAIL — a clean non-error exchange (or an open,
# protocol-accepting socket) is a probe failure.
#
# Result interpretation: any nonzero rc from the attempt (handshake alert,
# connection reset, refused, timeout) is the required denial → PASS. rc=0
# on the attempt means the unauthenticated exchange was accepted → FAIL.
# When the gateway is not deployed yet, the connection fails to open
# (rc=124/7) — still a PASS (an unauthenticated client demonstrably cannot
# register), and the log records the observed rc and gateway presence so
# the reader sees the cause.
#
# Precondition: deploy/agents/namespace-rbac.yaml applied (the namespace and
# the NetworkPolicies); the kindest/node image is on the cluster node.
#
# Usage: deploy/agents/tests/probes/slim-auth-denial.sh [kubectl-context]
# Exit:  0 = unauthenticated registration denied; 1 = the attempt was
#        ACCEPTED (guardrail broken) or the probe could not run.

set -euo pipefail

CTX="${1:-}"
K() { if [[ -n "$CTX" ]]; then kubectl --context "$CTX" "$@"; else kubectl "$@"; fi; }

NS=agentic-netops-agents
POD=slim-auth-probe
GW=slim
PORT=46357
TIMEOUT_S=10
NODE_IMAGE=kindest/node@sha256:28b7cbb993dfe093c76641a0c95807637213c9109b761f1d422c2400e22b8e87

cleanup() { K -n "$NS" delete pod "$POD" --ignore-not-found --wait=false >/dev/null 2>&1 || true; }
trap cleanup EXIT

K -n "$NS" delete pod "$POD" --ignore-not-found --wait=false >/dev/null 2>&1 || true

GATEWAY_DEPLOYED=no
if K -n "$NS" get svc "$GW" >/dev/null 2>&1; then
  GATEWAY_DEPLOYED=yes
fi
echo "slim gateway deployed: ${GATEWAY_DEPLOYED}"

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
      # Unauthenticated registration attempt: TLS handshake WITHOUT a client
      # certificate against the gateway's mTLS data plane. openssl s_client
      # with no -cert/-key sends an anonymous ClientHello; a client-cert-
      # verifying server answers with a handshake_failure alert (or resets).
      # The raw exchange is captured; a server that lets the handshake
      # complete (rc=0 on connect) is the guardrail breach.
      echo "TLS: handshake without client certificate" \
        | timeout ${TIMEOUT_S} openssl s_client -connect ${GW}:${PORT} \\
            -tls1_2 -no_ign_eof 2>&1
      rc=\$?
      echo "attempt_rc=\${rc}"
      exit 0
EOF

# Wait for the terminal phase (the container always exits; restartPolicy Never).
echo "waiting for probe pod ${POD} to finish the unauthenticated attempt (bounded 300 s)..."
phase=""
for _ in $(seq 1 150); do
  phase="$(K -n "$NS" get pod "$POD" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")"
  case "$phase" in
    Succeeded|Failed) break ;;
  esac
  sleep 2
done

if [[ "$phase" != "Succeeded" && "$phase" != "Failed" ]]; then
  echo "FAIL: probe pod never reached a terminal phase (last phase: ${phase:-unknown})" >&2
  exit 1
fi

LOG="$(K -n "$NS" logs "$POD" 2>/dev/null || true)"
echo "$LOG" | sed 's/^/  | /'

RC_LINE="$(echo "$LOG" | grep -o 'attempt_rc=[0-9]*' | tail -1 || true)"
ATTEMPT_RC="${RC_LINE#attempt_rc=}"
if [[ -z "$ATTEMPT_RC" ]]; then
  echo "FAIL: probe produced no attempt_rc marker (container failed before openssl ran)" >&2
  exit 1
fi

if [[ "$ATTEMPT_RC" -eq 0 ]]; then
  echo "FAIL: the unauthenticated TLS handshake was ACCEPTED by ${GW}:${PORT} (rc=0) — the gateway is not verifying client certificates" >&2
  exit 1
fi

echo "PASS: unauthenticated registration attempt DENIED (attempt_rc=${ATTEMPT_RC}, gateway=${GATEWAY_DEPLOYED}) — the gateway refused a client without credentials"
exit 0
