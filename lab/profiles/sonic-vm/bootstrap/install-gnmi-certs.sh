#!/usr/bin/env bash
# Idempotently install gNMI TLS certs into /etc/sonic/telemetry (VM variant).
#
# Unlike the sonic-vs variant (which runs INSIDE the SONiC container), this
# script runs inside the guest SONiC VM: the launcher-side init script
# (init-sonic-bootstrap.sh) copies the staged TLS material into the guest and
# invokes this over SSH. Paths and the mandatory .cer suffixes are identical
# to sonic-vs — sonic-telemetry YANG validates cert paths against
# "(/[a-zA-Z0-9_-]+)*/([a-zA-Z0-9_-]+).cer", and GCU validates the ENTIRE
# CONFIG_DB before any patch, so a ".crt" path in TELEMETRY|certs makes every
# GCU write fail with Data Loading Failed.
set -euo pipefail

dst=/etc/sonic/telemetry
src=${GNMI_CERT_SRC_DIR:-/tmp/agentic-netops-gnmi}
sudo mkdir -p "$dst"
sudo install -m 0600 -T "$src/gnmi.key" "$dst/gnmi.key"
sudo install -m 0644 -T "$src/gnmi.crt" "$dst/gnmi.cer"
sudo install -m 0644 -T "$src/ca.crt" "$dst/ca.cer"

echo "[install-gnmi-certs] installed certs to $dst"
