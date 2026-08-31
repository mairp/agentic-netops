#!/usr/bin/env bash
# AINETOPS lab telemetry service wrapper (SONiC 202605 gNMI stack).
# Reads the TELEMETRY table from /etc/sonic/config_db.json (file-based, so the
# service can start before redis is ready) and execs /usr/sbin/telemetry.
# Shape of TELEMETRY (sonic-gnmi 202605):
#   TELEMETRY|gnmi:   port, client_auth, user_auth, log_level
#   TELEMETRY|certs:  server_crt, server_key, ca_crt
#   TELEMETRY|CLIENTS: username, password (used when user_auth=password)
set -u

CONFIG_DB=/etc/sonic/config_db.json
# --gnmi_translib_write: the lab requires gNMI Set (capability gate, provider
# and SRv6 controller apply config via gNMI). The binary is built with the
# default (read-only) constant; this flag enables translib write at runtime.
TELEMETRY_ARGS=" -logtostderr --gnmi_translib_write"
export CVL_SCHEMA_PATH=/usr/sbin/schema
# The translib transformer loads the SONiC YANG model set from YANG_MODELS_PATH
# (the upstream default /usr/models/yang/ does not exist in this image; the
# models ship in /usr/local/yang-models/). Without this the xspec map is empty
# and sonic-* gNMI paths (sonic-srv6, sonic-telemetry, sonic-bgp, ...) do not
# resolve.
export YANG_MODELS_PATH=/usr/local/yang-models/
export GOTRACEBACK=crash

if [ -f "$CONFIG_DB" ]; then
  GNMI=$(jq -c '.TELEMETRY.gnmi // empty' "$CONFIG_DB" 2>/dev/null || true)
  CERTS=$(jq -c '.TELEMETRY.certs // empty' "$CONFIG_DB" 2>/dev/null || true)
else
  GNMI=""
  CERTS=""
fi

# TLS: use server cert/key when configured, else plaintext (pre-bootstrap state)
if [ -n "$CERTS" ]; then
  SERVER_CRT=$(echo "$CERTS" | jq -r '.server_crt // empty')
  SERVER_KEY=$(echo "$CERTS" | jq -r '.server_key // empty')
  if [ -z "$SERVER_CRT" ] || [ -z "$SERVER_KEY" ] || [ ! -f "$SERVER_CRT" ] || [ ! -f "$SERVER_KEY" ]; then
    echo "[telemetry] cert files missing; starting insecure (pre-bootstrap)" >&2
    TELEMETRY_ARGS+=" --insecure"
  else
    TELEMETRY_ARGS+=" --server_crt $SERVER_CRT --server_key $SERVER_KEY"
    CA_CRT=$(echo "$CERTS" | jq -r '.ca_crt // empty')
    if [ -n "$CA_CRT" ] && [ -f "$CA_CRT" ]; then
      TELEMETRY_ARGS+=" --ca_crt $CA_CRT"
    fi
  fi
else
  TELEMETRY_ARGS+=" --insecure"
fi

# Port
PORT=8080
if [ -n "$GNMI" ]; then
  PORT=$(echo "$GNMI" | jq -r '.port // "8080"')
  if ! [[ "$PORT" =~ ^[0-9]+$ ]]; then
    echo "[telemetry] invalid port '$PORT'; using 8080" >&2
    PORT=8080
  fi
fi
TELEMETRY_ARGS+=" --port $PORT"

# Client certificate handling
CLIENT_AUTH=""
USER_AUTH=""
if [ -n "$GNMI" ]; then
  CLIENT_AUTH=$(echo "$GNMI" | jq -r '.client_auth // empty')
  USER_AUTH=$(echo "$GNMI" | jq -r '.user_auth // empty')
fi
if [ -z "$CLIENT_AUTH" ] || [ "$CLIENT_AUTH" = "false" ]; then
  TELEMETRY_ARGS+=" --allow_no_client_auth"
fi
if [ -n "$USER_AUTH" ] && [ "$USER_AUTH" != "null" ]; then
  TELEMETRY_ARGS+=" --client_auth $USER_AUTH"
fi

# Log level
LOG_LEVEL=""
[ -n "$GNMI" ] && LOG_LEVEL=$(echo "$GNMI" | jq -r '.log_level // empty')
if [[ "$LOG_LEVEL" =~ ^[0-9]+$ ]]; then
  TELEMETRY_ARGS+=" -v=$LOG_LEVEL"
else
  TELEMETRY_ARGS+=" -v=2"
fi

echo "telemetry args: $TELEMETRY_ARGS" >&2
exec /usr/sbin/telemetry ${TELEMETRY_ARGS}
