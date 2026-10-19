#!/usr/bin/env bash
# install-executor-key.sh — per-lab SSH key material for the fabric executor's
# transport on the sonic-vm profile (T170-T172).
#
# The executor's ssh transport authenticates with a KEY, never a password and
# never a secret on the command line (contracts/executor-transport.md): FABRIC_SSH_KEY
# (0600) + FABRIC_SSH_KNOWN_HOSTS (0600, StrictHostKeyChecking=yes). This
# script produces that per-lab material and installs the public half into every
# sonic-vm guest:
#
#   secrets/fabric-executor.key(.pub)  ed25519 pair, generated once per lab
#                                      bring-up (containerlab.sh destroy
#                                      removes them — host keys change per lab)
#   secrets/known_hosts_executor       the guests' host keys, keyed by the
#                                      address the executor connects to (the
#                                      launcher's mgmt IP, which forwards :22
#                                      to the guest). Key TYPE is whatever the
#                                      guest image ships — the pinned sonic-vm
#                                      runs a FIPS OpenSSH that offers ssh-rsa
#                                      only (no ed25519 host key; seen live on
#                                      the 2026-10-14 bring-up) — so both the
#                                      readiness wait and the capture scan all
#                                      types instead of forcing one.
#
# Done when `ssh -o BatchMode=yes -o StrictHostKeyChecking=yes` succeeds for
# every node WITHOUT the password (the executor never carries one).
#
# Runs on the HOST as part of the sonic-vm bootstrap (containerlab.sh),
# fail-closed: any node that cannot be reached with the key fails the
# bootstrap. sshpass/admin is used exactly once per node, to append the
# public key — the factory guest password (vrnetlab resets it per lab).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
SECRETS_DIR="${REPO_ROOT}/secrets"
KEY="${SECRETS_DIR}/fabric-executor.key"
KEY_PUB="${KEY}.pub"
KH="${SECRETS_DIR}/known_hosts_executor"
NODES=(spine01 spine02 leaf01 leaf02)
# Launcher mgmt addresses: the lab topology (lab/topology.sonic-vm.clab.yml)
# pins each VM's launcher to its mgmt-ipv4 on the 172.31.0.0/16 mgmt network.
declare -A ADDR=( [spine01]=172.31.0.11 [spine02]=172.31.0.12 [leaf01]=172.31.0.21 [leaf02]=172.31.0.22 )

command -v ssh-keygen >/dev/null || { echo "missing ssh-keygen" >&2; exit 2; }
command -v sshpass >/dev/null || { echo "missing sshpass (one-time public-key install)" >&2; exit 2; }
command -v ssh-keyscan >/dev/null || { echo "missing ssh-keyscan" >&2; exit 2; }

mkdir -p "$SECRETS_DIR"
if [[ ! -f "$KEY" || ! -f "$KEY_PUB" ]]; then
  echo "[executor-key] generating ed25519 keypair ${KEY}"
  rm -f "$KEY" "$KEY_PUB"
  ssh-keygen -q -t ed25519 -N '' -C agentic-netops-fabric-executor -f "$KEY"
fi
chmod 600 "$KEY"

echo "[executor-key] waiting for guest SSH on ${NODES[*]}"
for n in "${NODES[@]}"; do
  up=0
  for i in $(seq 1 60); do
    if ssh-keyscan -T 5 "${ADDR[$n]}" >/dev/null 2>&1; then up=1; break; fi
    sleep 10
  done
  [[ "$up" -eq 1 ]] || { echo "ERROR: ${n} (${ADDR[$n]}) SSH never came up" >&2; exit 1; }
done

echo "[executor-key] installing the public key into each guest (one password auth per node)"
pub="$(cat "$KEY_PUB")"
for n in "${NODES[@]}"; do
  # The key line is written inline (printf) — NOT via stdin — because the ssh
  # call runs with </dev/null and a stdin-fed `cat >>` would append nothing
  # while the trailing chmod still exits 0 (seen live, 2026-10-14).
  sshpass -p admin ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o ConnectTimeout=15 "admin@${ADDR[$n]}" \
    "umask 077; mkdir -p ~/.ssh && { grep -qxF '$pub' ~/.ssh/authorized_keys 2>/dev/null || printf '%s\n' '$pub' >> ~/.ssh/authorized_keys; } && chmod 700 ~/.ssh && chmod 600 ~/.ssh/authorized_keys" \
    </dev/null || { echo "ERROR: could not install the public key on ${n}" >&2; exit 1; }
done

echo "[executor-key] capturing guest host keys into ${KH}"
: > "$KH"
for n in "${NODES[@]}"; do
  ssh-keyscan -T 10 "${ADDR[$n]}" >> "$KH" 2>/dev/null \
    || { echo "ERROR: ssh-keyscan failed for ${n}" >&2; exit 1; }
done
chmod 600 "$KH"

echo "[executor-key] verifying passwordless batch SSH per node"
errf="${SECRETS_DIR}/.executor-key-ssherr.$$"
trap 'rm -f "$errf"' EXIT
for n in "${NODES[@]}"; do
  # stdout must be exactly "ok"; stderr is kept separate because the guest
  # sshd prints a Banner (/etc/issue) to stderr on every session (seen live,
  # 2026-10-14) — mixing the streams with 2>&1 would break the exact match.
  out=$(ssh -o BatchMode=yes -o StrictHostKeyChecking=yes \
        -o UserKnownHostsFile="$KH" -o ConnectTimeout=15 \
        -i "$KEY" "admin@${ADDR[$n]}" 'echo ok' </dev/null 2>"$errf") \
    || { echo "ERROR: BatchMode SSH failed for ${n}: $(cat "$errf")" >&2; exit 1; }
  [[ "$out" == "ok" ]] || { echo "ERROR: unexpected reply from ${n}: ${out}" >&2; exit 1; }
  echo "[executor-key] ${n} (${ADDR[$n]}): BatchMode SSH ok"
done
echo "[executor-key] done: ${KEY} + ${KH} (0600) ready for FABRIC_SSH_KEY / FABRIC_SSH_KNOWN_HOSTS"
