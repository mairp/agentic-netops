#!/usr/bin/env bash
# kernel-vrf-module.sh — spike-kernel-vrf-module proof body (T067).
# Whether the `vrf` module must be loaded on leaf01 and how: module state
# before, `modprobe vrf`, and a real VRF device create/delete to show the
# module is what answers VRF requests. Admin needs sudo (no CAP_NET_ADMIN).
set -u
. "$(dirname "$0")/spike-env.sh"
c=$(container_of leaf01)
echo "--- module state before ---"
node_run "$c" "lsmod | grep -E '^vrf ' || echo 'vrf module not loaded'" || true
echo "--- how it is set on this guest: sudo modprobe vrf ---"
node_run "$c" "sudo modprobe vrf && echo 'modprobe vrf: ok'" || true
node_run "$c" "lsmod | grep -E '^vrf '" || true
echo "--- proof the module serves VRF devices: create + delete a scratch VRF ---"
node_run "$c" "sudo ip link add .spike_vrf type vrf table 50001 && ip -d link show .spike_vrf | head -1 | sed 's/[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]:[0-9a-f][0-9a-f]/MAC/' && sudo ip link del .spike_vrf && echo 'scratch VRF ok'" || true
echo "--- persistence: module is autoloaded on demand (no boot entry needed) ---"
node_run "$c" "grep -r vrf /etc/modules-load.d/ 2>/dev/null || echo 'no modules-load entry; kernel auto-loads vrf on first VRF device'" || true
