# SONiC VS Profile — Limited Bootstrap

Scope: Limit bootstrap to management reachability, TLS materials, gNMI service enablement, and
persistence mounts. No underlay/overlay control-plane or data-plane configuration is applied
by this profile.

Bootstrap contents:
- Management interface is provided by containerlab mgmt network (mgmt0).
- TLS key/cert are mounted into /etc/sonic/telemetry/ and permissions set.
- gNMI/telemetry service is enabled with TLS only; JSON_IETF is the required encoding.
- Persistent configuration is stored under /etc/sonic via a named Docker volume
  (agentic-netops-${clab-node-name}-etc-sonic) to survive container restarts.

Artifacts:
- gnmi_config_db.json — minimal CONFIG_DB snippet enabling gNMI/telemetry with TLS paths.
- install-gnmi-certs.sh — idempotent installer for TLS key/cert into the running container.
- init-sonic-bootstrap.sh — orchestrates TLS install and telemetry service enablement.
