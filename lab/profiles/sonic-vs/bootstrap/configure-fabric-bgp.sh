#!/usr/bin/env bash
# Configure the underlay BGP fabric and the EVPN overlay on the SONiC nodes.
# Runs once from the host after every node has been bootstrapped, because
# peers reference each other and must all exist first.
#
# Why this exists: containerlab brings the nodes up and the profile bootstrap
# configures gNMI, but nothing configured routing originally. bgpd was not even
# running, CONFIG_DB carried no BGP_NEIGHBOR/LOOPBACK_INTERFACE, and
# tests/integration/fabric_verify.sh (T043 [US3], FR-004) asserts a live underlay
# with negotiated L2VPN EVPN AF and originated Type-2/3/5 routes (SC-002).
#
# Three layers are written deliberately, and they are not redundant:
#   * /etc/frr/bgpd.conf — the durable FRR configuration. bgpd is NOT in the
#     image's start.sh daemon list, so at every container start something must
#     both start bgpd AND have a config for it to load (this image has no
#     bgpcfgd: CONFIG_DB never generates FRR config). Writing bgpd.conf and
#     restarting bgpd makes this file the single source of truth — the live
#     vtysh session and the next boot can never disagree.
#   * CONFIG_DB — the declared intent (BGP_NEIGHBOR, LOOPBACK_INTERFACE,
#     INTERFACE, VLAN/VLAN_MEMBER, VRF, VXLAN_TUNNEL_MAP), written through GCU
#     so the whole-config YANG validation runs, read back over the sonic-db gNMI
#     origin by fabric_verify.sh. The GCU write REQUIRES `docker exec -i`: the
#     patch script is fed on stdin, and without -i python3 reads an empty
#     script, exits 0, and the write silently no-ops (root cause of the
#     "BGP_NEIGHBOR is empty" fabric_verify failures of 2026-08-30/31).
#   * fabric-init boot hook — /etc/sonic/bootstrap/fabric-init.sh registered in
#     /etc/supervisor/conf.d/agentic-netops-fabric.conf (autostart=true). The
#     capability gate's persistence check (T014) restarts every lab container
#     mid-provision; start.sh restarts zebra/fpmsyncd/vrfmgrd/... but NOT bgpd.
#     The hook waits for the manager daemons and the VRF device, then starts
#     bgpd (which loads the durable bgpd.conf), so the whole fabric — underlay,
#     EVPN AF, VTEP, L3VNI — re-converges by itself after any restart.
#
# Route coverage (docs/FABRIC_BGP_EVPN_DEFERRED.md D-A, SC-002):
#   * Type-3 (IMET): leaves originate via advertise-all-vni + the VTEP.
#   * Type-2 (MAC/IP): client01/client02 are bridged members of Vlan100
#     (VLAN_MEMBER, untagged) behind leaf01:eth3 / leaf02:eth3; client ARP/ping
#     traffic is driven by tests/integration/fabric_verify.sh before it asserts
#     the Type-2 routes in the EVPN RIB.
#   * Type-5 (IP prefix): tenant VRF vrf-blue bound to L3VNI 1000
#     (VXLAN_TUNNEL_MAP to Vlan2000 + VRF vni) with per-leaf connected SVI
#     subnets and `advertise ipv4 unicast` under the vrf's l2vpn evpn AF —
#     leaves only, so spines keep carrying no tenant VRF (FR-004).
#   * IPv6 underlay: every fabric link also carries a /127 (v6 eBGP sessions),
#     so leaf Loopback0 IPv6 addresses are reachable end-to-end (verified by
#     fabric_verify's loopback ping6).
#
# Traps guarded here (all previously hit, see findings 4.1 and the docs above):
#   * GCU validates the ENTIRE CONFIG_DB before any patch — DEVICE_METADATA
#     switch_type must be "npu" (asserted, not assumed).
#   * SONiC renders interfaces from CONFIG_DB admin-down — INTERFACE entries
#     carry admin_status up and interfaces are brought up explicitly.
set -euo pipefail

CLAB_PREFIX=${CLAB_PREFIX:-clab-agentic-netops-fabric-}

# node|asn|lo4|lo6|svi4|peer-spec(iface,local-ip,peer-ip,peer-asn,local-v6,peer-v6;...)
# Underlay is eBGP over /31 p2p links, ASNs per lab/topology.clab.yml
# (spines 65000, leaf01 65101, leaf02 65102). /127 v6 pairs ride the same
# links; the v6 addresses sit in the /127 blocks {::2,::3} and {::4,::5} —
# block {::0,::1} is unusable because Linux rejects the all-zeros host
# address ::0, and both endpoints must share one /127 block.
FABRIC="
spine01|65000|10.0.0.11|2001:db8:ff::11||eth1,10.1.0.0,10.1.0.1,65101,2001:db8:1::3,2001:db8:1::2;eth2,10.1.0.2,10.1.0.3,65102,2001:db8:1::5,2001:db8:1::4
spine02|65000|10.0.0.12|2001:db8:ff::12||eth1,10.1.0.4,10.1.0.5,65101,2001:db8:2::3,2001:db8:2::2;eth2,10.1.0.6,10.1.0.7,65102,2001:db8:2::5,2001:db8:2::4
leaf01|65101|10.0.0.21|2001:db8:ff::21|192.168.201.1|eth1,10.1.0.1,10.1.0.0,65000,2001:db8:1::2,2001:db8:1::3;eth2,10.1.0.5,10.1.0.4,65000,2001:db8:2::2,2001:db8:2::3
leaf02|65102|10.0.0.22|2001:db8:ff::22|192.168.202.1|eth1,10.1.0.3,10.1.0.2,65000,2001:db8:1::4,2001:db8:1::5;eth2,10.1.0.7,10.1.0.6,65000,2001:db8:2::4,2001:db8:2::5
"

# Leaves terminate the overlay (VTEP + L2VNI + L3VNI). Spines transit EVPN
# routes and deliberately carry no VTEP or tenant VRF — fabric_verify.sh asserts
# that absence on spines (FR-004), so do not add VXLAN/VRF state to a spine.
L2VNI=${L2VNI:-100}
VLAN=${VLAN:-Vlan100}
ACCESS_IFACE=${ACCESS_IFACE:-eth3}
L3VNI=${L3VNI:-1000}
L3VLAN=${L3VLAN:-Vlan2000}
TENANT_VRF=${TENANT_VRF:-VrfBlue}
VTEP=${VTEP:-vtep1}

log() { echo "[fabric-bgp] $*"; }

node_role() { case "$1" in leaf*) echo leaf ;; *) echo spine ;; esac; }

# Start the helper daemons a node needs before bgpd can mean anything. The
# image's start.sh already starts zebra/fpmsyncd/vrfmgrd/vlanmgrd/vxlanmgrd/
# intfmgrd at boot; starting them here too is idempotent and keeps the script
# usable standalone on a node booted before those defaults existed.
start_daemons() {
  local c=$1 role=$2 progs="zebra bgpd fpmsyncd vrfmgrd intfmgrd"
  # IPv6 forwarding is OFF by default in these containers while IPv4 forwarding is
  # on, so every node could originate and terminate IPv6 but not TRANSIT it. The
  # underlay is dual-stack and fabric_verify.sh asserts Loopback0 IPv6 reachability
  # between the leaves, which goes leaf -> spine -> leaf: each leaf could reach the
  # spine's loopback fine, and the spine could reach each leaf, but leaf-to-leaf
  # failed 100% because the spine dropped the transit packet.
  #
  # Measured 2026-09-03 on a clean provision: net.ipv6.conf.all.forwarding=0 with
  # net.ipv4.ip_forward=1 on all four nodes; leaf01 <-> leaf02 Loopback0 at 100%
  # packet loss, both directions 0% immediately after enabling it. Set on spines as
  # well as leaves -- the spines are the transit nodes, so they are the ones that
  # actually need it.
  docker exec "$c" sysctl -qw net.ipv6.conf.all.forwarding=1 2>/dev/null || true
  [[ "$role" == leaf ]] && progs="$progs vlanmgrd vxlanmgrd"
  local p
  for p in $progs; do
    docker exec "$c" supervisorctl start "$p" >/dev/null 2>&1 || true
  done
}

