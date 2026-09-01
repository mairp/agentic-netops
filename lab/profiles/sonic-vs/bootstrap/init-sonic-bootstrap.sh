#!/usr/bin/env bash
# Minimal SONiC VS bootstrap: TLS + gNMI enable only. No underlay config.
# The lab image runs supervisord (no systemd): the telemetry program is defined
# in /etc/supervisor/conf.d/telemetry.conf and (re)started here after the
# TELEMETRY config is merged into /etc/sonic/config_db.json and reloaded into redis.
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
  echo "[bootstrap] merged gNMI telemetry settings into /etc/sonic/config_db.json"
  # Reload merged config into redis CONFIG_DB (same loader start.sh uses)
  if [[ -x /usr/bin/configdb-load.sh ]]; then
    /usr/bin/configdb-load.sh
    echo "[bootstrap] reloaded CONFIG_DB"
  fi
fi

# 2b) Create the gNMI account as a Linux user.
# sonic-gnmi's user_auth=password path (basicAuth.go -> PopulateAuthStruct ->
# UserPwAuth) authenticates the gNMI username/password against the container
# itself: PopulateAuthStruct does user.Lookup() in /etc/passwd and UserPwAuth
# dials sshd on 127.0.0.1:22 with the offered password. The account must exist
# as a local user with the same password and sshd must be listening.
# NOTE: credentials come from a dedicated file, never from a TELEMETRY|CLIENTS
# CONFIG_DB table — the sonic-telemetry YANG models no CLIENTS list, so that
# table poisons GCU whole-config validation (every apply-patch would fail).
CREDS=/etc/sonic/bootstrap/gnmi_creds.json
if [[ -f "$CREDS" ]]; then
  GNMI_USER=$(jq -r '.username // empty' "$CREDS")
  GNMI_PASS=$(jq -r '.password // empty' "$CREDS")
elif [[ -f /etc/sonic/config_db.json ]]; then
  GNMI_USER=$(jq -r '.TELEMETRY.CLIENTS.username // empty' /etc/sonic/config_db.json)
  GNMI_PASS=$(jq -r '.TELEMETRY.CLIENTS.password // empty' /etc/sonic/config_db.json)
fi
if [ -n "$GNMI_USER" ] && [ -n "$GNMI_PASS" ]; then
  if ! id -u "$GNMI_USER" >/dev/null 2>&1; then
    useradd -m -s /bin/bash "$GNMI_USER"
    echo "[bootstrap] created gNMI linux user $GNMI_USER"
  fi
  echo "$GNMI_USER:$GNMI_PASS" | chpasswd
  echo "[bootstrap] set gNMI user password"
else
  echo "[bootstrap] WARN: no TELEMETRY|CLIENTS credentials found; gNMI password auth will fail" >&2
fi

# 2c) Ensure sshd is listening on 127.0.0.1:22 (UserPwAuth target).
if command -v sshd >/dev/null 2>&1 || [ -x /usr/sbin/sshd ]; then
  if ! (exec 3<>/dev/tcp/127.0.0.1/22) 2>/dev/null; then
    ssh-keygen -A >/dev/null 2>&1 || true
    mkdir -p /var/run/sshd
    if supervisorctl status sshd >/dev/null 2>&1; then
      supervisorctl start sshd >/dev/null 2>&1 || /usr/sbin/sshd || true
    else
      /usr/sbin/sshd || true
    fi
    echo "[bootstrap] started sshd for gNMI password auth"
  fi
else
  echo "[bootstrap] WARN: no sshd in image; gNMI password auth cannot succeed" >&2
fi

# 3) Restart the telemetry service (supervisord program)
if command -v supervisorctl >/dev/null 2>&1; then
  supervisorctl status telemetry >/dev/null 2>&1 \
    && supervisorctl restart telemetry \
    || echo "[bootstrap] telemetry program not registered yet; supervisord will start it"
fi

# 4) Wait for the gNMI port to listen (bounded)
for i in $(seq 1 30); do
  if (exec 3<>"/dev/tcp/127.0.0.1/8080") 2>/dev/null; then
    exec 3>&- 3<&- || true
    echo "[bootstrap] gNMI port 8080 is listening"
    break
  fi
  sleep 2
done

echo "[bootstrap] completed"
