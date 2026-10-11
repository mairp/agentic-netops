#!/usr/bin/env bash
# SONiC VM (vrnetlab / containerlab sonic-vm kind) bootstrap: TLS + gNMI only.
#
# CONTEXT (different from sonic-vs): clab::bootstrap docker-exec's THIS script
# into the node container, but for the sonic-vm kind that container is the
# vrnetlab QEMU *launcher* — SONiC itself runs inside a VM. docker exec never
# reaches the guest. vrnetlab forwards guest TCP ports into the launcher
# namespace, so guest SSH (22) is reachable from here via the launcher's own
# mgmt IP (NOT 127.0.0.1 — see the credentials note below), and sshpass is
# baked into the vrnetlab sonic image. We provision the guest over SSH.
#
# What this script does inside the GUEST (all over SSH):
#   1. install TLS key/cert (mandatory .cer suffixes) into /etc/sonic/telemetry
#   2. merge gnmi_config_db.json (TELEMETRY|gnmi + TELEMETRY|certs) via
#      `config load` and persist it with `config save`
#   3. create the gNMI Linux user with the lab-generated password
#      (sonic-gnmi user_auth=password dials PAM/sshd, so the user must exist
#      in the guest with that password — same mechanism as the VS profile)
#   4. restart the gnmi service and wait for :8080 to listen
#
# Idempotence: clab::bootstrap gates on the /etc/agentic-netops/.bootstrapped
# marker in the launcher; every guest step here is also safe to re-run.
set -uo pipefail

# Credentials: vrnetlab's launch.py logs into the factory guest and RESETS the
# admin password to $PASSWORD (containerlab default: admin) during its own
# bootstrap — the factory YourPaSsWoRd is then rejected. Follow the env when
# present. NOTE: 127.0.0.1:22 is deliberately avoided as the guest address —
# the in-container loopback path into qemu's slirp hostfwd stalls (TCP accepts
# but the guest banner never returns); the launcher's own mgmt IP works.
ADMIN_USER=${SONIC_VM_ADMIN_USER:-${USERNAME:-admin}}
ADMIN_PASS=${SONIC_VM_ADMIN_PASS:-${PASSWORD:-admin}}
GUEST=${SONIC_VM_GUEST_ADDR:-$(hostname -i | awk '{print $1}')}
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 -o LogLevel=ERROR"

log() { echo "[vm-bootstrap] $*"; }
die() { echo "[vm-bootstrap] ERROR: $*" >&2; exit 1; }

command -v sshpass >/dev/null 2>&1 || die "sshpass not found in launcher (vrnetlab sonic image should provide it)"

# shellcheck disable=SC2086  # SSH_OPTS is intentionally word-split (multiple options)
gssh() { sshpass -p "$ADMIN_PASS" ssh $SSH_OPTS "${ADMIN_USER}@${GUEST}" "$@"; }
gscp() { sshpass -p "$ADMIN_PASS" scp $SSH_OPTS "$@"; }

# 0) Wait for the guest to finish booting (SONiC VM takes ~1-3 min; sshd is
# one of the last services). Bounded at ~10 minutes.
log "waiting for guest SSH on ${GUEST}:22 ..."
ready=0
for i in $(seq 1 60); do
  if gssh true 2>/dev/null; then ready=1; break; fi
  sleep 10
done
[[ "$ready" == 1 ]] || die "guest SSH never became reachable after 10 minutes"
log "guest SSH is up"

# 1) Stage TLS material + config snippet into the guest
gscp -q /etc/agentic-netops/gnmi/ca.crt  "${ADMIN_USER}@${GUEST}:/tmp/" || die "scp ca.crt failed"
gscp -q /etc/agentic-netops/gnmi/gnmi.crt "${ADMIN_USER}@${GUEST}:/tmp/" || die "scp gnmi.crt failed"
gscp -q /etc/agentic-netops/gnmi/gnmi.key "${ADMIN_USER}@${GUEST}:/tmp/" || die "scp gnmi.key failed"
gscp -q /etc/sonic/bootstrap/gnmi_config_db.json "${ADMIN_USER}@${GUEST}:/tmp/gnmi_config_db.json" || die "scp config snippet failed"
gscp -q /etc/sonic/bootstrap/install-gnmi-certs.sh "${ADMIN_USER}@${GUEST}:/tmp/install-gnmi-certs.sh" || die "scp cert installer failed"

# 2) Install certs + merge TELEMETRY config + persist
gssh "GNMI_CERT_SRC_DIR=/tmp/agentic-netops-gnmi bash -c '
  mkdir -p /tmp/agentic-netops-gnmi &&
  install -m 0644 /tmp/ca.crt  /tmp/agentic-netops-gnmi/ca.crt &&
  install -m 0644 /tmp/gnmi.crt /tmp/agentic-netops-gnmi/gnmi.crt &&
  install -m 0600 /tmp/gnmi.key /tmp/agentic-netops-gnmi/gnmi.key &&
  chmod +x /tmp/install-gnmi-certs.sh && /tmp/install-gnmi-certs.sh
'" || die "guest cert install failed"

gssh "sudo config load /tmp/gnmi_config_db.json -y" || die "config load of TELEMETRY snippet failed"
gssh "sudo config save -y" || log "WARN: config save failed; gNMI settings will not persist a guest reimage"

# 3) Create the gNMI Linux user inside the guest (PAM/sshd password auth)
# NOTE: parsed with sed, not jq — the vrnetlab launcher container has no jq.
creds_field() { sed -n 's/.*"'"$1"'"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$CREDS" 2>/dev/null | head -1; }
CREDS=/etc/sonic/bootstrap/gnmi_creds.json
if [[ -f "$CREDS" ]]; then
  GNMI_USER=$(creds_field username)
  GNMI_PASS=$(creds_field password)
fi
if [[ -n "${GNMI_USER:-}" && -n "${GNMI_PASS:-}" ]]; then
  gssh "sudo useradd -m -s /bin/bash '$GNMI_USER' 2>/dev/null; echo '$GNMI_USER:$GNMI_PASS' | sudo chpasswd" \
    || die "gNMI user creation in guest failed"
  log "created/updated gNMI user $GNMI_USER in guest"
else
  log "WARN: no gnmi_creds.json staged; gNMI password auth will fail"
fi

# 4) Restart gNMI and wait for the port (SONiC VM uses systemd)
gssh "sudo systemctl restart gnmi 2>/dev/null || sudo systemctl restart telemetry 2>/dev/null || true"
for i in $(seq 1 30); do
  if gssh "(exec 3<>/dev/tcp/127.0.0.1/8080) 2>/dev/null"; then
    log "gNMI port 8080 is listening in guest"
    log "completed"
    exit 0
  fi
  sleep 4
done

log "WARN: gNMI port 8080 not confirmed listening in guest after 2 minutes"
exit 1