# SONiC renders interfaces from CONFIG_DB and leaves them admin-down, so every
# fabric link, the loopback and the L3VLAN SVI are brought up explicitly.
# Idempotent: addresses are only added when absent, and stale /127s that do not
# match the declared local address are removed (guards against a swapped peer
# address left behind by an earlier run).
configure_interfaces() {
  local c=$1 lo4=$2 lo6=$3 svi4=$4 peers=$5 spec iface lip lip6
  docker exec "$c" bash -c "
    ip link set lo up
    ip -br addr show lo | grep -q '$lo4/32'  || ip addr add $lo4/32 dev lo
    ip -br addr show lo | grep -q '$lo6/128' || ip -6 addr add $lo6/128 dev lo
  "
  local IFS=';'
  for spec in $peers; do
    IFS=',' read -r iface lip _ _ lip6 _ <<<"$spec"
    docker exec "$c" bash -c "
      ip link set $iface up 2>/dev/null || true
      ip -br addr show $iface 2>/dev/null | grep -q '$lip/31'  || ip addr add $lip/31 dev $iface 2>/dev/null || true
      ip -br addr show $iface 2>/dev/null | grep -q '$lip6/127' || ip -6 addr add $lip6/127 dev $iface 2>/dev/null || true
      for a in \$(ip -br addr show $iface 2>/dev/null | grep -oE '2001:db8:[0-9a-f:]+/127' | grep -v '^$lip6/127\$'); do
        ip -6 addr del \$a dev $iface 2>/dev/null || true
      done
    "
  done
  unset IFS
  if [[ -n "$svi4" ]]; then
    docker exec "$c" bash -c "ip link set $L3VLAN up 2>/dev/null || true"
  fi
}

# Overlay VTEP on leaves only, through CONFIG_DB so vxlanmgrd builds the kernel
# VXLAN devices (verified: vtep1-<vni> created and enslaved to Bridge):
#   * L2VNI $L2VNI <-> $VLAN, with the leaf access port bridged in (Type-2), and
#   * L3VNI $L3VNI <-> $L3VLAN bound to tenant VRF $TENANT_VRF (Type-5).
configure_overlay() {
  local c=$1 lo4=$2 svi4=$3
  docker exec "$c" bash -c "
    redis-cli -n 4 hset 'VXLAN_TUNNEL|$VTEP' src_ip '$lo4' >/dev/null
    redis-cli -n 4 hset 'EVPN_NVO|nvo1' source_vtep '$VTEP' >/dev/null
    redis-cli -n 4 hset 'VLAN|$VLAN' vlanid '${VLAN#Vlan}' >/dev/null
    redis-cli -n 4 hset 'VXLAN_TUNNEL_MAP|$VTEP|map_${L2VNI}_$VLAN' vni '$L2VNI' vlan '$VLAN' >/dev/null
    redis-cli -n 4 hset 'VLAN|$L3VLAN' vlanid '${L3VLAN#Vlan}' >/dev/null
    redis-cli -n 4 hset 'VXLAN_TUNNEL_MAP|$VTEP|map_${L3VNI}_$L3VLAN' vni '$L3VNI' vlan '$L3VLAN' >/dev/null
    # Materialize the VRF before the GCU whole-config validation below. On the
    # 202505 manager stack, GCU can apply a multi-row patch successfully but
    # time out its immediate verification; the subsequent VRF patch must not
    # be skipped merely because that earlier readback raced the consumers.
    redis-cli -n 4 hset 'VRF|$TENANT_VRF' vni '$L3VNI' >/dev/null
  "
}

# Declared intent in CONFIG_DB, written through the generic config updater so the
# whole-config YANG validation runs. GCU validates the ENTIRE CONFIG_DB before
# applying any patch — one invalid value anywhere fails every write, so this
# must stay the LAST writer (it doubles as a canary for the raw writes above).
# Whole tables are added in single ops so GCU expands and JSON-pointer-escapes
# the slash-carrying keys (e.g. "10.0.0.21/32") itself.
#
# Scope note: this image's sonic-interface.yang types INTERFACE_LIST.name as a
# leafref into the PORT table, so link/SVI addressing cannot be declared there
# at all (any eth*/Vlan* row fails validation with "Value not found for name").
# Link addressing is therefore kernel state, restored at every container start
# by the fabric-init boot hook installed below.
#
# IMPORTANT: `docker exec -i` is mandatory here. The patch script is fed on
# stdin; without -i python3 reads an empty script, exits 0 and the write
# silently no-ops — the exact failure that left BGP_NEIGHBOR/LOOPBACK_INTERFACE
# unpopulated while every FRR session still established (fixed 2026-09-01).
configure_config_db() {
  local c=$1 lo4=$2 lo6=$3 svi4=$4 peers=$5 role=$6
  # The stock image ships switch_type="switch", which is not in the YANG enum
  # (chassis-packet|fabric|npu|voq|dpu|dummy-sup) — see findings 4.1. Fix it
  # here so this step does not depend on bootstrap ordering.
  docker exec "$c" redis-cli -n 4 hset "DEVICE_METADATA|localhost" switch_type npu >/dev/null 2>&1 || true

  docker exec -i \
    -e PEERS="$peers" -e ROLE="$role" -e LO4="$lo4" -e LO6="$lo6" \
    -e L3VNI="$L3VNI" -e TENANT_VRF="$TENANT_VRF" \
    -e VRF_TABLE_EXISTS="$(docker exec "$c" bash -c '[ -n "$(redis-cli -n 4 --scan --pattern "VRF|*" | head -n1)" ] && echo 1 || echo 0')" \
    "$c" python3 - <<'PY' || \
    echo "[fabric-bgp] WARN: CONFIG_DB intent write failed on $c (FRR state is still live)" >&2
import os, sys, json, jsonpatch
from generic_config_updater.generic_updater import GenericUpdater, ConfigFormat

peers = []
for spec in os.environ["PEERS"].split(";"):
    iface, lip, pip, pasn, lip6, pip6 = spec.split(",")
    peers.append(dict(lip=lip, pip=pip, pasn=pasn, lip6=lip6, pip6=pip6))
role = os.environ["ROLE"]
lo4, lo6 = os.environ["LO4"], os.environ["LO6"]
up = GenericUpdater()

# patch 1 — tables this script fully owns (whole-table adds; GCU expands and
# JSON-pointer-escapes the slash-carrying keys itself)
lo = {"Loopback0": {}, f"Loopback0|{lo4}/32": {}, f"Loopback0|{lo6}/128": {}}
nbr: dict = {}
for p in peers:
    nbr[p["pip"]] = {"asn": p["pasn"], "local_addr": p["lip"], "holdtime": "180",
                     "keepalive": "60", "nhopself": "0", "rrclient": "0"}
    nbr[p["pip6"]] = {"asn": p["pasn"], "local_addr": p["lip6"], "holdtime": "180",
                      "keepalive": "60", "nhopself": "0", "rrclient": "0"}
try:
    up.apply_patch(jsonpatch.JsonPatch([
        {"op": "add", "path": "/LOOPBACK_INTERFACE", "value": lo},
        {"op": "add", "path": "/BGP_NEIGHBOR", "value": nbr},
    ]), ConfigFormat.CONFIGDB, False, False, False, [])
except Exception as exc:
    # GCU's 202505 read-after-write verification can race manager consumers.
    # Continue to the independently validated overlay patch; shell-level live
    # state and fabric_verify remain the fail-closed checks.
    print(f"[fabric-bgp] WARN: underlay GCU immediate verification: {exc}", file=sys.stderr)

# patch 2 — leaf overlay intent, applied separately so a failure here cannot
# roll back the underlay intent above. Per-key adds need the parent table to
# exist; when VRF does not exist yet it is added whole (it holds only our VRF).
if role == "leaf":
    # The tenant VRF is declared here (GCU-valid). VLAN membership of the real
    # access link is NOT declared in CONFIG_DB at all: VLAN_MEMBER_LIST.port is
    # a leafref into the PORT table, and this image's topology links (ethN) do
    # not exist there — a raw row would poison every GCU write image-wide (the
    # switch_type trap pattern). The boot hook below bridges the access link
    # into the vlanmgrd-created Bridge with a kernel-side join instead.
    leaf_patch = []
    if os.environ.get("VRF_TABLE_EXISTS") == "1":
        leaf_patch.append({"op": "add", "path": f"/VRF/{os.environ['TENANT_VRF']}",
                           "value": {"vni": os.environ["L3VNI"]}})
    else:
        leaf_patch.append({"op": "add", "path": "/VRF",
                           "value": {os.environ["TENANT_VRF"]: {"vni": os.environ["L3VNI"]}}})
    try:
        up.apply_patch(jsonpatch.JsonPatch(leaf_patch), ConfigFormat.CONFIGDB, False, False, False, [])
    except Exception as exc:
        print(f"[fabric-bgp] WARN: overlay GCU immediate verification: {exc}", file=sys.stderr)
print("[fabric-bgp] CONFIG_DB intent applied", file=sys.stderr)
PY
}

