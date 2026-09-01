#!/usr/bin/env bash
# Idempotently install gNMI TLS certs into /etc/sonic/telemetry
set -euo pipefail

dst=/etc/sonic/telemetry
src=${GNMI_CERT_SRC_DIR:-/etc/ainetops/gnmi}
mkdir -p "$dst"
# NOTE: .cer suffixes are mandatory — sonic-telemetry YANG validates cert paths
# against "(/[a-zA-Z0-9_-]+)*/([a-zA-Z0-9_-]+).cer", and GCU validates the ENTIRE
# CONFIG_DB before any patch (docs/SRV6_GNMI_CAPABILITY_FINDINGS.md §4.1), so a
# ".crt" path in TELEMETRY|certs makes every GCU write fail with Data Loading Failed.
install -m 0600 -T "$src/gnmi.key" "$dst/gnmi.key"
install -m 0644 -T "$src/gnmi.crt" "$dst/gnmi.cer"
install -m 0644 -T "$src/ca.crt" "$dst/ca.cer"

echo "[install-gnmi-certs] installed certs to $dst"
