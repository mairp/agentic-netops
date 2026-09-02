#!/bin/bash
# docker/mtls-proxy.sh — pod-local mTLS client proxy for the SLIM gateway.
#
# FR-024 (Decision 6): the gateway terminates TLS with client-certificate
# verification against the generated CA. The pinned agntcy-app-sdk 0.4.5
# SLIMTransport cannot present a client certificate (its tls surface is the
# single `insecure` flag), so the transport would be refused by the
# verifying gateway. This proxy closes that gap WITHOUT weakening the
# gateway: it terminates the client side of the mTLS session in the agent
# pod and forwards the plaintext stream to 127.0.0.1, so the SDK connects
# to TRANSPORT_SERVER_ENDPOINT=http://127.0.0.1:46357 and the gateway still
# only ever accepts TLS sessions authenticated by a per-agent certificate
# (mounted from Secret/slim-tls, one pair per agent identity).
#
# Env:
#   SLIM_TLS_DIR      dir with ca.crt, <SLIM_CLIENT_NAME>.crt/.key
#   SLIM_CLIENT_NAME  agent identity whose cert to present (default: pod name)
#   SLIM_UPSTREAM     host:port of the gateway (default: slim:46357)
#   SLIM_PROXY_PORT   local plaintext port     (default: 46357)
#
# Then `exec "$@"` — the agent process runs as PID 1's child replacement,
# so signals and the container lifecycle stay owned by the agent.

set -euo pipefail

SLIM_TLS_DIR=${SLIM_TLS_DIR:-/etc/slim/tls}
SLIM_CLIENT_NAME=${SLIM_CLIENT_NAME:-$(hostname)}
SLIM_UPSTREAM=${SLIM_UPSTREAM:-slim:46357}
SLIM_PROXY_PORT=${SLIM_PROXY_PORT:-46357}

echo "[mtls-proxy] 127.0.0.1:${SLIM_PROXY_PORT} -> ${SLIM_UPSTREAM} (client cert: ${SLIM_CLIENT_NAME})"
socat \
  "TCP4-LISTEN:${SLIM_PROXY_PORT},bind=127.0.0.1,fork,reuseaddr,keepalive" \
  "OPENSSL:${SLIM_UPSTREAM},verify=1,cafile=${SLIM_TLS_DIR}/ca.crt,cert=${SLIM_TLS_DIR}/${SLIM_CLIENT_NAME}.crt,key=${SLIM_TLS_DIR}/${SLIM_CLIENT_NAME}.key" \
  &
SOCAT_PID=$!

cleanup() {
  kill "${SOCAT_PID}" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

exec "$@"