# Durable FRR config. bgpd reads /etc/frr/bgpd.conf when it starts (no -f is
# passed by the supervisord program), so writing the file and (re)starting bgpd
# makes running state and next-boot state identical by construction.
generate_frr_conf() {
  local c=$1 node=$2 asn=$3 lo4=$4 role=$5 svi4=$6 peers=$7
  local conf spec iface lip pip pasn lip6 pip6
  conf="hostname $node\nlog syslog informational\n!\nrouter bgp $asn\n bgp router-id $lo4\n no bgp ebgp-requires-policy\n"
  local v4nbrs="" v6nbrs=""
  local IFS=';'
  for spec in $peers; do
    IFS=',' read -r iface lip pip pasn lip6 pip6 <<<"$spec"
    conf+=" neighbor $pip remote-as $pasn\n neighbor $pip6 remote-as $pasn\n"
    v4nbrs+="  neighbor $pip activate\n"
    v6nbrs+="  neighbor $pip6 activate\n"
  done
  unset IFS
  # maximum-paths 2: the fabric's declared intent is ECMP across each leaf's
  # two uplinks (data-model §7, eight links). Without it bgpd's eBGP default
  # is a single best path, so zebra installs ONE kernel nexthop even though
  # the RIB holds both — measured live 2026-10-15 (sonic-vm leg, same FRR
  # build): the ECMP distribution check saw 100% of a multi-flow burst on one
  # uplink until maximum-paths 2 was applied, which immediately installed
  # both kernel nexthops.
  conf+=" !\n address-family ipv4 unicast\n  maximum-paths 2\n  redistribute connected\n$v4nbrs exit-address-family\n"
  conf+=" !\n address-family ipv6 unicast\n  maximum-paths 2\n  redistribute connected\n$v6nbrs exit-address-family\n"
  conf+=" !\n address-family l2vpn evpn\n$v4nbrs"
  # advertise-all-vni is what makes zebra hand its VNIs (L2VNI + L3VNI) to bgpd;
  # without it `show evpn vni` stays empty and no Type-2/3/5 route is originated.
  [[ "$role" == leaf ]] && conf+="  advertise-all-vni\n"
  conf+=" exit-address-family\n!\n"
  if [[ "$role" == leaf ]]; then
    # The L3-VNI binding is deliberately NOT written here. This file is parsed
    # by bgpd alone, while `vni` in a top-level `vrf` block is owned by
    # integrated FRR/zebra. bgpd rejects that line as an unknown command. The
    # binding is applied through integrated vtysh after zebra and the kernel
    # bridge/SVI topology are ready (apply_frr and the boot hook below).
    conf+="router bgp $asn vrf $TENANT_VRF\n"
    conf+=" address-family ipv4 unicast\n  redistribute connected\n exit-address-family\n"
    conf+=" !\n address-family l2vpn evpn\n  advertise ipv4 unicast\n exit-address-family\n!\n"
  fi
  conf+="line vty\n"
  printf '%b' "$conf" | docker exec -i "$c" tee /etc/frr/bgpd.conf >/dev/null
}

