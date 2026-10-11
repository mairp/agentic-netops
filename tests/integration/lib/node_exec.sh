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
node_run() {
  local c=$1; shift
  if node_is_vm "$c"; then
    local ip
    ip=$(node_guest_addr "$c")
    sshpass -p "${GUEST_PASS:-admin}" ssh -o StrictHostKeyChecking=no \
      -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
      "${GUEST_USER:-admin}@${ip}" "$*"
  else
    docker exec "$c" bash -c "$*"
  fi
}

# node_run_i <container> <command-string> — run with stdin piped through
node_run_i() {
  local c=$1; shift
  if node_is_vm "$c"; then
    local ip
    ip=$(node_guest_addr "$c")
    sshpass -p "${GUEST_PASS:-admin}" ssh -o StrictHostKeyChecking=no \
      -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR \
      "${GUEST_USER:-admin}@${ip}" "$*"
  else
    docker exec -i "$c" bash -c "$*"
  fi
}
