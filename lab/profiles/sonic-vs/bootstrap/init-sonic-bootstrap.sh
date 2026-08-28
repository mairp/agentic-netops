#!/usr/bin/env bash
# Minimal SONiC VS bootstrap: TLS + gNMI enable only. No underlay config.
set -euo pipefail

echo "[bootstrap] starting minimal SONiC bootstrap for gNMI"

# 1) Install TLS certs
if [[ -x /etc/sonic/bootstrap/install-gnmi-certs.sh ]]; then
  /etc/sonic/bootstrap/install-gnmi-certs.sh
fi

# 2) Enable telemetry/gNMI via CONFIG_DB overlay if present
if [[ -f /etc/sonic/bootstrap/gnmi_config_db.json ]]; then
  jq -s '.[0] * .[1]' /etc/sonic/config_db.json /etc/sonic/bootstrap/gnmi_config_db.json > /etc/sonic/config_db.json.tmp
  mv /etc/sonic/config_db.json.tmp /etc/sonic/config_db.json
  echo "[bootstrap] merged gNMI telemetry settings into CONFIG_DB"
fi

# 3) Ensure telemetry service is enabled (systemd inside container)
if command -v systemctl >/dev/null 2>&1; then
  systemctl enable telemetry.service || true
  systemctl restart telemetry.service || true
fi

echo "[bootstrap] completed"
