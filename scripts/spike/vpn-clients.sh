#!/usr/bin/env bash
# vpn-clients.sh — spike-vpn-clients proof body (T078).
# The addresses and routes srv6-client01 and srv6-client02 need for
# client-to-client traffic: the builder re-asserts them (idempotent) and the
# proof reads both clients' eth1 addresses and routes back.
set -u
. "$(dirname "$0")/spike-env.sh"
# vpn-setup exits non-zero when a leaf's kernel VRF state is stuck (wedged
# orchagent): fail loudly instead of recording an unprogrammed dataplane.
bash "$(dirname "$0")/vpn-setup.sh" || exit 1
echo "===== srv6-client01: address and routes ====="
client_run "$C_srv6_client01" "ip -4 -br addr show eth1" | addr_norm || true
client_run "$C_srv6_client01" "ip route show" || true
echo "===== srv6-client02: address and routes ====="
client_run "$C_srv6_client02" "ip -4 -br addr show eth1" | addr_norm || true
client_run "$C_srv6_client02" "ip route show" || true
echo "===== gateways reachable inside the VRFs ====="
client_run "$C_srv6_client01" "ping -c2 -W2 192.168.1.1 2>&1 | tail -2" | ping_norm || true
client_run "$C_srv6_client02" "ping -c2 -W2 192.168.2.1 2>&1 | tail -2" | ping_norm || true
# Fail loudly when a VRF gateway is unreachable: that is the half-programmed
# VRF signature (CONFIG_DB rows present, kernel address never programmed —
# 2026-10-13, leaf02), and the recorded loss above must not pass silently.
_gw_ok=1
client_run "$C_srv6_client01" "ping -c2 -W2 192.168.1.1 >/dev/null 2>&1" || _gw_ok=0
client_run "$C_srv6_client02" "ping -c2 -W2 192.168.2.1 >/dev/null 2>&1" || _gw_ok=0
[ "$_gw_ok" = 1 ] || { echo "GATEWAY-UNREACHABLE: in-VRF gateway ping failed" >&2; exit 1; }
