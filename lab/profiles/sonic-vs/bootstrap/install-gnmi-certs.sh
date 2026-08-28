#!/usr/bin/env bash
# Idempotently install gNMI TLS certs into /etc/sonic/telemetry
set -euo pipefail

dst=/etc/sonic/telemetry
src=${GNMI_CERT_SRC_DIR:-/etc/ainetops/gnmi}
mkdir -p "$dst"
install -m 0600 -T "$src/gnmi.key" "$dst/gnmi.key"
install -m 0644 -T "$src/gnmi.crt" "$dst/gnmi.crt"
install -m 0644 -T "$src/ca.crt" "$dst/ca.crt"

echo "[install-gnmi-certs] installed certs to $dst"