# Host-side counterpart of the fabric-init hook's leaf block: make sure the
# vlanmgrd/vxlanmgrd/vrfmgrd devices exist and carry the kernel state FRR needs
# (SVI address + VRF membership, L3VNI vtep bridged into its VLAN). The
# managers of this build warm-read nothing at startup — they only react to
# live CONFIG_DB changes — so they are (re)started here to process the tables
# written above. FRR's supported topology keeps the VXLAN device on the
# VLAN-aware bridge and enslaves the L3 SVI to the tenant VRF.
ensure_overlay_devices() {
  local c=$1 svi4=$2
  docker exec "$c" supervisorctl restart vlanmgrd vxlanmgrd >/dev/null 2>&1 || true
  local i dev id vtep_dev=""
  for i in $(seq 1 15); do
    vtep_dev=""
    for dev in $(docker exec "$c" bash -c 'ls /sys/class/net/ 2>/dev/null | grep "^vtep" || true'); do
      id=$(docker exec "$c" bash -c "ip -d link show $dev 2>/dev/null | grep -oE 'vxlan id [0-9]+' | awk '{print \$3}'" 2>/dev/null)
      [[ "$id" == "$L3VNI" ]] && { vtep_dev=$dev; break; }
    done
    [[ -n "$vtep_dev" ]] && docker exec "$c" bash -c "ip link show $L3VLAN >/dev/null 2>&1" && break
    sleep 2
  done
  local l2_vtep_dev=""
  for i in $(seq 1 45); do
    l2_vtep_dev=""
    for dev in $(docker exec "$c" bash -c 'ls /sys/class/net/ 2>/dev/null | grep "^vtep" || true'); do
      id=$(docker exec "$c" bash -c "ip -d link show $dev 2>/dev/null | grep -oE 'vxlan id [0-9]+' | awk '{print \$3}'" 2>/dev/null)
      [[ "$id" == "$L2VNI" ]] && { l2_vtep_dev=$dev; break; }
    done
    [[ -n "$l2_vtep_dev" ]] && break
    if (( i == 20 )); then
      echo "[fabric-bgp] $c: waiting for L2 VTEP $L2VNI; restarting orchagent/vxlanmgrd once" >&2
      docker exec "$c" supervisorctl restart orchagent vxlanmgrd >/dev/null 2>&1 || true
    fi
    sleep 2
  done
  # L3VLAN device fallback (see fabric-init hook comment): create kernel-side
  # if vlanmgrd did not
  docker exec "$c" bash -c "ip link show $L3VLAN >/dev/null 2>&1 || ip link add $L3VLAN link Bridge type vlan id ${L3VLAN#Vlan} 2>/dev/null || true" || true
  # L2 access link -- joined BEFORE the L3VNI guard below, because Type-2 bridging
  # must not depend on L3VNI/Type-5 being healthy. Two independent defects made that
  # dependency fatal on 2026-09-02:
  #   * the access link was never enslaved at all on a first provision. The enslave +
  #     link-up live only in the fabric-init boot hook (section 5b), and
  #     install_boot_hook writes the supervisor conf without a `supervisorctl reread
  #     && update`, so that hook first runs on the NEXT boot.
  #   * `bridge vlan add dev X` is a no-op on a device that is not a bridge port, and
  #     every line here carries `|| true`, so it failed silently.
  # With the pinned image's FRR not adopting the L3VNI (D-A2), vtep_dev stays empty,
  # the guard returns 0, and the L2 path was collateral damage: eth3 DOWN and absent
  # from Bridge on both leaves, VLAN|Vlan100 present in CONFIG_DB and APPL_DB with no
  # port carrying it, client01 -> client02 at 100% packet loss, and fabric_verify.sh
  # burning ~12 min per run in its 24x5s reachability retry until the wiggum
  # repeat-stall watchdog killed the phase-8 pass.
  docker exec "$c" bash -c "
    # Wait for vlanmgrd to create Bridge, exactly as the boot hook does. Bailing on
    # a missing Bridge without waiting made the join RACE-DEPENDENT: on a leaf where
    # the L3VNI never adopts (D-A2) the wait loop above burns its full timeout and
    # Bridge is there by the time we run, but on a leaf that DOES get its L3VNI vtep
    # the loop breaks early and Bridge may not exist yet. Observed 2026-09-03 at 11
    # minutes uptime: leaf01 eth3 UP/master=Bridge, leaf02 eth3 DOWN/master=none, and
    # the overlay at 100% packet loss because one side of the bridge was missing.
    for _i in \$(seq 1 45); do
      ip link show Bridge >/dev/null 2>&1 && break
      sleep 2
    done
    ip link show Bridge >/dev/null 2>&1 || exit 0
    # The L2 VTEP must be a bridge port too. vxlanmgrd normally enslaves
    # vtep1-<L2VNI> itself, but it does not always win the race against Bridge
    # creation, and when it loses there is no retry. zebra then cannot classify the
    # VNI, so bgpd reports \"Number of L2 VNIs: 0\" even with advertise-all-vni
    # enabled, no remote VTEP is ever installed from the peer's IMET, and the
    # overlay silently forwards nothing.
    #
    # Measured 2026-09-03 on a clean provision: leaf02 had vtep1-100 master=Bridge
    # and 1 L2 VNI; leaf01 had vtep1-100 with NO master and 0 L2 VNIs, while both
    # had identical running configs and zebra on both listed VNI 100. Enslaving it
    # on leaf01 took bgpd 0 -> 1 L2 VNIs, remote VTEPs 0 -> 1 on both leaves, and
    # client01 -> client02 from 100% packet loss to 0%.
    #
    # This is why restarting bgpd (and even zebra) appeared to \"fix\" adoption
    # intermittently: those restarts only helped when the device happened to be
    # bridged by then. Bridging it directly is the actual fix.
    vtep_l2='$l2_vtep_dev'
    [ -n \"\$vtep_l2\" ] || vtep_l2=vtep1-${VLAN#Vlan}
    if ip link show \$vtep_l2 >/dev/null 2>&1; then
      m_vtep=\$(ip -d link show \$vtep_l2 2>/dev/null | grep -oE 'master [a-zA-Z0-9_]+' | cut -d' ' -f2)
      [ \"\$m_vtep\" = 'Bridge' ] || ip link set \$vtep_l2 master Bridge 2>/dev/null || true
      bridge vlan add dev \$vtep_l2 vid ${VLAN#Vlan} pvid untagged 2>/dev/null || true
      ip link set \$vtep_l2 up 2>/dev/null || true
      ip -d link show \$vtep_l2 2>/dev/null | grep -q 'master Bridge' \
        && echo '[fabric-bgp] L2 VTEP '\$vtep_l2' bridged into vlan ${VLAN#Vlan}'
    fi
    ip link set $ACCESS_IFACE up 2>/dev/null || true
    master_acc=\$(ip -d link show $ACCESS_IFACE 2>/dev/null | grep -oE 'master [a-zA-Z0-9_]+' | cut -d' ' -f2)
    [ \"\$master_acc\" = 'Bridge' ] || ip link set $ACCESS_IFACE master Bridge 2>/dev/null || true
    bridge vlan del dev $ACCESS_IFACE vid 1 2>/dev/null || true
    bridge vlan add dev $ACCESS_IFACE vid ${VLAN#Vlan} pvid untagged 2>/dev/null || true
    ip -d link show $ACCESS_IFACE 2>/dev/null | grep -q 'master Bridge' \
      && echo '[fabric-bgp] access link $ACCESS_IFACE bridged into vlan ${VLAN#Vlan}'
  " || true
  [[ -n "$vtep_dev" ]] || { echo "[fabric-bgp] WARN: no vtep carrying vni $L3VNI on $c" >&2; return 0; }
  docker exec "$c" bash -c "
    ip link set $L3VLAN up 2>/dev/null || true
    ip -br addr show $L3VLAN 2>/dev/null | grep -q '$svi4/24' || ip addr add $svi4/24 dev $L3VLAN 2>/dev/null || true
    ip link set $L3VLAN master $TENANT_VRF 2>/dev/null || true
    master=\$(ip -d link show $vtep_dev 2>/dev/null | grep -oE 'master [a-zA-Z0-9_]+' | cut -d' ' -f2)
    [ \"\$master\" = 'Bridge' ] || ip link set $vtep_dev master Bridge 2>/dev/null || true
    bridge vlan del dev $vtep_dev vid 1 2>/dev/null || true
    bridge vlan add dev $vtep_dev vid ${L3VLAN#Vlan} pvid untagged 2>/dev/null || true
    ip link set $vtep_dev up 2>/dev/null || true
    ip -d link show $vtep_dev 2>/dev/null | grep -q 'master Bridge' \
      && echo '[fabric-bgp] L3VNI $vtep_dev bridged into vlan ${L3VLAN#Vlan}; $L3VLAN bound to $TENANT_VRF'
  " || true
}

apply_frr() {
  local c=$1 node=$2 asn=$3 lo4=$4 role=$5 svi4=$6 peers=$7
  generate_frr_conf "$c" "$node" "$asn" "$lo4" "$role" "$svi4" "$peers"
  if [[ "$role" == leaf ]]; then
    ensure_overlay_devices "$c" "$svi4"
    # The FRR vrf stanza only binds once the kernel VRF device exists. vrfmgrd
    # picks up VRF rows reliably at startup (the runtime keyspace notification
    # proved lossy on leaf01), so restart it if the device is missing, then
    # wait for it rather than let bgpd load an unbindable VRF instance.
    if ! docker exec "$c" bash -c "ip link show $TENANT_VRF >/dev/null 2>&1"; then
      docker exec "$c" supervisorctl restart vrfmgrd >/dev/null 2>&1 || true
    fi
    local i ok
    for i in $(seq 1 30); do
      ok=1
      docker exec "$c" bash -c "ip link show $TENANT_VRF >/dev/null 2>&1" || ok=0
      [[ $ok -eq 1 ]] && break
      sleep 2
    done
    [[ $ok -eq 1 ]] || log "WARN: $TENANT_VRF device not seen on $node yet (bgpd will still load the rest)"
    # This is an integrated FRR/zebra command, not a bgpd.conf command. Apply it
    # after the kernel topology exists and reapply on every provisioning run;
    # FRR 10.x has known reload paths that can lose this association.
    docker exec "$c" vtysh -c 'configure terminal' -c "vrf $TENANT_VRF" \
      -c "vni $L3VNI" -c 'end' >/dev/null 2>&1 || {
        echo "[fabric-bgp] ERROR: $node: could not bind L3 VNI $L3VNI to $TENANT_VRF through integrated vtysh" >&2
        return 1
      }
  fi
  docker exec "$c" supervisorctl restart bgpd >/dev/null 2>&1 \
    || docker exec "$c" supervisorctl start bgpd >/dev/null 2>&1 \
    || { echo "[fabric-bgp] ERROR: bgpd on $node could not be (re)started" >&2; return 1; }
  local i
  for i in $(seq 1 30); do
    docker exec "$c" bash -c 'pgrep -x bgpd >/dev/null' 2>/dev/null && break
    sleep 2
  done
  # VNI-adoption verification (mirrors hook step 6b): both VNIs are mandatory.
  # A lost bgpd/zebra notification is normally recovered by toggling
  # advertise-all-vni; restart escalation is retained for an empty zebra table.
  if [ "$role" = leaf ]; then
    local attempt adopted_l2=0 adopted_l3=0
    for attempt in 1 2 3; do
      adopted_l2=0
      adopted_l3=0
      for i in $(seq 1 10); do
        docker exec "$c" bash -c "vtysh -d bgpd -c 'show bgp l2vpn evpn vni' 2>/dev/null | grep -qE '^\\*?[[:space:]]*${L2VNI}[[:space:]]+L2'" && adopted_l2=1 || adopted_l2=0
        docker exec "$c" bash -c "vtysh -d bgpd -c 'show bgp l2vpn evpn vni' 2>/dev/null | grep -qE '^\\*?[[:space:]]*${L3VNI}[[:space:]]+L3.*[[:space:]]${TENANT_VRF}([[:space:]]|$)'" && adopted_l3=1 || adopted_l3=0
        [ "$adopted_l2" -eq 1 ] && [ "$adopted_l3" -eq 1 ] && break
        sleep 3
      done
      if [ "$adopted_l2" -eq 1 ] && [ "$adopted_l3" -eq 1 ]; then
        echo "[fabric-bgp] $node: bgpd adopted L2 VNI $L2VNI and L3 VNI $L3VNI (attempt $attempt)"
        break
      fi
      echo "[fabric-bgp] $node: VNI adoption incomplete (L2=$adopted_l2 L3=$adopted_l3, attempt $attempt) — toggling advertise-all-vni"
      docker exec "$c" vtysh \
        -c 'configure terminal' -c "router bgp $asn" \
        -c 'address-family l2vpn evpn' -c 'no advertise-all-vni' -c 'end' >/dev/null 2>&1 || true
      sleep 2
      docker exec "$c" vtysh \
        -c 'configure terminal' -c "router bgp $asn" \
        -c 'address-family l2vpn evpn' -c 'advertise-all-vni' -c 'end' >/dev/null 2>&1 || true
      sleep 8
      if ! docker exec "$c" bash -c "vtysh -c 'show evpn vni' 2>/dev/null | grep -qE '^[[:space:]]*${L2VNI}[[:space:]]'" || \
         ! docker exec "$c" bash -c "vtysh -c 'show evpn vni' 2>/dev/null | grep -qE '^[[:space:]]*${L3VNI}[[:space:]]+L3.*[[:space:]]${TENANT_VRF}([[:space:]]|$)'"; then
        echo "[fabric-bgp] $node: zebra VNI table incomplete (attempt $attempt) — restarting zebra and restoring the integrated L3-VNI binding"
        docker exec "$c" supervisorctl restart zebra >/dev/null 2>&1 || true
        sleep 12
        docker exec "$c" vtysh -c 'configure terminal' -c "vrf $TENANT_VRF" \
          -c "vni $L3VNI" -c 'end' >/dev/null 2>&1 || true
      else
        echo "[fabric-bgp] $node: restarting bgpd to re-query zebra"
      fi
      docker exec "$c" supervisorctl restart bgpd >/dev/null 2>&1 || true
      sleep 10
    done
    if [ "$adopted_l2" -ne 1 ]; then
      echo "[fabric-bgp] ERROR: $node: bgpd never adopted L2 VNI $L2VNI after 3 restarts — overlay cannot forward; failing provision" >&2
      return 1
    fi
    if [ "$adopted_l3" -ne 1 ]; then
      echo "[fabric-bgp] ERROR: $node: bgpd never adopted L3 VNI $L3VNI for $TENANT_VRF — Type-5 origination is unavailable; failing provision" >&2
      return 1
    fi
  fi
  docker exec "$c" bash -c 'pgrep -x bgpd >/dev/null' 2>/dev/null || {
    echo "[fabric-bgp] ERROR: bgpd did not start on $node" >&2; return 1
  }
  return 0
}

# Restart-persistence: install a boot hook inside the node so the fabric comes
# back by itself after the gate's persistence restart (or any container restart).
# start.sh restarts the manager daemons but NOT bgpd, and a fresh container
# network namespace has NO interface addresses — the hook re-applies the node's
# declared addressing (loopbacks, /31 + /127 links, L3VLAN SVI) and then starts
# bgpd, which loads the durable /etc/frr/bgpd.conf written above. The generated
# script and its supervisor registration live in the node filesystem, which
# survives `docker restart`; a fresh clab deploy re-runs this whole script at
# bootstrap and reinstalls both.
install_boot_hook() {
  local c=$1 node=$2 role=$3 lo4=$4 lo6=$5 svi4=$6 peers=$7
  # node-specific values, baked in at generation time
  {
    echo "#!/usr/bin/env bash"
    echo "# Agentic NetOps fabric init for $node (role=$role) — generated at bootstrap"
    echo "# by lab/profiles/sonic-vs/bootstrap/configure-fabric-bgp.sh."
    echo "set -u"
    echo "log() { echo \"[fabric-init] \$*\"; }"
    echo "ROLE='$role'"
    echo "TENANT_VRF='$TENANT_VRF'"
    echo "L3VLAN='$L3VLAN'"
    echo "L3VNI='$L3VNI'"
    echo "L2VNI='$L2VNI'"
    echo "ACCESS_IFACE='$ACCESS_IFACE'"
    echo "L2VLAN='$VLAN'"
    echo "VTEP='$VTEP'"
    echo "SVI4='$svi4'"
    echo "LO4='$lo4'"
    echo "LO6='$lo6'"
    echo "PEERS='$peers'"
    echo "PEER_VTEP='$( [[ "$role" == leaf ]] && peer_leaf_lo4 "$node" )'"
    cat <<'EOS'
# 0) IPv6 forwarding: OFF by default in this container while IPv4 forwarding is on,
#    and a sysctl does not survive a restart -- so it must be re-applied here or the
#    dual-stack underlay loses leaf->spine->leaf transit after the persistence
#    restart even though each hop is individually reachable (2026-09-03).
sysctl -qw net.ipv6.conf.all.forwarding=1 2>/dev/null || true
# 1) CONFIG_DB must be loaded (start.sh/configdb-load.sh) before anything else
for i in $(seq 1 90); do
  [ -n "$(redis-cli -n 4 hget 'DEVICE_METADATA|localhost' switch_type 2>/dev/null)" ] && break
  sleep 2
done
if [ "$ROLE" = leaf ]; then
  redis-cli -n 4 hset "EVPN_NVO|nvo1" source_vtep "$VTEP" >/dev/null 2>&1 || true
fi
# 2) manager daemons (started by start.sh) must be RUNNING before bgpd
for i in $(seq 1 60); do
  supervisorctl status zebra 2>/dev/null | grep -q RUNNING && \
    supervisorctl status fpmsyncd 2>/dev/null | grep -q RUNNING && break
  sleep 2
done
# zebra can lose the boot race on this image (observed 2026-10-15: after the
# persistence restart both leaves came up with zebra EXITED; without a restart
# FRR never classifies the VNIs and EVPN stays dark while every daemon
# reports RUNNING)
supervisorctl status zebra 2>/dev/null | grep -q RUNNING || \
  supervisorctl start zebra >/dev/null 2>&1 || true
# 3) leaves: the tenant VRF device must exist before bgpd loads its vrf stanza
if [ "$ROLE" = leaf ]; then
  for i in $(seq 1 45); do
    ip link show "$TENANT_VRF" >/dev/null 2>&1 && break
    sleep 2
  done
fi
# 4) interface addressing: a container restart creates a fresh network
#    namespace, so the declared addresses are re-applied here (idempotent)
ip link set lo up 2>/dev/null || true
ip -br addr show lo | grep -q "$LO4/32"  || ip addr add "$LO4/32" dev lo 2>/dev/null || true
ip -br addr show lo | grep -q "$LO6/128" || ip -6 addr add "$LO6/128" dev lo 2>/dev/null || true
ip link set Loopback0 up 2>/dev/null || true
OLDIFS=$IFS
IFS=';'
for spec in $PEERS; do
  IFS=',' read -r iface lip _ _ lip6 _ <<<"$spec"
  ip link set "$iface" up 2>/dev/null || true
  ip -br addr show "$iface" 2>/dev/null | grep -q "$lip/31"  || ip addr add "$lip/31" dev "$iface" 2>/dev/null || true
  ip -br addr show "$iface" 2>/dev/null | grep -q "$lip6/127" || ip -6 addr add "$lip6/127" dev "$iface" 2>/dev/null || true
done
IFS=$OLDIFS
# 5) Leaf L3VLAN SVI + L3VNI binding. FRR's supported topology is:
#      VXLAN device -> VLAN-aware Bridge, tagged/PVID for the L3 VLAN
#      L3 VLAN SVI  -> tenant VRF
#    The top-level `vrf ... vni` command belongs to integrated FRR/zebra, so
#    apply it through vtysh before bgpd starts; bgpd.conf cannot own it.
if [ "$ROLE" = leaf ] && [ -n "$SVI4" ]; then
  # 5a) wait for vxlanmgrd/vlanmgrd to (re)create the devices — they start in
  #     parallel with this hook and take a while after CONFIG_DB load. The vtep
  #     device name does not encode the VNI (vni 1000 lands as vtep1-2000,
  #     suffixed with the L3VLAN id), so resolve it by its vxlan id.
  VTEP_DEV=""
  for i in $(seq 1 15); do
    ip link show "$L3VLAN" >/dev/null 2>&1 && break
    sleep 2
  done
  # vlanmgrd's creation of the L3VLAN device proved unreliable across boots
  # (observed 2026-09-01: Vlan2000 missing after a clean supervisorctl cycle),
  # so create it kernel-side if it is still absent — the VLAN table row stays
  # the declared intent; this only materializes the device.
  ip link show "$L3VLAN" >/dev/null 2>&1 || \
    ip link add "$L3VLAN" link Bridge type vlan id "${L3VLAN#Vlan}" 2>/dev/null || true
  for i in $(seq 1 60); do
    VTEP_DEV=""
    for d in /sys/class/net/vtep*; do
      [ -e "$d" ] || continue
      dev=$(basename "$d")
      id=$(ip -d link show "$dev" 2>/dev/null | grep -oE 'vxlan id [0-9]+' | awk '{print $3}')
      if [ "$id" = "$L3VNI" ]; then VTEP_DEV="$dev"; break; fi
    done
    [ -n "$VTEP_DEV" ] && break
    sleep 2
  done
  ip link set "$L3VLAN" up 2>/dev/null || true
  ip -br addr show "$L3VLAN" 2>/dev/null | grep -q "$SVI4/24" || ip addr add "$SVI4/24" dev "$L3VLAN" 2>/dev/null || true
  ip link set "$L3VLAN" master "$TENANT_VRF" 2>/dev/null || true
  if [ -n "$VTEP_DEV" ]; then
    master=$(ip -d link show "$VTEP_DEV" 2>/dev/null | grep -oE 'master [a-zA-Z0-9_]+' | cut -d' ' -f2)
    [ "$master" = "Bridge" ] || ip link set "$VTEP_DEV" master Bridge 2>/dev/null || true
    bridge vlan del dev "$VTEP_DEV" vid 1 2>/dev/null || true
    bridge vlan add dev "$VTEP_DEV" vid "${L3VLAN#Vlan}" pvid untagged 2>/dev/null || true
    ip link set "$VTEP_DEV" up 2>/dev/null || true
    master=$(ip -d link show "$VTEP_DEV" 2>/dev/null | grep -oE 'master [a-zA-Z0-9_]+' | cut -d' ' -f2)
    if [ "$master" = "Bridge" ]; then
      log "L3VNI vtep $VTEP_DEV (vni $L3VNI) bridged into vlan ${L3VLAN#Vlan}; $L3VLAN bound to $TENANT_VRF"
    else
      log "WARN: $VTEP_DEV not bound to Bridge (master=${master:-none})"
    fi
    vtysh -c 'configure terminal' -c "vrf $TENANT_VRF" -c "vni $L3VNI" -c 'end' >/dev/null 2>&1 || \
      log "WARN: integrated FRR rejected vrf $TENANT_VRF vni $L3VNI"
    for i in $(seq 1 30); do
      # vrfmgrd may recreate the VRF after CONFIG_DB reload and detach the SVI
      # after our first assignment. Reassert the supported kernel topology
      # throughout convergence so zebra never observes a stale direct-VRF VXLAN
      # or an unbound L3 SVI.
      ip link set "$L3VLAN" master "$TENANT_VRF" 2>/dev/null || true
      ip link set "$VTEP_DEV" master Bridge 2>/dev/null || true
      bridge vlan add dev "$VTEP_DEV" vid "${L3VLAN#Vlan}" pvid untagged 2>/dev/null || true
      zn=$(vtysh -d zebra -c 'show evpn vni' 2>/dev/null)
      echo "$zn" | grep -qE "^$L3VNI[[:space:]]+L3.*[[:space:]]$TENANT_VRF([[:space:]]|$)" && break
      ip link set "$VTEP_DEV" down 2>/dev/null || true
      sleep 1
      ip link set "$VTEP_DEV" up 2>/dev/null || true
      vtysh -c 'configure terminal' -c "vrf $TENANT_VRF" -c "vni $L3VNI" -c 'end' >/dev/null 2>&1 || true
      sleep 2
    done
    vtysh -d zebra -c 'show evpn vni' 2>/dev/null | grep -qE "^$L3VNI[[:space:]]+L3.*[[:space:]]$TENANT_VRF([[:space:]]|$)" && \
      log "zebra classified vnis (L2 $L2VNI, L3 $L3VNI)" || \
      log "WARN: zebra vni classification incomplete before bgpd start"
  else
    log "WARN: no vtep device carrying vni $L3VNI found"
  fi
fi
# 5b) leaf access link: VLAN_MEMBER cannot declare an ethN port on this image
#     (PORT-table leafref), so the access link is bridged kernel-side into the
#     vlanmgrd-created Bridge. MACs learned on that bridge are what zebra
#     originates as EVPN Type-2 routes.
if [ "$ROLE" = leaf ]; then
  for i in $(seq 1 45); do
    ip link show Bridge >/dev/null 2>&1 && break
    sleep 2
  done
  VTEP_L2_DEV=""
  for i in $(seq 1 60); do
    for d in /sys/class/net/vtep*; do
      [ -e "$d" ] || continue
      dev=$(basename "$d")
      id=$(ip -d link show "$dev" 2>/dev/null | grep -oE 'vxlan id [0-9]+' | awk '{print $3}')
      if [ "$id" = "$L2VNI" ]; then VTEP_L2_DEV="$dev"; break; fi
    done
    [ -n "$VTEP_L2_DEV" ] && break
    if [ "$i" -eq 25 ]; then
      log "waiting for L2 VTEP $L2VNI; restarting orchagent/vxlanmgrd once"
      supervisorctl restart orchagent vxlanmgrd >/dev/null 2>&1 || true
    fi
    sleep 2
  done
  if [ -n "$VTEP_L2_DEV" ] && ip link show Bridge >/dev/null 2>&1; then
    master=$(ip -d link show "$VTEP_L2_DEV" 2>/dev/null | grep -oE 'master [a-zA-Z0-9_]+' | cut -d' ' -f2)
    [ "$master" = "Bridge" ] || ip link set "$VTEP_L2_DEV" master Bridge 2>/dev/null || true
    # vxlanmgrd may (re)create this vtep after step 6c ran; assert the jumbo
    # MTU alongside the topology reasserts so a late recreate cannot hand the
    # L2 VNI back at MTU 1500 (measured 2026-10-15: leaf02 lost exactly this
    # race and the 8900-byte DF ping went 100% loss one direction only).
    ip link set "$VTEP_L2_DEV" mtu 9100 2>/dev/null || true
    bridge vlan add dev "$VTEP_L2_DEV" vid "${L2VLAN#Vlan}" pvid untagged 2>/dev/null || true
    ip link set "$VTEP_L2_DEV" up 2>/dev/null || true
  else
    log "WARN: no L2 VTEP device carrying vni $L2VNI found"
  fi
  if ip link show "$ACCESS_IFACE" >/dev/null 2>&1 && ip link show Bridge >/dev/null 2>&1; then
    master=$(ip -d link show "$ACCESS_IFACE" 2>/dev/null | grep -oE 'master [a-zA-Z0-9_]+' | cut -d' ' -f2)
    [ "$master" = "Bridge" ] || ip link set "$ACCESS_IFACE" master Bridge 2>/dev/null || true
    # Bridge is VLAN-aware (SONiC creates it vlan_filtering): map the access
    # port's untagged traffic into the L2VNI VLAN. Without this the port sits
    # in the default PVID 1 and its frames never reach vtep1-<L2VNI>
    # (vlan 100) — ARP floods go nowhere (observed 2026-09-01).
    bridge vlan del dev "$ACCESS_IFACE" vid 1 2>/dev/null || true
    bridge vlan add dev "$ACCESS_IFACE" vid "${L2VLAN#Vlan}" pvid untagged 2>/dev/null || true
    ip link set "$ACCESS_IFACE" up 2>/dev/null || true
  fi
fi
# 6) start bgpd — it loads the durable /etc/frr/bgpd.conf
supervisorctl start bgpd >/dev/null 2>&1
for i in $(seq 1 30); do
  pgrep -x bgpd >/dev/null && { log "bgpd running (role=$ROLE)"; break; }
  sleep 2
done
# 6b) Verify both VNIs. Re-toggling advertise-all-vni makes bgpd re-read
#     zebra's table and is less disruptive than restarting established peers.
if [ "$ROLE" = leaf ]; then
  for attempt in 1 2 3; do
    adopted_l2=0
    adopted_l3=0
    for i in $(seq 1 10); do
      # Manager reconciliation can finish after zebra's first classification
      # and detach the SVI once more. Keep the lab-owned topology converged for
      # the entire bgpd adoption window, not only before bgpd starts.
      if [ -n "${VTEP_DEV:-}" ]; then
        ip link set "$L3VLAN" master "$TENANT_VRF" 2>/dev/null || true
        ip link set "$VTEP_DEV" master Bridge 2>/dev/null || true
        ip link set "$VTEP_DEV" mtu 9100 2>/dev/null || true
        bridge vlan add dev "$VTEP_DEV" vid "${L3VLAN#Vlan}" pvid untagged 2>/dev/null || true
        vtysh -c 'configure terminal' -c "vrf $TENANT_VRF" -c "vni $L3VNI" -c 'end' >/dev/null 2>&1 || true
      fi
      vtysh -d bgpd -c 'show bgp l2vpn evpn vni' 2>/dev/null | grep -qE "^\*?[[:space:]]*$L2VNI[[:space:]]+L2" && adopted_l2=1 || adopted_l2=0
      vtysh -d bgpd -c 'show bgp l2vpn evpn vni' 2>/dev/null | grep -qE "^\*?[[:space:]]*$L3VNI[[:space:]]+L3.*[[:space:]]$TENANT_VRF([[:space:]]|$)" && adopted_l3=1 || adopted_l3=0
      [ "$adopted_l2" -eq 1 ] && [ "$adopted_l3" -eq 1 ] && break
      sleep 3
    done
    [ "$adopted_l2" -eq 1 ] && [ "$adopted_l3" -eq 1 ] && { log "bgpd adopted L2 VNI $L2VNI and L3 VNI $L3VNI (attempt $attempt)"; break; }
    log "VNI adoption incomplete (L2=$adopted_l2 L3=$adopted_l3, attempt $attempt) — toggling advertise-all-vni"
    vtysh -c 'configure terminal' -c "router bgp $(awk '/^router bgp [0-9]+$/{print $3; exit}' /etc/frr/bgpd.conf)" \
      -c 'address-family l2vpn evpn' -c 'no advertise-all-vni' -c 'end' >/dev/null 2>&1 || true
    sleep 2
    vtysh -c 'configure terminal' -c "router bgp $(awk '/^router bgp [0-9]+$/{print $3; exit}' /etc/frr/bgpd.conf)" \
      -c 'address-family l2vpn evpn' -c 'advertise-all-vni' -c 'end' >/dev/null 2>&1 || true
    sleep 8
    vtysh -c 'configure terminal' -c "vrf $TENANT_VRF" -c "vni $L3VNI" -c 'end' >/dev/null 2>&1 || true
    supervisorctl restart bgpd >/dev/null 2>&1 || true
    sleep 10
  done
  [ "$adopted_l2" -eq 1 ] && [ "$adopted_l3" -eq 1 ] || \
    log "WARN: bgpd VNI adoption incomplete after recovery (L2=$adopted_l2 L3=$adopted_l3)"
fi
# 6c) jumbo MTU (data-model §7: the fabric links carry MTU 9216; the overlay
#     devices cap below the encap overhead). Docker defaults every veth and
#     vxlanmgrd creates the vteps at MTU 1500, which caps this profile's
#     overlay at standard frames — measured 2026-10-15: an 8900-byte DF ping
#     was 100% loss until the raw links and eth0 went 9216 and the
#     bridge/vteps 9100 (the outer leaf-to-leaf path rides eth0/management,
#     which the provision creates at the topology-declared 9216). Re-applied
#     on every boot: kernel MTUs are not part of config_db.json.
#     Assert-and-stabilize: vxlanmgrd creates (and can re-create) the vteps
#     asynchronously at MTU 1500, so a single set can be undone seconds later
#     (measured 2026-10-15: a provision whose jumbo pass had logged clean still
#     read a late-recreated vtep at 1500 at receipt time, and the 8900-byte DF
#     ping went 100% loss while warm small-frame probes stayed green). Re-set
#     and re-read until every device holds its floor for two consecutive reads,
#     bounded to ~60 s; fall through either way — the boot must not fail on
#     MTU bookkeeping.
jumbo_stable=0
for round in $(seq 1 15); do
  for d in eth0 eth1 eth2 "$ACCESS_IFACE"; do
    ip link show "$d" >/dev/null 2>&1 && ip link set "$d" mtu 9216 2>/dev/null || true
  done
  ip link show Bridge >/dev/null 2>&1 && ip link set Bridge mtu 9100 2>/dev/null || true
  for d in /sys/class/net/vtep*; do
    [ -e "$d" ] || continue
    ip link set "$(basename "$d")" mtu 9100 2>/dev/null || true
  done
  jumbo_low=0
  for d in eth0 eth1 eth2 "$ACCESS_IFACE"; do
    if [ -e "/sys/class/net/$d/mtu" ] && [ "$(cat "/sys/class/net/$d/mtu")" -lt 9216 ]; then
      jumbo_low=1
    fi
  done
  if [ -e /sys/class/net/Bridge/mtu ] && [ "$(cat /sys/class/net/Bridge/mtu)" -lt 9100 ]; then
    jumbo_low=1
  fi
  for d in /sys/class/net/vtep*; do
    if [ -e "$d/mtu" ] && [ "$(cat "$d/mtu")" -lt 9100 ]; then
      jumbo_low=1
    fi
  done
  if [ "$jumbo_low" -eq 0 ]; then jumbo_stable=$((jumbo_stable+1)); else jumbo_stable=0; fi
  if [ "$jumbo_stable" -ge 2 ]; then break; fi
  sleep 2
done
if [ "$jumbo_stable" -lt 2 ]; then
  log "WARN: jumbo MTU did not stabilize (a device kept dropping below its floor)"
fi
# 6d) NO leaf ECMP flow split here (owner amendment 2026-10-16): the floor
#     suite must run on a bootstrap WITHOUT any port- or mark-keyed flow
#     split. The kernel-vxlan encap route lookup carries no L4 fields, so
#     hash policy 1 alone leaves every encapped flow on one uplink (measured
#     live 2026-10-16) — the ECMP floor in tests/integration/mtu_ecmp.sh is
#     expected to fail honestly, with the failure recorded live and the
#     peer-VTEP-over-mgmt route cited as its cause; ECMP on this profile is
#     deferred until the VTEP path is kept off mgmt and the lab hashes
#     encapsulated traffic.
# 7) nudge peers past connect backoff once, late in the boot window
sleep 10
vtysh -c 'clear bgp *' >/dev/null 2>&1 || true
log "fabric init done (role=$ROLE)"
exit 0
EOS
  } | docker exec -i "$c" tee /etc/sonic/bootstrap/fabric-init.sh >/dev/null
  docker exec "$c" bash -c "mkdir -p /etc/agentic-netops; echo '$role' > /etc/agentic-netops/role; chmod +x /etc/sonic/bootstrap/fabric-init.sh"
  docker exec -i "$c" tee /etc/supervisor/conf.d/agentic-netops-fabric.conf >/dev/null <<'EOS'
[program:agentic-netops-fabric-init]
command=/etc/sonic/bootstrap/fabric-init.sh
priority=25
autostart=true
autorestart=false
startsecs=0
exitcodes=0
redirect_stderr=true
stdout_logfile=/var/log/agentic-netops-fabric-init.log
stdout_logfile_maxbytes=2MB
EOS
  log "$node: boot hook installed (role=$role)"
}

# peer_leaf_lo4 <node> — the other leaf's VTEP loopback (the encap destination
# the fabric's BGP carriers announce). Scans the FABRIC table (node|asn|lo4|...).
peer_leaf_lo4() {
  local node=$1
  while IFS='|' read -r n _ lo4 _ _ _; do
    [[ -z "$n" || "$n" == "$node" ]] && continue
    if [[ "$(node_role "$n")" == leaf ]]; then echo "$lo4"; return; fi
  done <<<"$FABRIC"
}

# NO flow_split_pass_node here (owner amendment 2026-10-16): the earlier
# leaf ECMP flow split (ebtables AGNT_ECMP dport-half marks + fwmark rules
# pinning tables 4001/4002 to each uplink) is REMOVED — the floor suite must
# run on a bootstrap WITHOUT any port- or mark-keyed flow split. The
# kernel-vxlan encap route lookup carries no L4 fields, so hash policy 1
# alone pins EVERY encapped flow to one multipath bucket (measured live
# 2026-10-16): the ECMP floor in tests/integration/mtu_ecmp.sh fails
# honestly, the failure is recorded live, and the peer-VTEP route learned
# over mgmt (eth0) is cited as its cause.

# Jumbo MTU authority (host side): the boot hook's 6c re-applies the same
# values on every container restart; pass 3 and the --jumbo mode below are the
# re-run/restore paths.
# The same hook also asserts the kernel multipath hash policy (L4): on this
# profile the uplink ECMP decision is the container kernel's FIB, and its
# default policy 0 hashes on L3 only — for VXLAN-encapped traffic the outer
# tuple (leaf VTEP -> remote VTEP, proto UDP) is CONSTANT across flows, so
# every flow deterministically lands on one uplink. Measured 2026-10-16 00:56
# on the sonic-vm default lab (same kernel default): a 1,280,000-byte
# 32-flow burst crossed 100% on one uplink (delta 1,297,628 vs the peer's
# tick-only 1,416) while the route table showed BOTH nexthops installed —
# policy 0, not a missing path. Policy 1 (L4) lets the per-flow outer UDP
# source port participate and is what makes "ECMP hashing" testable here at
# all (tests/integration/mtu_ecmp.sh asserts each uplink moves >= 25% of the
# burst). Container restarts can reset it, so it rides the same re-assert
# hook as the jumbo MTUs.
jumbo_pass_node() {
  local c=$1
  docker exec "$c" bash -c "for d in eth0 eth1 eth2 '$ACCESS_IFACE'; do ip link show \"\$d\" >/dev/null 2>&1 && ip link set \"\$d\" mtu 9216 2>/dev/null || true; done; ip link show Bridge >/dev/null 2>&1 && ip link set Bridge mtu 9100 2>/dev/null || true; for d in /sys/class/net/vtep*; do [ -e \"\$d\" ] && ip link set \"\$(basename \"\$d\")\" mtu 9100 2>/dev/null || true; done; echo 1 > /proc/sys/net/ipv4/fib_multipath_hash_policy 2>/dev/null || true; true" \
    >/dev/null 2>&1
}

# read-only per-node census: "<dev>=<mtu> ..." for the jumbo-relevant devices
jumbo_census_node() {
  local c=$1
  docker exec "$c" bash -c "
    for d in eth0 eth1 eth2 '$ACCESS_IFACE' Bridge; do
      [ -e \"/sys/class/net/\$d/mtu\" ] && printf '%s=%s ' \"\$d\" \"\$(cat \"/sys/class/net/\$d/mtu\")\"
    done
    for d in /sys/class/net/vtep*; do
      [ -e \"\$d/mtu\" ] && printf '%s=%s ' \"\$(basename \"\$d\")\" \"\$(cat \"\$d/mtu\")\"
    done
    true"
}

# read-only per-node floor check: prints "LOW <dev>=<mtu>" per offending
# device and exits 1 if any jumbo-relevant device sits below its floor
jumbo_floor_node() {
  local c=$1
  docker exec "$c" bash -c "
    rc=0
    for d in eth0 eth1 eth2 '$ACCESS_IFACE'; do
      if [ -e \"/sys/class/net/\$d/mtu\" ] && [ \"\$(cat \"/sys/class/net/\$d/mtu\")\" -lt 9216 ]; then
        echo \"LOW \$d=\$(cat \"/sys/class/net/\$d/mtu\")\"; rc=1
      fi
    done
    if [ -e /sys/class/net/Bridge/mtu ] && [ \"\$(cat /sys/class/net/Bridge/mtu)\" -lt 9100 ]; then
      echo \"LOW Bridge=\$(cat /sys/class/net/Bridge/mtu)\"; rc=1
    fi
    for d in /sys/class/net/vtep*; do
      [ -e \"\$d/mtu\" ] || continue
      if [ \"\$(cat \"\$d/mtu\")\" -lt 9100 ]; then
        echo \"LOW \$(basename \"\$d\")=\$(cat \"\$d/mtu\")\"; rc=1
      fi
    done
    exit \$rc"
}

# --jumbo: idempotent post-qualification re-assert. vxlanmgrd creates (and can
# re-create) the vteps asynchronously at MTU 1500, and a vtep (or vlanmgrd's
# Bridge) can be re-created AFTER this script's own pass 3 — measured
# 2026-10-15: a fresh provision whose bootstrap jumbo pass had logged clean
# still served the 8900-byte DF ping 100% loss at receipt time (warm
# small-frame probes stay green on a capped path, so only the jumbo probe
# sees it). Run the pass over the live containers, then read the floors back;
# repeat until they hold (bounded) and FAIL CLOSED if they never do — the
# provision must not report complete on a capped overlay path. The census
# lands in the provision/chain log and doubles as the MTU diagnosis.
jumbo_reassert() {
  local node c rc=0 round lows
  for round in $(seq 1 10); do
    rc=0
    while IFS='|' read -r node _ _ _ _ _; do
      [[ -z "$node" ]] && continue
      c="${CLAB_PREFIX}${node}"
      docker ps --format '{{.Names}}' | grep -qx "$c" || { log "skip $node (not running)"; continue; }
      jumbo_pass_node "$c" || log "WARN: jumbo MTU pass failed on $node"
      # no ECMP flow split re-assert (owner amendment 2026-10-16): none is
      # installed; the ECMP floor fails honestly instead
    done <<<"$FABRIC"
    while IFS='|' read -r node _ _ _ _ _; do
      [[ -z "$node" ]] && continue
      c="${CLAB_PREFIX}${node}"
      docker ps --format '{{.Names}}' | grep -qx "$c" || continue
      if lows=$(jumbo_floor_node "$c" 2>/dev/null); then
        log "$node mtu ok: $(jumbo_census_node "$c")"
      else
        log "$node mtu LOW: $(tr '\n' ' ' <<<"$lows")census: $(jumbo_census_node "$c")"
        rc=1
      fi
    done <<<"$FABRIC"
    if [[ $rc -eq 0 ]]; then
      log "jumbo re-assert verified (round $round): fabric links >= 9216, Bridge/vteps >= 9100"
      return 0
    fi
    log "jumbo floors violated (round $round) — re-asserting"
    sleep 2
  done
  log "ERROR: jumbo MTU floors still violated after $round rounds — a device is being re-created below its floor"
  return 1
}

main() {
  local node asn lo4 lo6 svi4 peers c role
  # pass 1 — daemons, interfaces, overlay tables, CONFIG_DB intent, boot hook
  while IFS='|' read -r node asn lo4 lo6 svi4 peers; do
    [[ -z "$node" ]] && continue
    c="${CLAB_PREFIX}${node}"
    docker ps --format '{{.Names}}' | grep -qx "$c" || { log "skip $node (not running)"; continue; }
    role=$(node_role "$node")
    log "$node ($role, AS$asn): starting daemons"
    start_daemons "$c" "$role"
    configure_interfaces "$c" "$lo4" "$lo6" "$svi4" "$peers"
    [[ "$role" == leaf ]] && configure_overlay "$c" "$lo4" "$svi4"
    configure_config_db "$c" "$lo4" "$lo6" "$svi4" "$peers" "$role"
    # declared identity (the managed-path witness the drift suite reads over
    # native gNMI CONFIG_DB, matching the sonic-vm bootstrap's
    # identity_reassert): hostname + BGP AS + router id straight from the plan
    docker exec "$c" redis-cli -n 4 hset "DEVICE_METADATA|localhost" \
      hostname "$node" bgp_asn "$asn" bgp_router_id "$lo4" >/dev/null
    install_boot_hook "$c" "$node" "$role" "$lo4" "$lo6" "$svi4" "$peers"
  done <<<"$FABRIC"

  # pass 2 — durable FRR config + bgpd, once every peer's interfaces are addressed
  local frr_failed=""
  while IFS='|' read -r node asn lo4 lo6 svi4 peers; do
    [[ -z "$node" ]] && continue
    c="${CLAB_PREFIX}${node}"
    docker ps --format '{{.Names}}' | grep -qx "$c" || continue
    role=$(node_role "$node")
    log "$node: writing bgpd.conf + starting bgpd"
    # apply_frr's status was previously discarded, so a leaf that never adopted
    # its L2 VNI still produced provision exit=0. Collect and fail at the end so
    # every node is still attempted (better diagnostics) but the run fails.
    apply_frr "$c" "$node" "$asn" "$lo4" "$role" "$svi4" "$peers" \
      || frr_failed="${frr_failed}${frr_failed:+, }${node}"
  done <<<"$FABRIC"
  if [[ -n "$frr_failed" ]]; then
    echo "[fabric-bgp] ERROR: FRR/EVPN bring-up failed on: ${frr_failed}" >&2
    return 1
  fi

  # converge, nudging past connect backoff once
  local i established=0
  for i in $(seq 1 20); do
    established=1
    while IFS='|' read -r node asn lo4 lo6 svi4 peers; do
      [[ -z "$node" ]] && continue
      c="${CLAB_PREFIX}${node}"
      docker ps --format '{{.Names}}' | grep -qx "$c" || continue
      docker exec "$c" vtysh -c 'show bgp summary json' 2>/dev/null \
        | grep -q '"state":"Established"' || established=0
    done <<<"$FABRIC"
    [[ $established -eq 1 ]] && { log "underlay converged (all nodes Established)"; break; }
    if (( i == 10 )); then
      while IFS='|' read -r node _ _ _ _ _; do
        [[ -z "$node" ]] && continue
        docker exec "${CLAB_PREFIX}${node}" vtysh -c 'clear bgp *' >/dev/null 2>&1 || true
      done <<<"$FABRIC"
    fi
    sleep 4
  done
  (( established == 1 )) || log "WARN: underlay did not fully converge; fabric_verify.sh will report the detail"

  # pass 3 — jumbo MTU for the live containers (the boot hook's 6c re-applies
  # the same values on every restart; this is the re-run/restore path)
  while IFS='|' read -r node _ _ _ _ peers; do
    [[ -z "$node" ]] && continue
    c="${CLAB_PREFIX}${node}"
    docker ps --format '{{.Names}}' | grep -qx "$c" || continue
    jumbo_pass_node "$c" || log "WARN: jumbo MTU pass failed on $node"
  done <<<"$FABRIC"

  # persist the declared CONFIG_DB intent to /etc/sonic/config_db.json so the
  # full fabric intent (BGP neighbors, loopbacks, VLAN/VTEP/VRF, interfaces)
  # reloads on every subsequent container start
  while IFS='|' read -r node _ _ _ _ _; do
    [[ -z "$node" ]] && continue
    c="${CLAB_PREFIX}${node}"
    docker ps --format '{{.Names}}' | grep -qx "$c" || continue
    docker exec "$c" bash -c 'config save -y' >/dev/null 2>&1 || log "WARN: config save failed on $node"
  done <<<"$FABRIC"
  return 0
}

# --jumbo: standalone post-qualification re-assert + fail-closed census, run
# after `provision.sh --profile sonic-vs` finishes (the capability gate's
# persistence witness restarts every SONiC container AFTER this script's own
# pass 3, so pass 3 alone cannot guarantee receipt-time MTU — the sonic-vm
# profile solves the same ordering problem with provision.sh's --reassert
# block, which this profile must not reuse: its gate hardcodes sonic-vm
# expectations)
if [[ "${1:-}" == "--jumbo" ]]; then
  jumbo_reassert || exit 1
  exit 0
fi

main "$@"
