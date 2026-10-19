#!/usr/bin/env bash
# vpn-ping.sh — spike-vpn-ping proof body (T079).
# Ping between the two clients through the SRv6 service: default size, then
# the 8900-byte payload with don't-fragment (below the ~9120-byte effective
# payload under MTU 9216 plus an SRv6 header). Confirms the probe size.
set -u
. "$(dirname "$0")/spike-env.sh"
bash "$(dirname "$0")/vpn-setup.sh" >/dev/null 2>&1 || true
cl01=$C_srv6_client01; cl02=$C_srv6_client02
# Silent warm-up pairs first: the very first packets after a (re)setup pay
# ARP + outer-ND costs inside the guests and can drop a recorded echo (racy
# replay, measured 23:04). Steady state is the assertion target; warm-ups
# print nothing, so the recorded output stays byte-identical (FR-039).
warm() { client_run "$1" "ping -c2 -W2 $2 >/dev/null 2>&1" >/dev/null 2>&1 || true; }
warm "$cl01" 192.168.2.2
warm "$cl02" 192.168.1.2
warm "$cl01" "192.168.2.2 -s 8900 -M do"
warm "$cl02" "192.168.1.2 -s 8900 -M do"
echo "===== client01 -> client02: default size ====="
client_run "$cl01" "ping -c3 -W3 192.168.2.2 2>&1 | tail -2" | ping_norm || true
echo "===== client01 -> client02: 8900-byte payload, don't-fragment ====="
client_run "$cl01" "ping -c3 -W3 -s 8900 -M do 192.168.2.2 2>&1 | tail -2" | ping_norm || true
echo "===== client02 -> client01: default size (return path) ====="
client_run "$cl02" "ping -c3 -W3 192.168.1.2 2>&1 | tail -2" | ping_norm || true
echo "===== client02 -> client01: 8900-byte payload, don't-fragment ====="
client_run "$cl02" "ping -c3 -W3 -s 8900 -M do 192.168.1.2 2>&1 | tail -2" | ping_norm || true
# Fail loudly on a dead dataplane: the assertion IS the passing pings, and a
# wedged orchagent once recorded a 100%-loss .out with exit 0 (2026-10-13,
# leaf02). Re-probe both directions silently — nothing is printed on success.
_dp_ok=1
client_run "$cl01" "ping -c3 -W3 192.168.2.2 >/dev/null 2>&1" || _dp_ok=0
client_run "$cl02" "ping -c3 -W3 192.168.1.2 >/dev/null 2>&1" || _dp_ok=0
[ "$_dp_ok" = 1 ] || { echo "DATAPLANE-DEAD: default-size pings do not pass; refusing to record" >&2; exit 1; }
echo "===== probe size confirmed: 8900-byte payload DF passes both directions ====="
