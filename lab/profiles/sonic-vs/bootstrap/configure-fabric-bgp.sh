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
#     /etc/supervisor/conf.d/ainetops-fabric.conf (autostart=true). The
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

CLAB_PREFIX=${CLAB_PREFIX:-clab-ainetops-fabric-}

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
    redis-cli -n 4 hset 'VLAN|$VLAN' vlanid '${VLAN#Vlan}' >/dev/null
    redis-cli -n 4 hset 'VXLAN_TUNNEL_MAP|$VTEP|map_${L2VNI}_$VLAN' vni '$L2VNI' vlan '$VLAN' >/dev/null
    redis-cli -n 4 hset 'VLAN|$L3VLAN' vlanid '${L3VLAN#Vlan}' >/dev/null
    redis-cli -n 4 hset 'VXLAN_TUNNEL_MAP|$VTEP|map_${L3VNI}_$L3VLAN' vni '$L3VNI' vlan '$L3VLAN' >/dev/null
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
up.apply_patch(jsonpatch.JsonPatch([
    {"op": "add", "path": "/LOOPBACK_INTERFACE", "value": lo},
    {"op": "add", "path": "/BGP_NEIGHBOR", "value": nbr},
]), ConfigFormat.CONFIGDB, False, False, False, [])

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
    up.apply_patch(jsonpatch.JsonPatch(leaf_patch), ConfigFormat.CONFIGDB, False, False, False, [])
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
  conf+=" !\n address-family ipv4 unicast\n  redistribute connected\n$v4nbrs exit-address-family\n"
  conf+=" !\n address-family ipv6 unicast\n  redistribute connected\n$v6nbrs exit-address-family\n"
  conf+=" !\n address-family l2vpn evpn\n$v4nbrs"
  # advertise-all-vni is what makes zebra hand its VNIs (L2VNI + L3VNI) to bgpd;
  # without it `show evpn vni` stays empty and no Type-2/3/5 route is originated.
  [[ "$role" == leaf ]] && conf+="  advertise-all-vni\n"
  conf+=" exit-address-family\n!\n"
  if [[ "$role" == leaf ]]; then
    # FRR vrf definition block: binds the L3VNI to the tenant VRF (FRR 10 needs
    # this on top of the kernel vrf_slave for Type-5 origination).
    conf+="vrf $TENANT_VRF\n vni $L3VNI\nexit-vrf\n!\n"
    conf+="router bgp $asn vrf $TENANT_VRF\n"
    conf+=" address-family ipv4 unicast\n  redistribute connected\n exit-address-family\n"
    conf+=" !\n address-family l2vpn evpn\n  advertise ipv4 unicast\n exit-address-family\n!\n"
  fi
  conf+="line vty\n"
  printf '%b' "$conf" | docker exec -i "$c" tee /etc/frr/bgpd.conf >/dev/null
}

