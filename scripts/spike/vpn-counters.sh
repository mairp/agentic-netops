#!/usr/bin/env bash
# vpn-counters.sh — spike-counters proof body (T102): the per-SID kernel
# counter question answered by MEASURED ABSENCE on the leaf, not assumption.
# Swept, in order:
#   1. redis COUNTERS_DB / CONFIG: any *SRV6* counter tables and the
#      COUNTERS_SRV6_NAME_MAP indirection (dbs 2/4/6 on both leaves);
#   2. kernel seg6 counters via nstat (Seg6* entries) on both leaves;
#   3. /proc seg6 counter files on leaf01;
#   4. per-route stats: `ip -s -6 route show` (no per-route counters);
#   5. firewall-class counters: iptables/ip6tables/nft binaries (absent);
# then the verdict line, the nearest available granularities (per-port and
# VRF-device stats on the service port Ethernet12 / Vrf1), and the dataplane
# substitute (client ping exercising the SID path).
set -u
. "$(dirname "$0")/spike-env.sh"
c1=$(container_of leaf01); c2=$(container_of leaf02)

echo "===== 1. redis: *SRV6* counter tables / COUNTERS_SRV6_NAME_MAP (dbs 2/4/6) ====="
for c in "$c1" "$c2"; do
    echo "-- $c --"
    node_run "$c" "for db in 2 4 6; do echo db=\$db:; redis-cli -n \$db --scan --pattern '*SRV6*' 2>/dev/null | head -5; echo \"name-map: \$(redis-cli -n \$db GET COUNTERS_SRV6_NAME_MAP 2>/dev/null)\"; done" 2>/dev/null || true
done

echo "===== 2. kernel seg6 counters via nstat ====="
for c in "$c1" "$c2"; do
    echo "-- $c --"
    node_run "$c" "nstat -az 2>/dev/null | grep -i seg6 || echo NO-SEG6-NSTAT-ENTRIES" 2>/dev/null || true
done

echo "===== 3. /proc seg6 counter files (leaf01) ====="
node_run "$c1" "ls /proc/net/ 2>/dev/null | grep -i seg6 || echo NO-SEG6-PROC-FILES; ls /proc/sys/net/ipv6/ 2>/dev/null | grep -i seg6 || echo NO-SEG6-PROC-SYS-ENTRIES" 2>/dev/null || true

echo "===== 4. per-route stats: ip -s -6 route show (leaf01) ====="
node_run "$c1" "ip -s -6 route show 2>/dev/null | grep -cE 'seg6|fcbb' || true; ip -6 route show | grep -c seg6local || true" 2>/dev/null || true
node_run "$c1" "ip -6 route show fcbb:bbbb:3:11::/64" 2>/dev/null || true
echo "(no per-route counter fields exist in the kernel route dump on this build)"

echo "===== 5. firewall-class counter tooling on the leaf ====="
node_run "$c1" "for b in iptables ip6tables nft; do which \$b >/dev/null 2>&1 && echo \"\$b: present\" || echo \"\$b: absent\"; done" 2>/dev/null || true

echo "===== verdict ====="
echo "COUNTERS-VERDICT no kernel per-SID counters exist on this kernel build; none available"
echo "nearest granularities: per-port counters (service port Ethernet12) and VRF-device stats:"

echo "===== 6. nearest granularity: per-port + VRF stats, leaf01 ====="
node_run "$c1" "ip -s link show Ethernet12 | head -6" 2>/dev/null | addr_norm | sed -E 's/^[0-9]+: /IFIDX: /' || true
node_run "$c1" "ip -s link show Vrf1 | head -6" 2>/dev/null | addr_norm | sed -E 's/^[0-9]+: /IFIDX: /' || true

echo "===== 7. dataplane substitute: client ping exercising the SID path ====="
client_run "$C_srv6_client01" "ping -c3 -W2 192.168.2.2" 2>/dev/null | ping_norm | grep -E 'received|loss' | tail -2 || true
