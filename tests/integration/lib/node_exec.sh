#!/usr/bin/env bash
# node_exec.sh — dispatch a command into the SONiC node from a suite.
#
# sonic-vs profile: the container IS the SONiC switch; docker exec works.
# sonic-vm profile: the container is the vrnetlab QEMU *launcher* and the
# SONiC OS runs inside the guest VM — config/redis-cli/ip exist only in the
# guest, so node-side operations route over SSH (vrnetlab forwards guest :22
# to the launcher's mgmt address; credentials come from the container env
# USERNAME/PASSWORD which vrnetlab's bootstrap set on the guest).

# node_is_vm <container> — true when the container is a sonic-vm launcher
node_is_vm() {
  [[ "$(docker inspect "$1" --format '{{index .Config.Labels "clab-node-kind"}}' 2>/dev/null)" == "sonic-vm" ]]
}

# node_guest_addr <container> — the launcher's mgmt IP (guest SSH entry point)
node_guest_addr() {
  docker inspect "$1" --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}'
}

# node_run <container> <command-string> — run in the SONiC node (no stdin)
# `-n` is contract, not style: without it the ssh channel consumes the
# caller's stdin, so a node_run inside a `while read` loop silently ended
# the loop after its first line (measured 2026-10-14: the configure-fabric
# pin loop installed only the first plan pin per node, and the baseline
# underlay check asserted only the Ethernet0 links).
# ConnectTimeout + ServerAlive are the unattended-run contract (2026-10-14:
# the q3-fabric suite hung 10+ min with no observable progress when a guest
# stopped answering — an ssh with no bounds waits forever): a connect fails
# in 15s and a silent session in ~60s, so a wedged guest records a RED check
# instead of stalling the whole battery.
node_run() {
  local c=$1; shift
  if node_is_vm "$c"; then
    local ip
    ip=$(node_guest_addr "$c")
    sshpass -p "${GUEST_PASS:-admin}" ssh -n -o StrictHostKeyChecking=no \
      -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
      -o ConnectTimeout=15 -o ServerAliveInterval=15 -o ServerAliveCountMax=4 \
      "${GUEST_USER:-admin}@${ip}" "$*"
  else
    docker exec "$c" bash -c "$*"
  fi
}

# node_sudo <container> — privilege prefix for node-side write commands.
# The sonic-vm guest SSH login is a non-root admin user, so node-side writes
# need sudo; the sonic-vs container already runs as root and ships no sudo
# binary — a hardcoded `sudo ...` there exits 127, which under `set -euo
# pipefail` both kills the calling check and (from a suite's EXIT trap)
# silently overrides a passing check's exit status (measured 2026-10-14:
# every core gNMI check on sonic-vs recorded fail despite green assertions).
# Bake the prefix at call time: node_run "$c" "$(node_sudo "$c") config save -y"
node_sudo() {
  if node_is_vm "$1"; then printf 'sudo'; else printf ''; fi
}

# node_run_i <container> <command-string> — run with stdin piped through
# Same bounds as node_run (unattended-run contract; see above).
node_run_i() {
  local c=$1; shift
  if node_is_vm "$c"; then
    local ip
    ip=$(node_guest_addr "$c")
    sshpass -p "${GUEST_PASS:-admin}" ssh -o StrictHostKeyChecking=no \
      -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
      -o ConnectTimeout=15 -o ServerAliveInterval=15 -o ServerAliveCountMax=4 \
      "${GUEST_USER:-admin}@${ip}" "$*"
  else
    docker exec -i "$c" bash -c "$*"
  fi
}