# Host-side counterpart of the fabric-init hook's leaf block: make sure the
# vlanmgrd/vxlanmgrd/vrfmgrd devices exist and carry the kernel state FRR needs
# (SVI address + VRF membership, L3VNI vtep enslaved to the tenant VRF). The
# managers of this build warm-read nothing at startup — they only react to
# live CONFIG_DB changes — so they are (re)started here to process the tables
# written above. bgpd classifies the L3VNI from kernel state at startup, so
# this MUST complete before bgpd loads its vrf stanza.
ensure_overlay_devices() {
  local c=$1 svi4=$2
  docker exec "$c" supervisorctl restart vlanmgrd vxlanmgrd >/dev/null 2>&1 || true
  local i dev id master vtep_dev=""
  for i in $(seq 1 60); do
    vtep_dev=""
    for dev in $(docker exec "$c" bash -c 'ls /sys/class/net/ 2>/dev/null | grep "^vtep" || true'); do
      id=$(docker exec "$c" bash -c "ip -d link show $dev 2>/dev/null | grep -oE 'vxlan id [0-9]+' | awk '{print \$3}'" 2>/dev/null)
      [[ "$id" == "$L3VNI" ]] && { vtep_dev=$dev; break; }
    done
    [[ -n "$vtep_dev" ]] && docker exec "$c" bash -c "ip link show $L3VLAN >/dev/null 2>&1" && break
    sleep 2
  done
  # L3VLAN device fallback (see fabric-init hook comment): create kernel-side
  # if vlanmgrd did not
  docker exec "$c" bash -c "ip link show $L3VLAN >/dev/null 2>&1 || ip link add $L3VLAN link Bridge type vlan id ${L3VLAN#Vlan} 2>/dev/null || true" || true
  [[ -n "$vtep_dev" ]] || { echo "[fabric-bgp] WARN: no vtep carrying vni $L3VNI on $c" >&2; return 0; }
  docker exec "$c" bash -c "
    ip link set $L3VLAN up 2>/dev/null || true
    ip -br addr show $L3VLAN 2>/dev/null | grep -q '$svi4/24' || ip addr add $svi4/24 dev $L3VLAN 2>/dev/null || true
    ip link set $L3VLAN master $TENANT_VRF 2>/dev/null || true
    bridge vlan del dev $ACCESS_IFACE vid 1 2>/dev/null || true
    bridge vlan add dev $ACCESS_IFACE vid ${VLAN#Vlan} pvid untagged 2>/dev/null || true
    master=\$(ip -d link show $vtep_dev 2>/dev/null | grep -oE 'master [a-zA-Z0-9_]+' | cut -d' ' -f2)
    [ \"\$master\" = '$TENANT_VRF' ] || ip link set $vtep_dev master $TENANT_VRF 2>/dev/null || true
    ip -d link show $vtep_dev 2>/dev/null | grep -q 'master $TENANT_VRF' && echo '[fabric-bgp] L3VNI $vtep_dev bound to $TENANT_VRF'
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
  fi
  docker exec "$c" supervisorctl restart bgpd >/dev/null 2>&1 \
    || docker exec "$c" supervisorctl start bgpd >/dev/null 2>&1 \
    || { echo "[fabric-bgp] ERROR: bgpd on $node could not be (re)started" >&2; return 1; }
  local i
  for i in $(seq 1 30); do
    docker exec "$c" bash -c 'pgrep -x bgpd >/dev/null' 2>/dev/null && break
    sleep 2
  done
  # VNI-adoption verification (mirrors hook step 6b): bgpd queries zebra's VNI
  # table once at startup — a lost race leaves it with zero VNIs permanently.
  # Restart-escalate until the L2 VNI shows up (leaf only).
  if [ "$role" = leaf ]; then
    local attempt adopted
    for attempt in 1 2 3; do
      adopted=0
      for i in $(seq 1 10); do
        docker exec "$c" bash -c "vtysh -d bgpd -c 'show bgp l2vpn evpn vni' 2>/dev/null | grep -q '^ \\* $L2VNI '" && { adopted=1; break; }
        sleep 3
      done
      [ "$adopted" -eq 1 ] && { echo "[fabric-bgp] $node: bgpd adopted L2 VNI $L2VNI (attempt $attempt)"; break; }
      echo "[fabric-bgp] $node: bgpd missing L2 VNI $L2VNI (attempt $attempt) — restarting"
      docker exec "$c" supervisorctl restart bgpd >/dev/null 2>&1 || true
      sleep 10
    done
    # Exhausting the escalation is a HARD failure, not a warning. Without the L2
    # VNI adopted, bgpd never processes the peer IMET: zebra installs no remote
    # VTEP, nothing floods, and every overlay ping fails 100%. This previously
    # fell through silently and provision still exited 0, so a structurally dead
    # fabric reached test-fabric and was misread as slow convergence
    # (2026-09-01: re-run cycle 1/2, leaf01, all 3 attempts exhausted).
    if [ "$adopted" -ne 1 ]; then
      echo "[fabric-bgp] ERROR: $node: bgpd never adopted L2 VNI $L2VNI after 3 restarts — overlay cannot forward; failing provision" >&2
      return 1
    fi
  fi
  docker exec "$c" bash -c 'pgrep -x bgpd >/dev/null' 2>/dev/null || { echo "[fabric-bgp] ERROR: bgpd did not start on $node" >&2; return 1; }
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
    echo "# AINETOPS fabric init for $node (role=$role) — generated at bootstrap"
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
    echo "SVI4='$svi4'"
    echo "LO4='$lo4'"
    echo "LO6='$lo6'"
    echo "PEERS='$peers'"
    cat <<'EOS'
# 1) CONFIG_DB must be loaded (start.sh/configdb-load.sh) before anything else
for i in $(seq 1 90); do
  [ -n "$(redis-cli -n 4 hget 'DEVICE_METADATA|localhost' switch_type 2>/dev/null)" ] && break
  sleep 2
done
# 2) manager daemons (started by start.sh) must be RUNNING before bgpd
for i in $(seq 1 60); do
  supervisorctl status zebra 2>/dev/null | grep -q RUNNING && \
    supervisorctl status fpmsyncd 2>/dev/null | grep -q RUNNING && break
  sleep 2
done
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
# 5) leaf L3VLAN SVI + L3VNI binding. Everything here must be final BEFORE bgpd
#    starts: bgpd classifies vni $L3VNI as the tenant VRF's L3VNI from the
#    kernel device state at startup, so the vtep must already be enslaved when
#    it loads its vrf stanza (a later re-enslavement is not picked up).
if [ "$ROLE" = leaf ] && [ -n "$SVI4" ]; then
  # 5a) wait for vxlanmgrd/vlanmgrd to (re)create the devices — they start in
  #     parallel with this hook and take a while after CONFIG_DB load. The vtep
  #     device name does not encode the VNI (vni 1000 lands as vtep1-2000,
  #     suffixed with the L3VLAN id), so resolve it by its vxlan id.
  VTEP_DEV=""
  for i in $(seq 1 90); do
    ip link show "$L3VLAN" >/dev/null 2>&1 && break
    sleep 2
  done
  # vlanmgrd's creation of the L3VLAN device proved unreliable across boots
  # (observed 2026-09-01: Vlan2000 missing after a clean supervisorctl cycle),
  # so create it kernel-side if it is still absent — the VLAN table row stays
  # the declared intent; this only materializes the device.
  ip link show "$L3VLAN" >/dev/null 2>&1 || \
    ip link add "$L3VLAN" link Bridge type vlan id "${L3VLAN#Vlan}" 2>/dev/null || true
  for i in $(seq 1 90); do
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
    [ "$master" = "$TENANT_VRF" ] || ip link set "$VTEP_DEV" master "$TENANT_VRF" 2>/dev/null || true
    master=$(ip -d link show "$VTEP_DEV" 2>/dev/null | grep -oE 'master [a-zA-Z0-9_]+' | cut -d' ' -f2)
    if [ "$master" = "$TENANT_VRF" ]; then
      log "L3VNI vtep $VTEP_DEV (vni $L3VNI) bound to $TENANT_VRF"
    else
      log "WARN: $VTEP_DEV not bound to $TENANT_VRF (master=${master:-none})"
    fi
    # 5c) bgpd builds its VNI table from zebra ONCE, right after it starts —
    #     if zebra has not classified the VNIs yet (vxlanmgrd created the vtep
    #     devices concurrently), bgpd ends up with none and no IMET/Type-2/5
    #     ever flows. Wait for zebra to classify both VNIs, nudging it with a
    #     re-enslave + link flap (and, if still unclassified, a vxlanmgrd
    #     restart that recreates the devices with fresh netlink events).
    vxrestart=0
    for i in $(seq 1 45); do
      zn=$(vtysh -d zebra -c 'show evpn vni' 2>/dev/null)
      echo "$zn" | grep -q "^$L2VNI " && \
        echo "$zn" | grep -q "^$L3VNI .*L3" && break
      if echo "$zn" | grep -q "^$L3VNI .*L3"; then
        ip link set "$VTEP_DEV" down 2>/dev/null || true
        sleep 1
        ip link set "$VTEP_DEV" up 2>/dev/null || true
      elif [ $vxrestart -eq 0 ] && [ $((i % 8)) -eq 0 ]; then
        vxrestart=1
        supervisorctl restart vxlanmgrd >/dev/null 2>&1 || true
        sleep 15
        ip link set "$VTEP_DEV" master "$TENANT_VRF" 2>/dev/null || true
        ip link set "$VTEP_DEV" down 2>/dev/null || true
        sleep 1
        ip link set "$VTEP_DEV" up 2>/dev/null || true
      else
        ip link set "$VTEP_DEV" nomaster 2>/dev/null || true
        sleep 1
        ip link set "$VTEP_DEV" master "$TENANT_VRF" 2>/dev/null || true
        ip link set "$VTEP_DEV" down 2>/dev/null || true
        sleep 1
        ip link set "$VTEP_DEV" up 2>/dev/null || true
      fi
      sleep 3
    done
    vtysh -d zebra -c 'show evpn vni' 2>/dev/null | grep -q "^$L3VNI .*L3" && \
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
# 6b) VERIFY the VNI table actually adopted (leaf only). bgpd queries zebra's
#     VNI table exactly once at startup; losing that race leaves bgpd with zero
#     VNIs forever — no IMET, no remote VTEPs, no Type-2/3 (observed again in the
#     2026-09-01 forced rerun, cycle 1: leaf02 ended with "L2 VNIs: 0" while
#     leaf01 won the race). bgpd restarts are cheap and re-trigger the query, so
#     verify-and-restart makes adoption deterministic instead of lucky.
if [ "$ROLE" = leaf ]; then
  for attempt in 1 2 3; do
    adopted=0
    for i in $(seq 1 10); do
      vtysh -d bgpd -c 'show bgp l2vpn evpn vni' 2>/dev/null | grep -q "^ \\* $L2VNI " && { adopted=1; break; }
      sleep 3
    done
    [ "$adopted" -eq 1 ] && { log "bgpd adopted L2 VNI $L2VNI (attempt $attempt)"; break; }
    log "bgpd missing L2 VNI $L2VNI (attempt $attempt) — restarting bgpd to re-query zebra"
    supervisorctl restart bgpd >/dev/null 2>&1 || true
    sleep 10
  done
  vtysh -d bgpd -c 'show bgp l2vpn evpn vni' 2>/dev/null | grep -q "^ \\* $L2VNI " || \
    log "WARN: bgpd still has no L2 VNI $L2VNI after 3 restarts"
fi
# 7) nudge peers past connect backoff once, late in the boot window
sleep 10
vtysh -c 'clear bgp *' >/dev/null 2>&1 || true
log "fabric init done (role=$ROLE)"
exit 0
EOS
  } | docker exec -i "$c" tee /etc/sonic/bootstrap/fabric-init.sh >/dev/null
  docker exec "$c" bash -c "mkdir -p /etc/ainetops; echo '$role' > /etc/ainetops/role; chmod +x /etc/sonic/bootstrap/fabric-init.sh"
  docker exec -i "$c" tee /etc/supervisor/conf.d/ainetops-fabric.conf >/dev/null <<'EOS'
[program:ainetops-fabric-init]
command=/etc/sonic/bootstrap/fabric-init.sh
priority=25
autostart=true
autorestart=false
startsecs=0
exitcodes=0
redirect_stderr=true
stdout_logfile=/var/log/ainetops-fabric-init.log
stdout_logfile_maxbytes=2MB
EOS
  log "$node: boot hook installed (role=$role)"
}

main() {
  local line node asn lo4 lo6 svi4 peers c role
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

main "$@"
