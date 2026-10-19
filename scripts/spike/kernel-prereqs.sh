#!/usr/bin/env bash
# kernel-prereqs.sh <node> — spike-kernel-<node> proof bodies (T066-T068).
# Confirms, on the live guest, the three kernel prerequisites the recipe lists
# for SRv6 (docs/SRV6_SERVICE_RECIPE.md §1 approaches): seg6_enabled=1, the
# vrf kernel module (proven by creating and removing a throwaway VRF device),
# and net.vrf.strict_mode. Every section is state-independent so the proof
# replays byte-identically: values are (re-)set before being read back, the
# module load is conditional and silent, and the throwaway VRF is removed in
# the same run. Measured on first contact (pre-state, recorded here only as a
# finding, not in this deterministic proof): all five seg6_enabled keys were 0
# at boot, the vrf module was not loaded, and /proc/sys/net/vrf did not exist
# until modprobe. State changes need sudo (the admin user has neither
# CAP_NET_ADMIN nor root; the sysctl binary is absent on this image).
set -u
. "$(dirname "$0")/spike-env.sh"

n=${1:?node required}
c=$(container_of "$n")

echo "===== $n: seg6_enabled set to 1 via /proc, read back ====="
node_run "$c" "for k in all default Ethernet0 Ethernet4 Loopback0; do sudo sh -c \"echo 1 > /proc/sys/net/ipv6/conf/\$k/seg6_enabled\" 2>/dev/null; done; for k in all default Ethernet0 Ethernet4 Loopback0; do printf '%s=' \$k; cat /proc/sys/net/ipv6/conf/\$k/seg6_enabled 2>/dev/null || echo missing; done" || true

echo "===== $n: vrf module loaded, proven by link add/del ====="
node_run "$c" "grep -qE '^vrf ' /proc/modules || sudo modprobe vrf 2>/dev/null; lsmod | grep -E '^vrf'" || true
node_run "$c" "sudo ip link add .spike_vrf type vrf table 59997 && echo vrf-link-add-OK && sudo ip link del .spike_vrf && echo vrf-link-del-OK" || true

echo "===== $n: net.vrf.strict_mode set to 1 via /proc, read back ====="
node_run "$c" "sudo sh -c 'echo 1 > /proc/sys/net/vrf/strict_mode' 2>/dev/null; printf 'strict_mode='; cat /proc/sys/net/vrf/strict_mode 2>/dev/null || echo no-proc-entry" || true

echo "===== $n: seg6_action + ipv6 forwarding (reference values) ====="
node_run "$c" "printf 'seg6_action='; cat /proc/sys/net/ipv6/conf/all/seg6_action 2>/dev/null || echo no-proc-entry; printf 'forwarding='; cat /proc/sys/net/ipv6/conf/all/forwarding" || true
