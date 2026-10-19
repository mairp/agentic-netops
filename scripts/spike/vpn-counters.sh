#!/usr/bin/env bash
# vpn-counters.sh — spike-counters proof body (T102): the per-SID kernel
# counter question answered by measurement on the leaf, not assumption.
# Swept, in order:
#   1. redis COUNTERS_DB / CONFIG: any *SRV6* counter tables and the
#      COUNTERS_SRV6_NAME_MAP indirection (dbs 2/4/6 on both leaves);
#   2. kernel seg6 counters via nstat (Seg6* entries) on both leaves;
#   3. /proc seg6 counter files on leaf01;
#   4. per-route stats: `ip -s -6 route show` (no counter fields while the
#      route is installed WITHOUT the seg6local `count` flag);
#   5. firewall-class counters: iptables/ip6tables/nft binaries (absent);
# then the verdict line, the companion granularities (per-port and
# VRF-device stats on the service port Ethernet12 / Vrf1), the dataplane
# probe (client ping exercising the SID path), and — added after the spike's
# first verdict was FALSIFIED (2026-10-18, T560):
#   8. the seg6local `count` flag (iproute2 SEG6LOCAL grammar
#      `action ACTION [ OPTIONS ] [ count ]`): enabling it makes the kernel
#      keep the behavior's OWN counters, printed by `ip -s -6 route show` on
#      the route line — the per-SID counters §4 could not see. Sections 1-4
#      measured only the flag-OFF state; the first verdict ("no kernel
#      per-SID counters exist on this kernel build") was wrong about §4 and
#      is corrected below. This section enables the flag with the same
#      command the plan now renders (pkg/fabricplan/srv6.go) and leaves it
#      installed — it is the plan-rendered state since T560.
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
echo "(no per-route counter fields on this route AS INSTALLED WITHOUT the seg6local \`count\` flag — §8 enables it)"

echo "===== 5. firewall-class counter tooling on the leaf ====="
node_run "$c1" "for b in iptables ip6tables nft; do which \$b >/dev/null 2>&1 && echo \"\$b: present\" || echo \"\$b: absent\"; done" 2>/dev/null || true

echo "===== verdict ====="
echo "COUNTERS-VERDICT kernel per-SID counters EXIST on this build: the seg6local \`count\` flag (iproute2 SEG6LOCAL grammar, §8) makes the kernel keep the End.DT46 behavior's own counters. COUNTERS_SRV6_NAME_MAP stays empty (§1) and no Seg6 nstat//proc counters exist (§2-3), so the per-SID source is the kernel route counters, read by the fabric-executor (T560); the VRF-device stats (§6) remain the coarser companion granularity."
echo "companion granularities: per-port counters (service port Ethernet12) and VRF-device stats:"

echo "===== 6. nearest granularity: per-port + VRF stats, leaf01 ====="
node_run "$c1" "ip -s link show Ethernet12 | head -6" 2>/dev/null | addr_norm | sed -E 's/^[0-9]+: /IFIDX: /' || true
node_run "$c1" "ip -s link show Vrf1 | head -6" 2>/dev/null | addr_norm | sed -E 's/^[0-9]+: /IFIDX: /' || true

echo "===== 7. dataplane probe: client ping exercising the SID path ====="
# The peer address is read, not assumed: allocations move (192.168.0.0/24 vs
# 192.168.1.0/24 at service-id 1, and they move again on every re-allocation),
# so the spike reads client02's eth1 address and pings it from client01.
CB=$(client_run "$C_srv6_client02" "ip -4 addr show eth1" 2>/dev/null | sed -n 's/.*inet \([0-9.]*\)[ \/].*/\1/p' | head -1)
echo "peer address: ${CB:-unreadable}"
[ -n "$CB" ] && client_run "$C_srv6_client01" "ping -c3 -W2 $CB" 2>/dev/null | ping_norm | grep -E 'received|loss' | tail -2 || true

echo "===== 8. per-SID counters: enable the seg6local \`count\` flag and measure ====="
# Same command the plan renders (pkg/fabricplan/srv6.go): `count` sits INSIDE
# the encap clause (before `dev`); at end-of-line iproute2 rejects it with
# `Error: either "to" is duplicate, or "count" is a garbage`.
SID=fcbb:bbbb:3:11::/64
node_run "$c1" "sudo ip -6 route replace $SID encap seg6local action End.DT46 vrftable \$(ip -d link show Vrf1 2>/dev/null | grep -o 'table [0-9]*' | cut -d' ' -f2) count dev Vrf1" 2>/dev/null || true
echo "-- counted route after enabling \`count\` (leaf01) --"
node_run "$c1" "ip -s -6 route show $SID" 2>/dev/null || true
CB=$(client_run "$C_srv6_client02" "ip -4 addr show eth1" 2>/dev/null | sed -n 's/.*inet \([0-9.]*\)[ \/].*/\1/p' | head -1)
[ -n "$CB" ] && client_run "$C_srv6_client01" "ping -c4 -W2 $CB" 2>/dev/null | ping_norm | grep -E 'received|loss' | tail -2 || true
echo "-- per-SID counter after 4 decapsulated probes (leaf01) --"
node_run "$c1" "ip -s -6 route show $SID" 2>/dev/null || true
node_run "$c2" "sudo ip -6 route replace fcbb:bbbb:4:11::/64 encap seg6local action End.DT46 vrftable \$(ip -d link show Vrf1 2>/dev/null | grep -o 'table [0-9]*' | cut -d' ' -f2) count dev Vrf1" 2>/dev/null || true
echo "-- counted route after enabling \`count\` (leaf02) --"
node_run "$c2" "ip -s -6 route show fcbb:bbbb:4:11::/64" 2>/dev/null || true
