#!/usr/bin/env bash
# persistence.sh — spike-persistence proof body (T103).
# What survives `config reload` on leaf01 and how the as-built comes back.
# Measured: the vtysh-rendered SRv6 locator block survives, every hand-added
# kernel object (fabric re-addressing, End.DT46 decap, Vrf1 steering, /48
# pin, E12 enslavement) is reverted to the FACTORY config_db.json snapshot —
# the GCU-written underlay rows live only in the running CONFIG_DB; the file
# is never saved — and the recovery is the full builder chain, not just
# vpn-setup.sh. Self-healing by construction.
set -u
. "$(dirname "$0")/spike-env.sh"
for _n in leaf01 leaf02 spine01 spine02; do ensure_bgp "$_n"; done
bash "$(dirname "$0")/vpn-setup.sh" >/dev/null 2>&1 || true
c1=$(container_of leaf01)
snap() {
    node_run "$c1" "vtysh -c 'show run' 2>/dev/null | grep -c 'locator loc-leaf01' | awk '{printf \"LOCATOR-VTYSH: %s\n\", \$1}'; ip -br addr show Ethernet0 2>/dev/null | grep -c '10.1.0.1/31' | awk '{printf \"FABRIC-E0-ADDR: %s\n\", \$1}'; ip -6 route show | grep -c 'encap seg6local action End.DT46' | awk '{printf \"KERNEL-DECAP: %s\n\", \$1}'; ip route show vrf Vrf1 2>/dev/null | grep -c 'encap seg6 mode encap' | awk '{printf \"KERNEL-STEERING: %s\n\", \$1}'; ip -6 route show | grep -c 'fcbb:bbbb:4::/48.*metric 5' | awk '{printf \"KERNEL-PIN-48: %s\n\", \$1}'; ip link show Ethernet12 2>/dev/null | grep -c 'master Vrf1' | awk '{printf \"E12-VRF-SLAVE: %s\n\", \$1}'" 2>/dev/null || true
}
echo "===== snapshot BEFORE config reload ====="
snap
echo "===== config reload -y (wait for frr to answer again) ====="
node_run "$c1" "sudo config reload -y >/dev/null 2>&1" >/dev/null 2>&1 || true
for i in $(seq 1 60); do
    ok=$(node_run "$c1" "vtysh -c 'show version' >/dev/null 2>&1 && echo READY" 2>/dev/null || true)
    [[ "$ok" == *READY* ]] && break
    sleep 3
done
sleep 8
echo "===== snapshot AFTER config reload (factory revert) ====="
snap
echo "===== recovery: full builder chain (underlay + vrf-apply + vpn-setup) ====="
bash "$(dirname "$0")/underlay-apply.sh" leaf01 >/dev/null 2>&1 || true
bash "$(dirname "$0")/vrf-apply.sh" leaf01 >/dev/null 2>&1 || true
bash "$(dirname "$0")/locator-node.sh" leaf01 >/dev/null 2>&1 || true
node_run "$c1" "sudo ip link set Ethernet12 master Vrf1 >/dev/null 2>&1" >/dev/null 2>&1 || true
for i in $(seq 1 40); do
    n=$(node_run "$c1" "vtysh -c 'show bgp summary json' 2>/dev/null | grep -o '\"state\":\"Established\"' | wc -l" 2>/dev/null | tr -d '[:space:]')
    [[ "${n:-0}" -ge 4 ]] 2>/dev/null && break
    sleep 3
done
bash "$(dirname "$0")/vpn-setup.sh" >/dev/null 2>&1 || true
sleep 4
echo "===== snapshot AFTER recovery ====="
snap
echo "===== client traffic passes again (8900-byte DF, both directions) ====="
client_run "$C_srv6_client01" "ping -c 3 -W 3 -s 8900 -M do 192.168.2.2 2>&1 | tail -2" | ping_norm || true
client_run "$C_srv6_client02" "ping -c 3 -W 3 -s 8900 -M do 192.168.1.2 2>&1 | tail -2" | ping_norm || true
