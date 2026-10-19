#!/usr/bin/env bash
# configure-fabric.sh — the sonic-vm bootstrap: identity, underlay BGP, kernel
# prerequisites, locators + advertisement, persistence (T129-T137).
#
# Writes the four fabric nodes from lab/profiles/sonic-vm/fabric.yaml (the
# single source; the same §7/§8.2 values the sonic-vs profile carries), using
# only the write classes proven against the 202505 image in scripts/spike/:
#   - CONFIG_DB through the guest's generic_config_updater (GCU), one
#     remove/add pair per patch, whole-table re-adds of the declared intent —
#     a GCU patch aborts on its first failing op, and a remove of an absent
#     table must not stop the adds (underlay-apply.sh, spike-factory-*)
#   - SRV6_MY_LOCATORS row in its own silent-remove process, then the add in a
#     fresh one (locator-node.sh GCU class)
#   - the FRR locator binding + origination re-asserted live through vtysh
#     (locator-node.sh / vpn-setup.sh / underlay-apply.sh classes)
#   - kernel service state through /proc (kernel-prereqs.sh: seg6_enabled on
#     all/default/Ethernet0/Ethernet4/Loopback0, vrf module, strict_mode;
#     leaves only — spines never terminate the service, data-model §8.8)
#   - spine iBGP fixups (update-source + allowas-in on the leaf-facing
#     neighbors) through vtysh, live-only, re-asserted on every run
#     (underlay-apply.sh: the 202505 bgpd template renders the iBGP neighbor
#     without update-source and the 202505 YANG has no allowas-in field)
#   - a bgp unit restart ONLY when the rendered /etc/sonic/frr/bgpd.conf still
#     advertises the /64 loopback (bgpcfgd renders once at unit start; the
#     knob-only CONFIG_DB change does not re-render it) — through systemd
#     after `systemctl reset-failed bgp`, never `docker restart bgp`
#     (StartLimitBurst, measured leaf01 2026-10-13)
#
# Timers/BFD (T136, V:steer): deliberately NONE — the steering write-up
# (data-model §8.8, spike-steering-failover-*) exercises no timers and records
# the 5 s bound as unmet without them; adding any would be a new, unproven
# write class on this image.
#
# Idempotent by construction: every step re-asserts (whole-table re-adds,
# `ip addr replace`, `ip route replace`, vtysh re-apply), so the script may be
# re-run on a healthy lab, after a `config reload`, or from scratch on a
# factory image. Steps: factory clean -> identity -> fabric link addressing ->
# underlay BGP -> kernel prerequisites (leaves) -> locator + advertisement ->
# config save -> config reload + re-assert + persistence verify.
#
# Fail-closed (plan 2-14): every step's failure is counted and the script
# exits non-zero unless every applied step verified. With --dry-run it prints
# the per-node plan and touches nothing.
#
# Host-side tooling only: python3+yaml parse fabric.yaml; the guest
# conversations go through node_run from tests/integration/lib/node_exec.sh
# (SSH into the sonic-vm guest); guest python is pushed base64-through-argv
# (stdin pushes corrupt, spike-env push_file class).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
# shellcheck disable=SC1091
. "$REPO_ROOT/tests/integration/lib/node_exec.sh"

FABRIC_YAML="$SCRIPT_DIR/../fabric.yaml"
DRY_RUN=0
REASSERT=0
NODES=(spine01 spine02 leaf01 leaf02)

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --reassert) REASSERT=1 ;;
    # --nodes=<comma list>: scope this run to a subset of the four nodes.
    # Default is all four (unchanged). The failure-recovery suite passes
    # --nodes=leaf02 after rebooting leaf02: re-asserting nodes that never
    # rebooted factory-cleans the SRv6 services' applied device state on them
    # and races the controller's drift re-apply out of convergence (measured
    # live 2026-10-19, feature-004 gate 11: the reload wedged leaf01's
    # intfmgr so the service's interface rows never programmed again; the
    # gcu-based drift loop converts to 0 changes and cannot heal it).
    --nodes=*)
      IFS=, read -r -a NODES <<< "${arg#--nodes=}"
      for n in "${NODES[@]}"; do
        case " spine01 spine02 leaf01 leaf02 " in
          *" $n "*) ;;
          *) echo "unknown node in --nodes: $n" >&2; exit 2 ;;
        esac
      done
      ;;
    -h|--help) echo "usage: $0 [--dry-run] [--reassert] [--nodes=n1,n2]"; exit 0 ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

[[ -f "$FABRIC_YAML" ]] || { echo "missing $FABRIC_YAML" >&2; exit 2; }
command -v python3 >/dev/null || { echo "python3 required on the host" >&2; exit 2; }

failures=0
note_fail() { echo "FAIL: $*" >&2; failures=$((failures + 1)); }

# guest_count <container> <cmd> — run a counting command on the guest and
# print a plain integer. grep -c exits 1 when nothing matches while still
# printing "0", so the classic `|| echo 0` fallback APPENDS a second 0
# ("00"), which != "0" and false-fails every comparison (measured: 4 spurious
# /64-render FAILs per run). Tolerate empty/partial output instead.
guest_count() {
  local v
  v=$(node_run "$1" "$2" 2>/dev/null || true)
  v="${v//[^0-9]/}"
  echo "${v:-0}"
}

# bgpcfgd_nudge <node> — unstick the bgpcfgd peer queue. After a bgp UNIT
# restart the peer manager's dependency queue can stay stuck ("Not all
# dependencies are met") because the LOOPBACK_INTERFACE dependency never gets
# a live event: a unit restart does not replay redis writes the way a
# container boot does, and GCU no-ops re-writes of unchanged content.
# Re-writing the standard prefix-less row marker makes InterfaceMgr publish
# and flushes the queue. Measured live on spine01 2026-10-14: neighbors went
# 0 -> 4 in the running config after this nudge.
bgpcfgd_nudge() {
  local n=$1 c
  c=$(container_of_node "$n")
  node_run "$c" "sudo redis-cli -n 4 HSET 'LOOPBACK_INTERFACE|Loopback0' NULL NULL" >/dev/null 2>&1 || true
}

# ---------------------------------------------------------------------------
# EVPN overlay baseline — LEAVES ONLY (spines transit EVPN routes and carry no
# VTEP or tenant VRF; fabric_verify.sh asserts that absence, FR-004).
#
# T223/q3-fabric verifies the SAME as-built overlay on both profiles: the
# bridged Vlan100 as L2 VNI 100 (Type-2, client access), tenant VRF VrfBlue
# bound to L3 VNI 1000 through Vlan2000 (Type-5). The sonic-vs bootstrap
# carries that block (configure_overlay + ensure_overlay_devices +
# apply_frr's integrated vtysh binding); this bootstrap was silent, which is
# the gap pkg/fabricplan's vtepBaselineForKind compensates for at SERVICE
# time — those plan rows stay idempotent against this baseline (same tables,
# same values, byte-identical to the sonic-vs overlay so a service plan
# renders identically on either profile).
#
# Write classes are the trial-proven vm forms:
#   * CONFIG_DB rows through `sudo redis-cli -n 4 HSET` — the same raw class
#     as the locator fallback and bgpcfgd_nudge; GCU whole-config validation
#     adds nothing for these manager-owned tables and can fail image-wide on
#     unrelated factory rows.
#   * FRR live re-asserts through vtysh, because bgpcfgd renders
#     /etc/sonic/frr/bgpd.conf from CONFIG_DB only at unit start and owns
#     that file — hand edits would not survive the next render. Order follows
#     the plan ops: advertise-all-vni BEFORE any per-VNI/per-VRF work (this
#     FRR build rejects the reverse order, observed live in p4-macvrf-trial).
#   * Kernel plumbing (vtep devices, Bridge membership, SVI, VRF bind, access
#     port) through sudo ip/bridge — vlanmgrd/vxlanmgrd/vrfmgrd react to the
#     CONFIG_DB rows above, exactly as they do for service plans.
# Persistence: CONFIG_DB rows survive `config reload`; the live vtysh state
# and kernel joins do not, so the reload re-assert in Pass 3 calls
# apply_overlay_baseline again and Pass 4 gates on adoption.
# ---------------------------------------------------------------------------
L2VNI=100; VLAN=Vlan100; ACCESS_PORT=Ethernet8
L3VNI=1000; L3VLAN=Vlan2000; TENANT_VRF=VrfBlue; VTEP=vtep1
# The EVPN domain's ASN: the two spines share AS 65000 and relay the leaf
# IMETs/Type-2s (eBGP), so the symmetric route-targets below pin the whole
# domain to <spine-as>:<vni>.
SPINE_ASN=65000

# set_jumbo <node> — jumbo MTU on the data-plane devices (data-model §7: the
# eight fabric links carry MTU 9216). The image ships ports at 9100 and the
# VxLAN devices at MTU 1500 — a `config reload` re-renders both defaults — and
# the 1500-byte vtep silently caps the overlay at standard frames: measured
# 2026-10-15, an 8900-byte DF ping crossed ports at 9100 but died at
# vtep1-100 until this step raised it (the q3-mtu root cause). Kernel
# live-write class (`ip link set`, the locator-pin/vpn-setup class),
# idempotent, re-run from persistence_reassert so a reload cannot regress it.
# Overlay devices are guarded: they exist on leaves only, and only after the
# overlay baseline created them.
set_jumbo() {
  local n=$1 c state dev want
  c=$(container_of_node "$n")
  node_run "$c" "for d in Ethernet0 Ethernet4 Ethernet8; do ip link show \$d >/dev/null 2>&1 && sudo ip link set \$d mtu 9216; done; for d in Bridge $VLAN $L3VLAN vtep1-${VLAN#Vlan} vtep1-${L3VLAN#Vlan}; do ip link show \$d >/dev/null 2>&1 && sudo ip link set \$d mtu 9100; done; true" >/dev/null 2>&1 \
    || { note_fail "$n jumbo mtu apply"; return 1; }
  state=$(node_run "$c" "for d in Ethernet0 Ethernet4 Bridge $VLAN $L3VLAN vtep1-${VLAN#Vlan} vtep1-${L3VLAN#Vlan}; do printf '%s=' \$d; cat /sys/class/net/\$d/mtu 2>/dev/null || echo absent; done" 2>/dev/null)
  for dev in Ethernet0 Ethernet4; do
    [[ "$(printf '%s\n' "$state" | sed -n "s/^${dev}=//p")" == "9216" ]] || { note_fail "$n $dev mtu not 9216"; return 1; }
  done
  for dev in "Bridge" "$VLAN" "$L3VLAN" "vtep1-${VLAN#Vlan}" "vtep1-${L3VLAN#Vlan}"; do
    want=$(printf '%s\n' "$state" | sed -n "s/^${dev}=//p")
    [[ "$want" == "absent" ]] && continue
    [[ "$want" == "9100" ]] || { note_fail "$n $dev mtu $want (want 9100)"; return 1; }
  done
  echo "$n: jumbo mtu applied (ports 9216, overlay 9100)"
}

# apply_ecmp_multipath <node> [strict] — turn on eBGP multipath (maximum-paths
# 2) in both unicast address-families. The fabric's declared intent is ECMP
# across each node's two uplinks (data-model §7, eight links), but bgpd's eBGP
# default is a single best path: measured live 2026-10-15, the RIB held both
# nexthops for the peer-leaf loopback while the kernel route carried only
# Ethernet0's — a multi-flow burst put 100% of the traffic on one uplink, and
# applying maximum-paths 2 immediately installed both kernel nexthops (the
# q3-mtu ECMP half's root cause). Same live vtysh write class as the EVPN
# neighbor activation, idempotent, re-run from persistence_reassert.
#
# STRICTNESS: without `strict` (Pass 1, pre-reload) the write is best-effort —
# at that point in bring-up bgpd still runs the image's FACTORY `router bgp
# 65100` instance (bgpcfgd pushes the node's own AS only after its dep gate),
# so `router bgp <plan-asn>` answers "BGP instance name and AS number mismatch
# / BGP instance is already running; AS is 65100" on every node (measured
# 2026-10-15, chain LEG 2: all four nodes hard-failed here and provision
# aborted with an otherwise-healthy fabric). Pre-reload live sessions are
# diagnostic-only by the render model above, so the race is tolerated exactly
# like the sibling live-only writes (a stderr note, no failure count): the
# enforced application happens after the reload, when bgpd runs the plan AS —
# measured in the same run: the post-reload application succeeded on all four
# nodes. persistence_reassert passes `strict`, so a post-reload rejection
# still fails the bootstrap.
apply_ecmp_multipath() {
  local n=$1 c asn out strict=${2:-} rc=0
  c=$(container_of_node "$n")
  asn=$(python3 -c "import json;p=json.load(open('$PLAN_DIR/plan.$n.json'));print(p['asn'])")
  out=$(node_run "$c" "$(node_sudo "$c") vtysh -c 'configure terminal' -c 'router bgp $asn' -c 'address-family ipv4 unicast' -c 'maximum-paths 2' -c 'address-family ipv6 unicast' -c 'maximum-paths 2' -c 'end'" 2>&1) || rc=$?
  if printf '%s' "$out" | grep -qi 'mismatch\|already running'; then
    if [[ -z "$strict" ]]; then
      echo "WARNING: $n maximum-paths deferred to the post-reload re-assert (pre-reload factory-AS race in live bgpd): $(printf '%s' "$out" | tr '\n' ' ' | head -c 140)" >&2
      return 0
    fi
    note_fail "$n maximum-paths factory-AS race (strict): $(printf '%s' "$out" | head -c 120)"
    return 1
  fi
  if [[ "$rc" -ne 0 ]]; then
    note_fail "$n maximum-paths vtysh: $out"; return 1
  fi
  if printf '%s' "$out" | grep -qi 'unknown\|error'; then
    note_fail "$n maximum-paths rejected: $(printf '%s' "$out" | head -c 120)"
    return 1
  fi
  echo "$n: maximum-paths 2 (v4+v6 unicast)"
}

# apply_multipath_hash_policy <node> — assert the kernel multipath hash
# policy (L4) on both families (leaves; spines carry no VTEP). Measured live
# 2026-10-16 on leaf01: the kernel-vxlan encap route lookup builds its flow
# with NO L4 fields, so even with maximum-paths 2 installed AND
# net.ipv4.fib_multipath_hash_policy=1, every encapped flow hashed into the
# SAME multipath bucket — a 1,280,000-byte burst egressed 100% through
# Ethernet0 (tcpdump: every outer frame carried spine01's dst MAC
# 22:a0:97:78:b0:f6 while `ip route get 10.0.0.22 sport X dport 4789`
# alternated per sport; the kernel never consults L4 for the
# locally-generated tunnel flow). Policy 1 is still asserted: it hashes
# forwarded transit and locally-generated non-tunnel flows per-flow and is
# the §8.8 baseline prerequisite. NO port- or mark-keyed flow split is
# installed to paper over the encap limitation (owner amendment 2026-10-16
# forbids it): the ECMP floor in tests/integration/mtu_ecmp.sh is expected
# to fail honestly until the limitation is fixed at the source, with the
# failure recorded live and its cause cited.
apply_multipath_hash_policy() {
  local n=$1 c out rc=0
  [[ "$(role_of "$n")" == leaf ]] || return 0
  c=$(container_of_node "$n")
  out=$(node_run "$c" "$(node_sudo "$c") sh -c 'echo 1 > /proc/sys/net/ipv4/fib_multipath_hash_policy; echo 1 > /proc/sys/net/ipv6/fib_multipath_hash_policy; cat /proc/sys/net/ipv4/fib_multipath_hash_policy'" 2>&1) || rc=$?
  [[ "$rc" -eq 0 && "$out" == *"1"* ]] || { note_fail "$n fib_multipath_hash_policy=1: $out"; return 1; }
  echo "$n: fib_multipath_hash_policy=1 (v4+v6; vxlan encap lookup stays L4-less — ECMP deferral documented, no flow split installed)"
}

svi4_of_node() {
  case "$1" in
    leaf01) echo 192.168.201.1 ;;
    leaf02) echo 192.168.202.1 ;;
    *) echo "" ;;
  esac
}
# The peer leaf's VTEP IP (its Loopback0) — the destination of this leaf's
# VXLAN flood entries for the bridged VLAN.
peer_vtep_of_node() {
  case "$1" in
    leaf01) python3 -c "import json;p=json.load(open('$PLAN_DIR/plan.leaf02.json'));print(p['lo4'].split('/')[0])" ;;
    leaf02) python3 -c "import json;p=json.load(open('$PLAN_DIR/plan.leaf01.json'));print(p['lo4'].split('/')[0])" ;;
    *) echo "" ;;
  esac
}

# The EVPN address-family carries routes only for neighbors ACTIVATED under
# it. The vs bootstrap gets these lines for free — bgpcfgd renders the whole
# bgpd.conf, including the l2vpn evpn neighbor activation, at boot from
# CONFIG_DB — but the vm write-class builds FRR state live via vtysh, so the
# activation has to be issued explicitly. Without it every leaf table holds
# only its own routes: the IMETs never cross, `show evpn vni` reports 0
# remote VTEPs and nothing forwards (observed live 2026-10-14,
# vm-overlay-port-validate2: adoption passed while the overlay stayed dead).
# The spines must activate too — they relay between the leaves (eBGP, AS
# 65000; no route-reflector-client needed for eBGP). Live-only state, so it
# is re-asserted in Pass 1 and after every config reload. Every BGP_NEIGHBOR
# row (IPv4 and IPv6 loopback/session addresses) is activated.
apply_evpn_neighbor_activation() {
  local n=$1 c asn nbr out
  c=$(container_of_node "$n")
  asn=$(python3 -c "import json;p=json.load(open('$PLAN_DIR/plan.$n.json'));print(p['asn'])")
  node_run "$c" "vtysh -c 'conf t' -c 'router bgp $asn' -c 'address-family l2vpn evpn' -c 'end'" >/dev/null 2>&1 || true
  while read -r nbr; do
    [[ -n "$nbr" ]] || continue
    out=$(node_run "$c" "vtysh -c 'conf t' -c 'router bgp $asn' -c 'address-family l2vpn evpn' -c 'neighbor $nbr activate' -c 'end'" 2>&1) || true
    [[ -n "$out" ]] && echo "$n: neighbor $nbr activate: $out" >&2
  done < <(node_run "$c" "sudo redis-cli -n 4 --raw keys 'BGP_NEIGHBOR|*'" 2>/dev/null | sed 's/^BGP_NEIGHBOR|//' | grep -E '^[0-9a-fA-F:.]+$')
}

apply_overlay_baseline() {
  local n=$1 c lo4 svi4 have peer_vtep
  [[ "$(role_of "$n")" == leaf ]] || { echo "$n: not a leaf — overlay baseline not required"; return 0; }
  c=$(container_of_node "$n")
  lo4=$(python3 -c "import json;p=json.load(open('$PLAN_DIR/plan.$n.json'));print(p['lo4'].split('/')[0])")
  svi4=$(svi4_of_node "$n")
  peer_vtep=$(peer_vtep_of_node "$n")
  echo "===== $n: EVPN overlay baseline ($VLAN/L2VNI $L2VNI, $TENANT_VRF/L3VNI $L3VNI) ====="
  # 1) CONFIG_DB rows. Idempotent hsets; the VXLAN_TUNNEL source is Loopback0
  #    exactly as the vs bootstrap and the vm plans derive it. The VLAN_MEMBER
  #    row is the one the SAI dataplane reads: without it the kernel bridge
  #    rows exist and MACs even learn on the access port, but the virtual
  #    switch never floods between the port and the VNI — the client ping
  #    stays 100% loss with green-looking kernel state (observed live
  #    2026-10-14: adding this row alone took the ping from 100% loss to 0).
  node_run "$c" "sudo redis-cli -n 4 HSET 'VXLAN_TUNNEL|$VTEP' src_ip '$lo4'; sudo redis-cli -n 4 HSET 'EVPN_NVO|nvo1' source_vtep '$VTEP'; sudo redis-cli -n 4 HSET 'VLAN|$VLAN' vlanid '${VLAN#Vlan}'; sudo redis-cli -n 4 HSET 'VLAN_MEMBER|$VLAN|${ACCESS_PORT}' tagging_mode untagged; sudo redis-cli -n 4 HSET 'VLAN|$L3VLAN' vlanid '${L3VLAN#Vlan}'; sudo redis-cli -n 4 HSET 'VRF|$TENANT_VRF' vni '$L3VNI'" >/dev/null 2>&1 || true
  # 2) FRR live re-asserts: announce the VNIs, originate VrfBlue connecteds
  #    as Type-5, bind the L3 VNI to the VRF (integrated vtysh commands — NOT
  #    bgpd.conf lines; bgpcfgd owns that file). advertise-all-vni BEFORE any
  #    per-VRF work (this FRR build rejects the reverse order, p4-macvrf-trial),
  #    and no bgp ebgp-requires-policy in the VRF block (the plan's proven
  #    form: without it eBGP policy filtering can drop the Type-5s).
  local asn
  asn=$(python3 -c "import json;p=json.load(open('$PLAN_DIR/plan.$n.json'));print(p['asn'])")
  node_run "$c" "vtysh -c 'conf t' -c 'router bgp $asn' -c 'address-family l2vpn evpn' -c 'advertise-all-vni' -c 'end'" >/dev/null 2>&1 || true
  # Symmetric route-target on the L2 VNI: with advertise-all-vni this build
  # derives the VNI's RT as <local-as>:<vni>, which DIFFERS between the leaves
  # (65101:100 vs 65102:100), so each leaf drops the peer's IMET/Type-2 —
  # observed live: MACs and remote VTEPs stayed at 0 until a symmetric RT was
  # set, then both imported within seconds. Pin the whole EVPN domain to
  # <spine-as>:<vni>. (The VrfBlue Type-5 RT keeps its per-node derivation:
  # the suite asserts Type-5 presence in each leaf's own RIB, which the local
  # VRF origination satisfies, and the service plans pin their own RTs.)
  node_run "$c" "vtysh -c 'conf t' -c 'router bgp $asn' -c 'address-family l2vpn evpn' -c 'vni $L2VNI' -c 'route-target both ${SPINE_ASN}:$L2VNI' -c 'exit-vni' -c 'end'" >/dev/null 2>&1 || true
  node_run "$c" "vtysh -c 'conf t' -c 'vrf $TENANT_VRF' -c 'vni $L3VNI' -c 'exit-vrf' -c 'router bgp $asn vrf $TENANT_VRF' -c 'no bgp ebgp-requires-policy' -c 'address-family ipv4 unicast' -c 'redistribute connected' -c 'exit-address-family' -c 'address-family l2vpn evpn' -c 'advertise ipv4 unicast' -c 'end'" >/dev/null 2>&1 || true
  # 3) Kernel plumbing, the plan's proven sequence. The vtep devices are
  #    named vtep1-<VID> (vni 1000 lands as vtep1-2000 — naming after the
  #    VNI is a silent no-op): vxlanmgrd builds each from its tunnel-map row
  #    ONCE, so a still-missing device is healed by bouncing that row (del,
  #    sleep, re-hset) — the map-bounce the plans use, not a daemon restart.
  for row in "${L2VNI} $VLAN vtep1-${VLAN#Vlan}" "${L3VNI} $L3VLAN vtep1-${L3VLAN#Vlan}"; do
    local vni vlan dev have i
    read -r vni vlan dev <<<"$row"
    have=0
    for i in $(seq 1 30); do
      [[ "$(guest_count "$c" "ip link show $dev | grep -c .")" -ge 1 ]] && { have=1; break; }
      sleep 1
    done
    if [[ "$have" -ne 1 ]]; then
      echo "$n: $dev not built — bouncing tunnel-map row (vxlanmgrd creates only on a new row)"
      node_run "$c" "sudo redis-cli -n 4 DEL 'VXLAN_TUNNEL_MAP|$VTEP|map_${vni}_$vlan'; sleep 3; sudo redis-cli -n 4 HSET 'VXLAN_TUNNEL_MAP|$VTEP|map_${vni}_$vlan' vni '$vni' vlan '$vlan'" >/dev/null 2>&1 || true
      for i in $(seq 1 30); do
        [[ "$(guest_count "$c" "ip link show $dev | grep -c .")" -ge 1 ]] && { have=1; break; }
        sleep 1
      done
    fi
    [[ "$have" -eq 1 ]] || note_fail "$n $dev never built from its tunnel-map row"
  done
  # VXLAN flood entries toward the peer leaf, keyed to the bridged VLAN. On
  # this build zebra learns the remote VTEP ("show evpn vni": flood: HER) but
  # nothing programs the kernel FDB, so without these entries broadcast/ARP
  # never leaves the bridge — the client ping stays 100% loss with fully
  # green EVPN state (observed live 2026-10-14). vlan_tunnel stays off (the
  # kernel rejects tunnel_info on this build); the vlan-keyed fdb row is the
  # model the live trial forwarded with. Idempotent via replace.
  node_run "$c" "sudo bash -c '
    ip link show vtep1-${VLAN#Vlan} >/dev/null 2>&1 && bridge fdb replace 00:00:00:00:00:00 dev vtep1-${VLAN#Vlan} dst ${peer_vtep} vlan ${VLAN#Vlan} 2>/dev/null
    ip link show vtep1-${L3VLAN#Vlan} >/dev/null 2>&1 && bridge fdb replace 00:00:00:00:00:00 dev vtep1-${L3VLAN#Vlan} dst ${peer_vtep} vlan ${L3VLAN#Vlan} 2>/dev/null
    true
  '" >/dev/null 2>&1 || true
  # Bridge both vteps and the access port; SVI on the L3 vlan bound to the
  # tenant VRF. Vlan devices are waited for first: vlanmgrd builds Vlan<n>
  # from the CONFIG_DB row and only creates it itself if it never appears —
  # creating it first makes vlanmgrd's own attempt fail without a retry
  # (plan.go sviShell, observed live). Same for the VRF master: vrfmgrd
  # builds the VRF device asynchronously, so waitMaster-style retries.
  node_run "$c" "sudo bash -c '
    ip link show Bridge >/dev/null 2>&1 || { ip link add Bridge type bridge; ip link set Bridge up; }
    for d in vtep1-${VLAN#Vlan} vtep1-${L3VLAN#Vlan}; do
      ip link show \$d >/dev/null 2>&1 || continue
      ip -d link show \$d 2>/dev/null | grep -q \"master Bridge\" || ip link set \$d master Bridge 2>/dev/null || true
      bridge vlan show dev \$d 2>/dev/null | grep -qE \"(^| )1( |\\\$)\" && bridge vlan del dev \$d vid 1 2>/dev/null
      true
    done
    bridge vlan show dev vtep1-${VLAN#Vlan} 2>/dev/null | grep -qw ${VLAN#Vlan} || bridge vlan add dev vtep1-${VLAN#Vlan} vid ${VLAN#Vlan} pvid untagged 2>/dev/null || true
    bridge vlan show dev vtep1-${L3VLAN#Vlan} 2>/dev/null | grep -qw ${L3VLAN#Vlan} || bridge vlan add dev vtep1-${L3VLAN#Vlan} vid ${L3VLAN#Vlan} pvid untagged 2>/dev/null || true
    for d in vtep1-${VLAN#Vlan} vtep1-${L3VLAN#Vlan}; do ip link show \$d >/dev/null 2>&1 && { ip link show \$d | grep -q \"state UP\\|state UNKNOWN\" || ip link set \$d up; }; done
    ip link set ${ACCESS_PORT} up 2>/dev/null || true
    ip link show ${ACCESS_PORT} | grep -q \"master Bridge\" || { ip link set ${ACCESS_PORT} nomaster 2>/dev/null || true; ip link set ${ACCESS_PORT} master Bridge 2>/dev/null || true; }
    bridge vlan show dev ${ACCESS_PORT} 2>/dev/null | grep -qE \"(^| )1( |\\\$)\" && bridge vlan del dev ${ACCESS_PORT} vid 1 2>/dev/null
    # Unconditional del+add (not a conditional add): vlanmgrd's late post-reload
    # apply can leave the access port a plain tagged member WITHOUT the PVID
    # flags (observed live 2026-10-14 on leaf02 — client frames then classify
    # to the deleted vid 1 and the L2 data plane dies with green-looking EVPN
    # state and a correct-looking '100' row).
    bridge vlan del dev ${ACCESS_PORT} vid ${VLAN#Vlan} 2>/dev/null || true
    bridge vlan add dev ${ACCESS_PORT} vid ${VLAN#Vlan} pvid untagged 2>/dev/null || true
    for i in \$(seq 1 15); do ip link show ${L3VLAN} >/dev/null 2>&1 && break; sleep 1; done
    ip link show ${L3VLAN} >/dev/null 2>&1 || ip link add ${L3VLAN} link Bridge type vlan id ${L3VLAN#Vlan} 2>/dev/null || true
    for i in \$(seq 1 30); do ip link set ${L3VLAN} master ${TENANT_VRF} 2>/dev/null && break; sleep 1; done
    ip link set ${L3VLAN} up 2>/dev/null || true
    bridge vlan add dev Bridge vid ${L3VLAN#Vlan} self 2>/dev/null || true
    ip -br addr show ${L3VLAN} 2>/dev/null | grep -qF \"${svi4}/24\" || ip addr add ${svi4}/24 dev ${L3VLAN} 2>/dev/null || true
    echo KERNEL-OVERLAY-DONE
  '" >/dev/null 2>&1 || true
  echo "$n kernel: vtep1-100=$(guest_count "$c" "ip link show vtep1-100 | grep -c .") vtep1-2000=$(guest_count "$c" "ip link show vtep1-2000 | grep -c .") ${L3VLAN}=$(guest_count "$c" "ip -br addr show ${L3VLAN} | grep -cF '${svi4}/24'") ${TENANT_VRF}=$(guest_count "$c" "ip link show ${TENANT_VRF} | grep -c .") flood=$(guest_count "$c" "sudo bridge fdb show dev vtep1-${VLAN#Vlan} | grep -c 'dst ${peer_vtep}'")"
  [[ "$(guest_count "$c" "ip -br addr show ${L3VLAN} | grep -cF '${svi4}/24'")" -ge 1 ]] || echo "$n WARNING: ${L3VLAN} SVI absent at the early read-back — reload race; the post-adoption re-assert re-claims device+VRF+address and gates on it"
  [[ "$(guest_count "$c" "ip link show ${TENANT_VRF} | grep -c .")" -ge 1 ]] || note_fail "$n ${TENANT_VRF} kernel device missing"
  # WARNING only (the post-adoption re-assert re-adds these and gates hard):
  # on a cold boot the kernel Bridge itself is still being created by vlanmgrd
  # when this block runs, so `bridge fdb replace` can no-op here even though
  # the same command succeeds minutes later (dry run 2: both leaves FAILed
  # early, healed late, ping 0%).
  [[ "$(guest_count "$c" "sudo bridge fdb show dev vtep1-${VLAN#Vlan} | grep -c 'dst ${peer_vtep}'")" -ge 1 ]] || echo "$n WARNING: no VXLAN flood entry toward peer ${peer_vtep} yet (cold-boot Bridge race) — the post-adoption re-assert re-adds and gates on it"
}

# Post-reload adoption gate (Pass 4, after wait_sessions): bgpd must have
# adopted BOTH VNIs — `show bgp l2vpn evpn vni` lists L2 100 and L3 1000 in
# VrfBlue ("Tenant VRF" marker). Heal order is the plan's proven sequence:
# re-bind the L3 VNI (zebra can know a VNI while bgpd does not — re-issuing
# `vrf X / vni N` fixes it), then the advertise-all-vni toggle.
verify_overlay_adoption() {
  local n=$1 c asn attempt l2 l3 peer_vtep svi4
  [[ "$(role_of "$n")" == leaf ]] || return 0
  c=$(container_of_node "$n")
  asn=$(python3 -c "import json;p=json.load(open('$PLAN_DIR/plan.$n.json'));print(p['asn'])")
  peer_vtep=$(peer_vtep_of_node "$n")
  svi4=$(svi4_of_node "$n")
  l2=0; l3=0
  for attempt in 1 2 3; do
    l2=$(guest_count "$c" "vtysh -d bgpd -c 'show bgp l2vpn evpn vni' | grep -cE '^[[:space:]]*\*?[[:space:]]*${L2VNI}[[:space:]]+L2'")
    l3=$(guest_count "$c" "vtysh -d bgpd -c 'show bgp l2vpn evpn vni $L3VNI' | grep -cF 'Tenant VRF: $TENANT_VRF'")
    [[ "$l2" -ge 1 && "$l3" -ge 1 ]] && break
    echo "$n: VNI adoption incomplete (L2=$l2 L3=$l3, attempt $attempt)"
    if [[ "$l3" -lt 1 ]]; then
      node_run "$c" "vtysh -c 'conf t' -c 'vrf $TENANT_VRF' -c 'no vni $L3VNI' -c 'end'" >/dev/null 2>&1 || true
      sleep 2
      node_run "$c" "vtysh -c 'conf t' -c 'vrf $TENANT_VRF' -c 'vni $L3VNI' -c 'end'" >/dev/null 2>&1 || true
      sleep 3
    fi
    node_run "$c" "vtysh -c 'conf t' -c 'router bgp $asn' -c 'address-family l2vpn evpn' -c 'no advertise-all-vni' -c 'end'" >/dev/null 2>&1 || true
    sleep 2
    node_run "$c" "vtysh -c 'conf t' -c 'router bgp $asn' -c 'address-family l2vpn evpn' -c 'advertise-all-vni' -c 'end'" >/dev/null 2>&1 || true
    sleep 8
  done
  echo "$n adoption: L2=$l2 L3=$l3 (vni $L2VNI + $L3VNI/$TENANT_VRF)"
  [[ "$l2" -ge 1 ]] || note_fail "$n bgpd never adopted L2 VNI $L2VNI — overlay cannot forward"
  [[ "$l3" -ge 1 ]] || note_fail "$n bgpd never adopted L3 VNI $L3VNI into $TENANT_VRF — no Type-5"
  # Peer-arrival gate — the one signal that cannot come from self-origination
  # (fabric_verify's bar): the remote VTEP count on the L2 VNI reaches 1 only
  # once the peer leaf's IMET has been received AND installed by zebra. Bounded
  # wait: both leaves re-assert their EVPN neighbor activation in Pass 3 before
  # this Pass 4 gate, so the IMETs need seconds, not the full suite budget.
  local rv i
  rv=0
  for i in $(seq 1 6); do
    rv=$(guest_count "$c" "vtysh -d zebra -c 'show evpn vni' | grep -E '^${L2VNI}[[:space:]]' | head -1 | awk '{print \$6}'")
    [[ "$rv" =~ ^[0-9]+$ && "$rv" -ge 1 ]] && break
    sleep 5
  done
  echo "$n remote VTEPs on VNI $L2VNI: ${rv:-0}"
  [[ "${rv:-0}" -ge 1 ]] || note_fail "$n: 0 remote VTEPs on L2 VNI $L2VNI — peer IMET never arrived (EVPN AF neighbor activation)"
  # LATE kernel re-assert, strictly after the daemons have settled (this is the
  # last leaf work of the run): vlanmgrd's post-reload apply races this script's
  # in-flight kernel block and can strip the access port's PVID flags after
  # persistence_reassert ran (leaf02, observed live 2026-10-14 — ping 100% loss
  # until the flags were restored late). Force the flags with del+add, refresh
  # the VXLAN flood entries (kernel state, wiped by the reload), and gate on
  # both — the data plane is the deliverable, not just green EVPN state.
  node_run "$c" "sudo bash -c '
    bridge vlan del dev ${ACCESS_PORT} vid ${VLAN#Vlan} 2>/dev/null
    bridge vlan add dev ${ACCESS_PORT} vid ${VLAN#Vlan} pvid untagged 2>/dev/null
    ip link show vtep1-${VLAN#Vlan} >/dev/null 2>&1 && bridge fdb replace 00:00:00:00:00:00 dev vtep1-${VLAN#Vlan} dst ${peer_vtep} vlan ${VLAN#Vlan} 2>/dev/null
    ip link show vtep1-${L3VLAN#Vlan} >/dev/null 2>&1 && bridge fdb replace 00:00:00:00:00:00 dev vtep1-${L3VLAN#Vlan} dst ${peer_vtep} vlan ${L3VLAN#Vlan} 2>/dev/null
    # The reload race can also eat the SVI: vlanmgrd recreates Bridge mid-boot,
    # so the early kernel block may have found no parent to hang ${L3VLAN} on
    # (validate5: device 0 at read-back while EVPN stayed green). Re-assert
    # device + VRF binding + address with bounded waits, same recipe.
    for i in \$(seq 1 10); do ip link show ${L3VLAN} >/dev/null 2>&1 && break; sleep 1; done
    ip link show ${L3VLAN} >/dev/null 2>&1 || ip link add ${L3VLAN} link Bridge type vlan id ${L3VLAN#Vlan} 2>/dev/null
    for i in \$(seq 1 15); do ip link set ${L3VLAN} master ${TENANT_VRF} 2>/dev/null && break; sleep 1; done
    ip link set ${L3VLAN} up
    bridge vlan add dev Bridge vid ${L3VLAN#Vlan} self 2>/dev/null
    ip -br addr show ${L3VLAN} | grep -qF \"${svi4}/24\" || ip addr add ${svi4}/24 dev ${L3VLAN}
    true
  '" >/dev/null 2>&1 || true
  [[ "$(guest_count "$c" "sudo bridge vlan show dev ${ACCESS_PORT} | grep -c 'PVID Egress Untagged'")" -ge 1 ]] || note_fail "$n ${ACCESS_PORT} lost its ${VLAN} PVID/untagged flags after the reload (vlanmgrd race)"
  [[ "$(guest_count "$c" "sudo bridge fdb show dev vtep1-${VLAN#Vlan} | grep -c 'dst ${peer_vtep}'")" -ge 1 ]] || note_fail "$n VXLAN flood entry toward ${peer_vtep} missing after the reload"
  [[ "$(guest_count "$c" "ip -br addr show ${L3VLAN} | grep -cF '${svi4}/24'")" -ge 1 ]] || note_fail "$n ${L3VLAN} SVI ${svi4}/24 missing after the reload (Bridge-recreation race)"
}

# ---------------------------------------------------------------------------
# Plan: fabric.yaml -> per-node JSON on the host (single source, no jq needed)
# ---------------------------------------------------------------------------
PLAN_DIR="$(mktemp -d /tmp/.cf-plan.XXXXXX)"
python3 - "$FABRIC_YAML" "$PLAN_DIR" <<'PY'
import json, sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
out = sys.argv[2]
nodes = d["nodes"]
lo = {n: (v["loopback4"].split("/")[0], v["loopback6"].split("/")[0])
      for n, v in nodes.items()}
for n, v in nodes.items():
    asn = str(v["asn"])
    links, nbrs, pins = [], [], []
    for l in v["links"]:
        peer = nodes[l["peer"]]
        links.append({"if": l["port"], "v4": l["v4"], "loc4": l["v4"].split("/")[0],
                      "peer4": l["peer_v4"].split("/")[0],
                      "v6": l["v6"], "loc6": l["v6"].split("/")[0],
                      "peer6": l["peer_v6"].split("/")[0],
                      "asn": int(peer["asn"]), "bgponly": False,
                      "peer": l["peer"]})
        nbrs.append({"peer4": l["peer_v4"].split("/")[0], "peer6": l["peer_v6"].split("/")[0],
                     "asn": str(peer["asn"]), "loc4": l["v4"].split("/")[0],
                     "loc6": l["v6"].split("/")[0]})
        # Loop-free locator pins (spike-locator-reach / vpn-setup classes): the
        # owner of a pinned prefix delivers locally, so every pinned path makes
        # forward progress; the symmetric-flow self-loop came from ECMP over
        # both spine legs, which a per-link pin removes.
        pins.append({"prefix": peer["locator"], "via": l["peer_v6"].split("/")[0],
                     "dev": l["port"]})
    # Spine-to-spine iBGP over the loopbacks: the spines share AS 65000 and are
    # not linked; without this the second spine's loopback arrives from a leaf
    # as "<leaf-as> 65000" and is dropped as an AS loop (underlay-apply class).
    if v["role"] == "spine":
        other = [m for m, w in nodes.items() if w["role"] == "spine" and m != n][0]
        nbrs.append({"peer4": lo[other][0], "peer6": lo[other][1], "asn": asn,
                     "loc4": v["loopback4"].split("/")[0], "loc6": v["loopback6"].split("/")[0],
                     "bgponly": True})
    # The peer leaf's /48 rides ONE spine leg on a leaf (vpn-setup pin_peer_48
    # class: the first spine-facing link) — with plain ECMP the symmetric flow
    # hash can pick the arrival leg and self-loop the packet spine02 -> leaf02
    # -> spine02 (spike-locator-reach).
    if v["role"] == "leaf":
        other = [m for m, w in nodes.items() if w["role"] == "leaf" and m != n][0]
        first = v["links"][0]
        pins.append({"prefix": nodes[other]["locator"],
                     "via": first["peer_v6"].split("/")[0], "dev": first["port"]})
        # Spike locator-reach loop-free pinning: a leaf holds BOTH spine legs
        # for a spine locator (eBGP ECMP) and the symmetric flow hash can pick
        # the arrival leg (spine02 -> leaf02 -> spine02 self-loop, ping dies in
        # time-exceeded). Pinning each spine locator on its OWNER spine's leg
        # makes every transit take a forward hop (the owner delivers locally).
        for l in v["links"]:
            if nodes[l["peer"]]["role"] == "spine":
                pins.append({"prefix": nodes[l["peer"]]["locator"],
                             "via": l["peer_v6"].split("/")[0], "dev": l["port"]})
        # The ::1 endpoints need their own pins: each spine originates its
        # locator /48 AND its ::1/128, the iBGP->eBGP export makes the /128
        # ECMP over both spine legs on a leaf exactly like the /48, and the
        # ASIC longest-prefix match resolves a ping to <dst-locator>::1
        # against the /128, not the pinned /48 (measured 2026-10-14: with the
        # /48 pinned, ROUTE_TABLE:fcbb:bbbb:2::1 still held nexthops={both
        # spines} and the spine->spine pairs stayed 10/12 until the ::1 rows
        # were pinned the same way). Same class, same legs, prefix+1.
        for l in v["links"]:
            if nodes[l["peer"]]["role"] == "spine":
                pins.append({"prefix": nodes[l["peer"]]["locator"][:-3] + "1/128",
                             "via": l["peer_v6"].split("/")[0], "dev": l["port"]})
        pins.append({"prefix": nodes[other]["locator"][:-3] + "1/128",
                     "via": first["peer_v6"].split("/")[0], "dev": first["port"]})
    plan = {"node": n, "role": v["role"], "asn": asn,
            "lo4": v["loopback4"], "lo6": v["loopback6"],
            "router_id": v["router_id"], "locator": v["locator"],
            "links": links, "nbrs": nbrs, "pins": pins,
            "expected_sessions": d["expected_sessions"][v["role"]]}
    json.dump(plan, open(out + "/plan." + n + ".json", "w"))
print(json.dumps({n: nodes[n]["role"] for n in nodes}))
PY
# shellcheck disable=SC2034
NODE_ROLES=$(python3 - "$FABRIC_YAML" <<'PY'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
print(" ".join(n + "=" + v["role"] for n, v in d["nodes"].items()))
PY
)
role_of() { python3 - "$FABRIC_YAML" "$1" <<'PY'
import sys, yaml
print(yaml.safe_load(open(sys.argv[1]))["nodes"][sys.argv[2]]["role"])
PY
}

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "===== DRY-RUN plan (from $FABRIC_YAML; nothing was written) ====="
  for n in "${NODES[@]}"; do
    echo "--- $n ($(role_of "$n")) ---"
    python3 -m json.tool "$PLAN_DIR/plan.$n.json"
  done
  echo "DRY-RUN: printed ${#NODES[@]} per-node plans, wrote nothing"
  exit 0
fi

# ---------------------------------------------------------------------------
# Guest-side appliers (pushed per node; proven write classes, parameterized by
# the plan JSON)
# ---------------------------------------------------------------------------
cat > "$PLAN_DIR/underlay.py" <<'PY'
import json, sys
from generic_config_updater.generic_updater import GenericUpdater, ConfigFormat
from jsonpatch import JsonPatch

plan = json.load(open("/tmp/.cf_plan.json"))
node, asn, lo4, lo6 = plan["node"], plan["asn"], plan["lo4"], plan["lo6"]

iface, nbr = {}, {}
for p in plan["links"]:
    # INTERFACE rows carry no fields on this image: admin_status is a PORT
    # field (ports are factory admin-up) and an unknown field makes the YANG
    # loader reject the whole INTERFACE table ("All Keys are not parsed in
    # INTERFACE", measured spike-underlay-leaf01).
    iface[p["if"]] = {}
    iface[p["if"] + "|" + p["v4"]] = {}
    iface[p["if"] + "|" + p["v6"]] = {}
    nbr[p["peer4"]] = {"asn": p["asn"], "local_addr": p["loc4"],
                       "holdtime": "180", "keepalive": "60",
                       "nhopself": "0", "rrclient": "0"}
    nbr[p["peer6"]] = {"asn": p["asn"], "local_addr": p["loc6"],
                       "holdtime": "180", "keepalive": "60",
                       "nhopself": "0", "rrclient": "0"}
for p in plan["nbrs"]:
    if p.get("bgponly"):
        nbr[p["peer4"]] = {"asn": p["asn"], "local_addr": p["loc4"],
                           "holdtime": "180", "keepalive": "60",
                           "nhopself": "0", "rrclient": "0"}
        nbr[p["peer6"]] = {"asn": p["asn"], "local_addr": p["loc6"],
                           "holdtime": "180", "keepalive": "60",
                           "nhopself": "0", "rrclient": "0"}

# lo4/lo6 already carry their prefix (plan line ~149: v["loopback4"] is
# "10.0.0.21/32") - do NOT append another one: "Loopback0|10.0.0.21/32/32"
# makes bgpcfgd die in netaddr parse_ip_network and the peer render never
# happens (measured leaf01 2026-10-14). GCU also rejects the malformed key,
# which is why this chunk silently raised on every node before.
lo = {"Loopback0": {}, "Loopback0|" + lo4: {}, "Loopback0|" + lo6: {}}
# Each remove/add pair is its own JsonPatch and each failure is tolerated:
# GCU aborts a whole patch on the first failing op, and a remove of a table
# that is already absent (factory image after install-executor-key) must not
# stop the adds - measured: the adds silently never ran in that case.
ops = [
    [{"op": "remove", "path": "/INTERFACE"}],
    [{"op": "add", "path": "/INTERFACE", "value": iface}],
    [{"op": "remove", "path": "/LOOPBACK_INTERFACE"}],
    [{"op": "add", "path": "/LOOPBACK_INTERFACE", "value": lo}],
    [{"op": "remove", "path": "/BGP_NEIGHBOR"}],
    [{"op": "add", "path": "/BGP_NEIGHBOR", "value": nbr}],
    [{"op": "add", "path": "/DEVICE_METADATA/localhost/hostname", "value": node}],
    [{"op": "add", "path": "/DEVICE_METADATA/localhost/bgp_asn", "value": asn}],
    [{"op": "add", "path": "/DEVICE_METADATA/localhost/bgp_router_id", "value": plan["router_id"]}],
    # 202505's bgpd template advertises the IPv6 loopback as the /64 covering
    # it unless this knob is set (bgpd.main.conf.j2 bgp_adv_lo_prefix_as_128
    # -> network .../128); without it no /128 loopback is reachable.
    [{"op": "add", "path": "/DEVICE_METADATA/localhost/bgp_adv_lo_prefix_as_128", "value": "true"}],
]
for chunk in ops:
    try:
        GenericUpdater().apply_patch(JsonPatch(chunk), ConfigFormat.CONFIGDB, False, False, False, [])
    except Exception:
        # GCU's immediate read-after-write verification can race the managers
        # on this image; the CONFIG_DB read-back after the apply is the check.
        print("APPLY-EXCEPTION (see CONFIG_DB read-back)", file=sys.stderr)
print("APPLIED %s asn=%s lo4=%s lo6=%s ifaces=%d nbrs=%d" %
      (node, asn, lo4, lo6, len(iface), len(nbr)))
PY

cat > "$PLAN_DIR/locator_rm.py" <<'PY'
import sys
from generic_config_updater.generic_updater import GenericUpdater, ConfigFormat
from jsonpatch import JsonPatch
try:
    GenericUpdater().apply_patch(JsonPatch([{"op": "remove",
        "path": "/SRV6_MY_LOCATORS[loc-" + sys.argv[1].lower() + "]", "value": {}}]),
        ConfigFormat.CONFIGDB, False, False, False, [])
except Exception:
    pass
PY

cat > "$PLAN_DIR/locator_add.py" <<'PY'
import sys
from generic_config_updater.generic_updater import GenericUpdater, ConfigFormat
from jsonpatch import JsonPatch
node, addr = sys.argv[1], sys.argv[2]
ops = [{"op": "add", "path": "/SRV6_MY_LOCATORS", "value":
        {"loc-" + node.lower(): {"prefix": addr}}}]
try:
    GenericUpdater().apply_patch(JsonPatch(ops), ConfigFormat.CONFIGDB, False, False, False, [])
    print("APPLIED")
except Exception as e:
    print("ADD-FAILED %s" % type(e).__name__)
PY

cat > "$PLAN_DIR/underlay_direct.py" <<'PY'
import json, subprocess

# Direct redis write fallback: identical content to the GCU applier, written
# with redis-cli instead of GCU. Used only when GCU cannot even load the
# CURRENT config (factory demo tables whose YANG translation raises), which
# makes every substantive patch fail before our ops run. redis CONFIG_DB is
# the same source of truth GCU writes to - bgpcfgd/orchagent react to the
# same keyspace notifications either way.
plan = json.load(open("/tmp/.cf_plan.json"))
node, asn, lo4, lo6 = plan["node"], plan["asn"], plan["lo4"], plan["lo6"]


def cli(*args):
    argv = ["sudo", "redis-cli", "-n", "4"] + [str(a) for a in args]
    r = subprocess.run(argv, check=True, capture_output=True, text=True)
    return r.stdout


def del_table(table):
    for key in cli("--raw", "KEYS", table + "|*").splitlines():
        if key.strip():
            cli("DEL", key)


for table in ("INTERFACE", "LOOPBACK_INTERFACE", "BGP_NEIGHBOR"):
    del_table(table)

iface_keys, nbr = [], {}
for p in plan["links"]:
    iface_keys += [p["if"], p["if"] + "|" + p["v4"], p["if"] + "|" + p["v6"]]
    nbr[p["peer4"]] = {"asn": p["asn"], "local_addr": p["loc4"],
                       "holdtime": "180", "keepalive": "60",
                       "nhopself": "0", "rrclient": "0"}
    nbr[p["peer6"]] = {"asn": p["asn"], "local_addr": p["loc6"],
                       "holdtime": "180", "keepalive": "60",
                       "nhopself": "0", "rrclient": "0"}
for p in plan["nbrs"]:
    if p.get("bgponly"):
        nbr[p["peer4"]] = {"asn": p["asn"], "local_addr": p["loc4"],
                           "holdtime": "180", "keepalive": "60",
                           "nhopself": "0", "rrclient": "0"}
        nbr[p["peer6"]] = {"asn": p["asn"], "local_addr": p["loc6"],
                           "holdtime": "180", "keepalive": "60",
                           "nhopself": "0", "rrclient": "0"}

# INTERFACE rows carry no fields on this image (see the GCU applier note).
for k in iface_keys:
    cli("HSET", "INTERFACE|" + k, "NULL", "NULL")
cli("HSET", "LOOPBACK_INTERFACE|Loopback0", "NULL", "NULL")
cli("HSET", "LOOPBACK_INTERFACE|Loopback0|" + lo4, "NULL", "NULL")
cli("HSET", "LOOPBACK_INTERFACE|Loopback0|" + lo6, "NULL", "NULL")
for ip, fields in nbr.items():
    for f, v in fields.items():
        cli("HSET", "BGP_NEIGHBOR|" + ip, f, v)
cli("HSET", "DEVICE_METADATA|localhost", "hostname", node, "bgp_asn", asn,
    "bgp_router_id", plan["router_id"], "bgp_adv_lo_prefix_as_128", "true")
print("DIRECT-WRITTEN %s ifaces=%d nbrs=%d" % (node, len(iface_keys), len(nbr)))
PY

# push_file <container> <local-file> <remote-path> — the spike-env push class
# (scripts/spike/spike-env.sh:188): deterministic script push over the SSH exec
# channel, base64 through ARGV. The stdin-piped node_run_i push truncates and
# corrupts intermittently on the sonic-vm guest (measured in the spike:
# /tmp/.spike_vpn_rb2.py landed as 658 truncated bytes with a SyntaxError,
# silently, behind >/dev/null). base64 has no stdin to lose; the remote side
# writes exactly the local bytes. This definition was missing from the first
# run (attempt-2 bring-up: "push_file: command not found" -> no applier ever
# reached a guest -> no APPLIED line anywhere); without it nothing here runs.
push_file() {
  local c=$1 src=$2 dst=$3 b64
  b64=$(base64 -w0 "$src") || return 1
  node_run "$c" "echo $b64 | base64 -d > $dst" >/dev/null 2>&1
}

push_plan() { # <node> — plan JSON + appliers into the guest
  local n=$1 c cplan
  c=$(container_of_node "$n")
  cp "$PLAN_DIR/plan.$n.json" "$PLAN_DIR/.cf_plan.json"
  push_file "$c" "$PLAN_DIR/.cf_plan.json" /tmp/.cf_plan.json || true
  for f in underlay.py underlay_direct.py locator_rm.py locator_add.py; do
    push_file "$c" "$PLAN_DIR/$f" "/tmp/.cf_$f" || true
  done
}

container_of_node() { echo "clab-agentic-netops-fabric-$1"; }

# ---------------------------------------------------------------------------
# Steps (each re-assertable; order per data-model §8.8)
# ---------------------------------------------------------------------------

# identity + fabric link addressing + underlay BGP: one GCU applier run per
# node (factory clean, DEVICE_METADATA, INTERFACE, LOOPBACK_INTERFACE,
# BGP_NEIGHBOR — the underlay-apply op list verbatim).
apply_underlay() {
  local n=$1 c out want_id got_id
  c=$(container_of_node "$n")
  echo "===== $n: GCU apply (factory clean + identity + links + BGP neighbors) ====="
  # The applier tolerates per-chunk GCU exceptions (read-after-write races on
  # this image) but still prints APPLIED — so APPLIED alone proves nothing.
  # Keep stderr: APPLY-EXCEPTION lines are the per-chunk signal, and the
  # identity read-back below is the hard truth (measured: leaf01 printed
  # APPLIED while every chunk had raised and the node stayed factory).
  out=$(node_run "$c" "sudo python3 /tmp/.cf_underlay.py" 2>&1 || true)
  echo "${out%%$'\n'*}"
  grep -q '^APPLIED' <<<"$out" || note_fail "$n underlay applier produced no APPLIED line"
  # Per-chunk exceptions on this image are usually the known read-after-write
  # race (the write lands; GCU's immediate verify loses): the CONFIG_DB
  # identity read-back below is the authoritative gate, so exceptions only
  # WARN here - shown in full for the log.
  nex=$(grep -c 'APPLY-EXCEPTION' <<<"$out" || true)
  if [[ "${nex:-0}" -gt 0 ]]; then
    echo "$n: $nex GCU chunk(s) raised (verify-race known benign; identity read-back decides)"
    grep 'APPLY-EXCEPTION' <<<"$out" | sed 's/^/  /' || true
  fi
  want_id=$(printf '%s,%s' "$n" "$(python3 -c "import json;print(json.load(open('$PLAN_DIR/plan.$n.json'))['asn'])")")
  got_id=$(node_run "$c" "sudo redis-cli -n 4 --raw HMGET 'DEVICE_METADATA|localhost' hostname bgp_asn" 2>/dev/null | paste -sd, -)
  if [[ "$got_id" != "$want_id" ]]; then
    echo "$n: GCU path did not land identity (got '$got_id') -> direct redis write fallback"
    node_run "$c" "sudo python3 /tmp/.cf_underlay_direct.py" || note_fail "$n direct redis write failed"
    got_id=$(node_run "$c" "sudo redis-cli -n 4 --raw HMGET 'DEVICE_METADATA|localhost' hostname bgp_asn" 2>/dev/null | paste -sd, -)
    if [[ "$got_id" != "$want_id" ]]; then
      note_fail "$n underlay identity read-back '$got_id' != '$want_id' (patch did not land)"
    fi
  fi
  echo "--- $n CONFIG_DB read-back ---"
  node_run "$c" "echo 'DEVICE_METADATA:'; sudo redis-cli -n 4 --raw HMGET 'DEVICE_METADATA|localhost' hostname bgp_asn bgp_router_id bgp_adv_lo_prefix_as_128; echo 'INTERFACE rows:'; sudo redis-cli -n 4 --raw KEYS 'INTERFACE|*' | sort; echo 'BGP_NEIGHBOR rows:'; sudo redis-cli -n 4 --raw KEYS 'BGP_NEIGHBOR|*' | sort" || true
  # Kernel IPv6 forwarding (underlay-apply class: sonic-vs measured 0 at boot).
  node_run "$c" "sudo sh -c 'echo 1 > /proc/sys/net/ipv6/conf/all/forwarding; echo 1 > /proc/sys/net/ipv4/conf/all/forwarding'; printf 'fwd46='; cat /proc/sys/net/ipv6/conf/all/forwarding /proc/sys/net/ipv4/conf/all/forwarding | paste -sd, -" || true
}

# bgpcfgd re-render: restart the bgp UNIT (systemd) only when the rendered
# config still advertises the /64 loopback — after the restart bgpcfgd renders
# the knob's /128 form. Bounded budget: the restart is refused after 2 in
# 20 min (StartLimitBurst protection), which a re-run simply skips because the
# check goes quiet once bgpd.conf carries the /128 form.
bgpcfgd_render_check() {
  local n=$1 c stale
  c=$(container_of_node "$n")
  stale=$(guest_count "$c" "sudo docker exec bgp grep -c 'network 2001:db8:ff::/64' /etc/frr/bgpd.conf")
  if [[ "$stale" == "0" ]]; then
    echo "$n: bgpd.conf already renders the /128 loopback form (no restart needed)"
    return 0
  fi
  echo "$n: bgpd.conf still carries the /64 advertisement -> bgp unit restart (bgpcfgd re-render)"
  node_run "$c" "sudo systemctl reset-failed bgp 2>/dev/null; sudo systemctl restart bgp" >/dev/null 2>&1 || true
  # A unit restart does not replay redis into bgpcfgd — nudge the dep gate.
  bgpcfgd_nudge "$n"
  local i
  for i in $(seq 1 24); do
    local have
    have=$(guest_count "$c" "vtysh -c 'show running-config' | grep -c 'neighbor .* remote-as'")
    [[ "$have" -ge 1 ]] 2>/dev/null && break
    sleep 5
  done
  sleep 10
  stale=$(guest_count "$c" "sudo docker exec bgp grep -c 'network 2001:db8:ff::/64' /etc/frr/bgpd.conf")
  if [[ "$stale" != "0" ]]; then
    note_fail "$n bgpd.conf still advertises the /64 loopback after the bgp unit restart"
  else
    echo "$n: bgpd.conf now renders the /128 form"
  fi
}

# spine iBGP fixups: update-source from the loopbacks (the rendered iBGP
# neighbor lacks it and the session then cycles Connect/Active) and allowas-in
# on the leaf-facing neighbors (the other spine's loopback transits a leaf as
# "<leaf-as> 65000"). Live-only on this image; re-asserted every run.
spine_fixups() {
  local n=$1 c asn lo4 lo6 other
  c=$(container_of_node "$n"); asn=$(python3 -c "import json;p=json.load(open('$PLAN_DIR/plan.$n.json'));print(p['asn'])")
  lo4=$(python3 -c "import json;p=json.load(open('$PLAN_DIR/plan.$n.json'));print(p['lo4'].split('/')[0])")
  lo6=$(python3 -c "import json;p=json.load(open('$PLAN_DIR/plan.$n.json'));print(p['lo6'].split('/')[0])")
  [[ "$(role_of "$n")" == spine ]] || return 0
  echo "===== $n: vtysh iBGP update-source + allowas-in (live, re-asserted) ====="
  # allowas-in 1 on every leaf-facing neighbor, both families (underlay-apply
  # class): the other spine's loopback transits a leaf as "<leaf-as> 65000".
  local args="" p
  while read -r p; do args+=" -c 'neighbor $p allowas-in 1'"; done \
    < <(python3 -c "import json;p=json.load(open('$PLAN_DIR/plan.$n.json'));ls=p['links'];print('\n'.join([l['peer4'] for l in ls]+[l['peer6'] for l in ls]))")
  node_run "$c" "vtysh -c 'conf t' -c 'router bgp $asn' -c 'address-family ipv4 unicast' $args -c 'address-family ipv6 unicast' $args -c 'end'" >/dev/null 2>&1 || true
  # update-source from the loopbacks for the iBGP peer (peer = the other
  # spine's loopbacks; the rendered neighbor lacks it and the session then
  # cycles Connect/Active forever — measured).
  local o4 o6
  o4=$(python3 -c "import json;p=json.load(open('$PLAN_DIR/plan.$n.json'));print([x['peer4'] for x in p['nbrs'] if x.get('bgponly')][0])")
  o6=$(python3 -c "import json;p=json.load(open('$PLAN_DIR/plan.$n.json'));print([x['peer6'] for x in p['nbrs'] if x.get('bgponly')][0])")
  node_run "$c" "vtysh -c 'conf t' -c 'router bgp $asn' -c 'neighbor $o4 update-source $lo4' -c 'neighbor $o6 update-source $lo6' -c 'end'" >/dev/null 2>&1 || true
  echo "$n: allowas-in rows: $(guest_count "$c" "vtysh -c 'show running-config' | grep -c 'allowas-in'")"
}

# kernel prerequisites — LEAVES ONLY (spines never terminate the service,
# data-model §8.8): seg6_enabled on all/default/Ethernet0/Ethernet4/Loopback0,
# vrf module loaded, net.vrf.strict_mode=1 (all through /proc; no sysctl
# binary on this image).
kernel_prereqs() {
  local n=$1 c
  [[ "$(role_of "$n")" == leaf ]] || { echo "$n: not a leaf — kernel service prerequisites not required"; return 0; }
  c=$(container_of_node "$n")
  echo "===== $n: kernel prerequisites (seg6_enabled, vrf, strict_mode) ====="
  node_run "$c" "for k in all default Ethernet0 Ethernet4 Loopback0; do sudo sh -c \"echo 1 > /proc/sys/net/ipv6/conf/\$k/seg6_enabled\" 2>/dev/null; done; printf 'seg6_enabled='; for k in all default Ethernet0 Ethernet4 Loopback0; do printf '%s,' \$(cat /proc/sys/net/ipv6/conf/\$k/seg6_enabled 2>/dev/null || echo missing); done; echo" || true
  node_run "$c" "grep -qE '^vrf ' /proc/modules || sudo modprobe vrf 2>/dev/null; lsmod | grep -E '^vrf' || echo vrf-missing" || true
  node_run "$c" "sudo sh -c 'echo 1 > /proc/sys/net/vrf/strict_mode' 2>/dev/null; printf 'strict_mode='; cat /proc/sys/net/vrf/strict_mode 2>/dev/null || echo no-proc-entry" || true
}

# locator + advertisement: CONFIG_DB row (silent remove, then add), the /128
# test address on Loopback0, the zebra static and the bgpd network for the
# /48, then the loop-free kernel pins.
apply_locator_and_advertisement() {
  local n=$1 c loc asn lo6 out
  c=$(container_of_node "$n")
  loc=$(python3 -c "import json;p=json.load(open('$PLAN_DIR/plan.$n.json'));print(p['locator'])")
  asn=$(python3 -c "import json;p=json.load(open('$PLAN_DIR/plan.$n.json'));print(p['asn'])")
  lo6=$(python3 -c "import json;p=json.load(open('$PLAN_DIR/plan.$n.json'));print(p['lo6'].split('/')[0])")
  echo "===== $n: locator $loc (GCU CONFIG_DB class: silent remove, then add) ====="
  node_run "$c" "sudo python3 /tmp/.cf_locator_rm.py \"$n\"" >/dev/null 2>&1 || true
  out=$(node_run "$c" "sudo python3 /tmp/.cf_locator_add.py \"$n\" \"${loc%/*}\"" 2>/dev/null || true)
  if ! grep -q '^APPLIED' <<<"$out"; then
    # Same failure class as the underlay: GCU cannot load the CURRENT config,
    # so the add raises before the row lands. SRV6_MY_LOCATORS is a plain
    # redis table on this image - write the row directly and re-read.
    echo "$n: GCU locator add did not land -> direct redis write fallback"
    node_run "$c" "sudo redis-cli -n 4 HSET 'SRV6_MY_LOCATORS|loc-$n' prefix '${loc%/*}'" >/dev/null 2>&1 || true
    out="DIRECT-WRITTEN"
  fi
  echo "$n redis locator row: $(node_run "$c" "sudo redis-cli -n 4 --raw HGET 'SRV6_MY_LOCATORS|loc-$n' prefix" 2>/dev/null || true)"
  [[ "$(node_run "$c" "sudo redis-cli -n 4 --raw HGET 'SRV6_MY_LOCATORS|loc-$n' prefix" 2>/dev/null)" == "${loc%/*}" ]] \
    || note_fail "$n locator row missing after add (GCU + direct write)"
  echo "$n frr locator row:  $(guest_count "$c" "vtysh -c 'show segment-routing srv6 locator' | grep -c 'loc-$n'")"
  echo "===== $n: advertisement (Loopback0 /128 + zebra static + bgpd network) ====="
  # The locator is stored with its /48 length (`fcbb:bbbb:N::/48`), so
  # `${loc%/*}` already ends in `::`; the endpoint appends only `1`
  # (`fcbb:bbbb:N::1/128`). Appending `::1` produced `fcbb:bbbb:N::::1`,
  # a malformed address that CONFIG_DB (and the config save) then carried:
  # hostcfgd crash-looped on ipaddress ValueError and the guest services
  # could not hold state (measured 2026-10-14).
  node_run "$c" "sudo ip addr replace ${loc%/*}1/128 dev Loopback0" >/dev/null 2>&1 || true
  # Locator endpoint durably in CONFIG_DB too: the reload's post-restart
  # orchagent reconciliation prunes kernel addresses it does not own, which
  # silently removed the bare `ip addr replace` endpoint (measured 2026-10-14:
  # ::1 gone minutes after reload). A LOOPBACK_INTERFACE row makes it owned.
  node_run "$c" "sudo redis-cli -n 4 HSET 'LOOPBACK_INTERFACE|Loopback0|${loc%/*}1/128' NULL NULL" >/dev/null 2>&1 || true
  node_run "$c" "vtysh -c 'conf t' -c 'ipv6 route ${loc%/*}/48 Loopback0' -c 'end'" >/dev/null 2>&1 || true
  node_run "$c" "vtysh -c 'conf t' -c 'router bgp $asn' -c 'address-family ipv6 unicast' -c 'network $loc' -c 'end'" >/dev/null 2>&1 || true
  # The 202505 template's bgp_adv_lo_prefix_as_128 knob emits only the IPv4
  # /32 network statement; the IPv6 loopback /128 needs an explicit one
  # (measured 2026-10-14: rendered bgpd.conf carried only `network 10.0.0.x/32`,
  # so no v6 loopback /128 was reachable anywhere and the v6 iBGP spine peer
  # never had a route to its peer's update-source).
  node_run "$c" "vtysh -c 'conf t' -c 'router bgp $asn' -c 'address-family ipv6 unicast' -c 'network $lo6/128' -c 'end'" >/dev/null 2>&1 || true
  echo "$n origination read-back: $(guest_count "$c" "vtysh -c 'show running-config' | grep -c 'network ${loc%/*}/48'") network row(s)"
  echo "===== $n: loop-free locator pins (metric 5) ====="
  local pin
  while read -r pin; do
    [[ -n "$pin" ]] || continue
    node_run "$c" "sudo ip -6 route replace $pin" >/dev/null 2>&1 || true
  done < <(python3 -c "import json;p=json.load(open('$PLAN_DIR/plan.$n.json'));print('\n'.join(x['prefix']+' via '+x['via']+' dev '+x['dev']+' metric 5' for x in p['pins']))")
  node_run "$c" "ip -6 route show | grep -E 'fcbb:bbbb.*metric 5' | sed 's/^/pin: /'" || true
}

# bounded BGP session wait — the AUTHORITATIVE post-reload gate (underlay-node
# class: awk established-count over the summary's 10th column; a leaf wants 2
# per family, a spine 3).
#
# Render model (measured 2026-10-14, yield4 stage 3): on this image bgpcfgd
# renders GCU-written BGP_NEIGHBOR rows only at container boot replay. Writes
# into CONFIG_DB on a RUNNING system sit in the dep gate indefinitely (0
# established for 15+ min across all four nodes despite the HSET nudge), and a
# node's sessions can only form once BOTH ends have re-rendered — i.e. after
# both ends went through config reload. So this wait is only meaningful after
# every node has reloaded; the orchestrator calls it exclusively from the
# final gate, never per-node inside the reload loop (the first-reloaded nodes
# would spuriously fail while their peers are still mid-reload — measured:
# spines FAIL 0<3 at their own reload, then all 12 sessions form minutes later
# as the leaves finish).
wait_sessions() {
  local n=$1 c want fam i have
  c=$(container_of_node "$n")
  want=$(python3 -c "import json;p=json.load(open('$PLAN_DIR/plan.$n.json'));print(p['expected_sessions'])")
  # The dep gate may still hold the rendered neighbors back; nudge once so
  # the wait observes real session progress rather than a stuck queue.
  bgpcfgd_nudge "$n"
  for fam in ipv4 ipv6; do
    have=0
    for i in $(seq 1 24); do
      have=$(node_run "$c" "vtysh -c 'show bgp $fam unicast summary'" 2>/dev/null | awk '$10 ~ /^[0-9]+$/ {e++} END {print e+0}')
      [[ "${have:-0}" -ge "$want" ]] 2>/dev/null && break
      sleep 5
    done
    echo "$n $fam ESTABLISHED=${have:-0} (want >= $want)"
    [[ "${have:-0}" -ge "$want" ]] || note_fail "$n $fam established ${have:-0} < $want"
  done
}

# pre-reload session observation (pass 2) — DIAGNOSTIC ONLY, never gates: the
# render model above says live sessions are NOT expected before the reloads;
# this pass just records whether any formed early so the log keeps the
# evidence either way. Kept short: 6 probes x 5s per family.
observe_sessions() {
  local n=$1 c want fam have
  c=$(container_of_node "$n")
  want=$(python3 -c "import json;p=json.load(open('$PLAN_DIR/plan.$n.json'));print(p['expected_sessions'])")
  for fam in ipv4 ipv6; do
    have=0
    local i
    for i in $(seq 1 6); do
      have=$(node_run "$c" "vtysh -c 'show bgp $fam unicast summary'" 2>/dev/null | awk '$10 ~ /^[0-9]+$/ {e++} END {print e+0}')
      [[ "${have:-0}" -ge "$want" ]] 2>/dev/null && break
      sleep 5
    done
    echo "$n $fam pre-reload ESTABLISHED=${have:-0} (want >= $want; informational)"
  done
}

# ---------------------------------------------------------------------------
# Pass 1: apply everything (neighbors first, sessions come up as nodes appear)
# ---------------------------------------------------------------------------
echo "===== configure-fabric: apply pass over ${NODES[*]} ====="
for n in "${NODES[@]}"; do
  push_plan "$n"
  apply_underlay "$n"
  bgpcfgd_render_check "$n"
  spine_fixups "$n"
  kernel_prereqs "$n"
  apply_locator_and_advertisement "$n"
  apply_evpn_neighbor_activation "$n"
  apply_overlay_baseline "$n"
  apply_ecmp_multipath "$n"
  apply_multipath_hash_policy "$n"
  set_jumbo "$n"
done

# ---------------------------------------------------------------------------
# Pass 2: pre-reload session observation (diagnostic only — see the render
# model note on wait_sessions; not a gate)
# ---------------------------------------------------------------------------
echo "===== configure-fabric: pre-reload session observation ====="
for n in "${NODES[@]}"; do observe_sessions "$n"; done

# ---------------------------------------------------------------------------
# Pass 3: persistence — save, reload, re-assert, verify (T137; the
# spike-persistence caveat: config reload keeps CONFIG_DB but loses kernel
# service state and the FRR locator binding, so the bootstrap re-asserts)
# ---------------------------------------------------------------------------
# identity_reassert <node> — re-claim the managed DEVICE_METADATA identity
# (hostname, bgp_asn, bgp_router_id, bgp_adv_lo_prefix_as_128) from the plan.
# Pass 1 writes identity once through the underlay direct-write; the live
# field is exactly the managed path the drift suite (tests/integration/
# drift_preservation.sh) mutates out-of-band, and a `config reload` keeps
# whatever is in redis — so the re-assert pass re-claims it (the drift
# oracle's restorer). Same `sudo redis-cli -n 4 HSET` class the
# underlay_direct.py applier uses, verified by read-back.
identity_reassert() {
  local n=$1 c asn router_id got
  c=$(container_of_node "$n")
  asn=$(python3 -c "import json;p=json.load(open('$PLAN_DIR/plan.$n.json'));print(p['asn'])")
  router_id=$(python3 -c "import json;p=json.load(open('$PLAN_DIR/plan.$n.json'));print(p['router_id'])")
  node_run "$c" "sudo redis-cli -n 4 HSET 'DEVICE_METADATA|localhost' hostname '$n' bgp_asn '$asn' bgp_router_id '$router_id' bgp_adv_lo_prefix_as_128 'true'" >/dev/null 2>&1 \
    || { note_fail "$n identity reassert"; return 1; }
  got=$(node_run "$c" "sudo redis-cli -n 4 --raw HMGET 'DEVICE_METADATA|localhost' hostname bgp_asn bgp_router_id" 2>/dev/null | paste -sd, -)
  [[ "$got" == "$n,$asn,$router_id" ]] || { note_fail "$n identity read-back '$got'"; return 1; }
}

persistence_reassert() {
  local n=$1 c loc asn
  c=$(container_of_node "$n")
  loc=$(python3 -c "import json;p=json.load(open('$PLAN_DIR/plan.$n.json'));print(p['locator'])")
  identity_reassert "$n"
  kernel_prereqs "$n"
  apply_locator_and_advertisement "$n"
  spine_fixups "$n"
  # Live vtysh overlay state (advertise-all-vni, the vni route-target, the
  # EVPN AF neighbor activation, the vrf VrfBlue block, the L3-VNI binding)
  # and the kernel joins do not survive config reload; the CONFIG_DB rows do,
  # so this re-runs the whole idempotent baseline.
  apply_evpn_neighbor_activation "$n"
  apply_overlay_baseline "$n"
  # strict: post-reload (and --reassert) bgpd runs the plan AS, so a
  # maximum-paths rejection here is a real failure, not the Pass-1 race.
  apply_ecmp_multipath "$n" strict
  # The kernel multipath hash policy is live kernel state like the overlay
  # joins — idempotent re-assert keeps L4 hashing asserted after every
  # reload. No flow split is re-asserted: none is installed (owner amendment
  # 2026-10-16 — the ECMP floor fails honestly instead).
  apply_multipath_hash_policy "$n"
  # set_jumbo LAST in this pass: apply_overlay_baseline can del+add the vtep
  # devices (its healing bounce), which re-renders the image-default MTU 1500
  # — measured live 2026-10-15, a reassert whose jumbo ran before the overlay
  # baseline handed back vteps at 1500 and the jumbo ping failed. Asserting
  # the MTUs after every device-touching step (with read-back) keeps the
  # reassert's exit state jumbo.
  set_jumbo "$n"
}

# ---------------------------------------------------------------------------
# --reassert mode (T223/T224 root-cause fix): Pass-3's re-assert + Pass-4's
# gate with NO config save/reload, for provision.sh to run AFTER the
# capability gate. scripts/lib/qualify.sh reloads every guest for its
# persistence witness once this bootstrap is done, and the sonic-vm guest
# keeps the CONFIG_DB rows but loses the live vtysh (advertise-all-vni, the
# EVPN AF neighbor activation, the vrf VrfBlue binding) and the kernel joins
# on every reload — the exact state Pass 3 exists to restore. Measured
# 2026-10-15 (chain run): the hook's own Pass-4 gate passed (adoption L2=1
# L3=1, remote VTEPs=1 on both leaves), the qualify reload followed, and
# q3-fabric minutes later found `show evpn vni` empty on both leaves. The
# re-assert is the validated healing path (the 2026-10-15 01:38 validate6
# hook re-run re-claimed the same state and client pings went 0% loss).
# provision.sh invokes this only for the sonic-vm profile: the sonic-vs
# bootstrap's overlay rides bgpcfgd-rendered durable FRR config, which
# survives reloads (p3-vs fabric_verify green on the same gate sequence).
# ---------------------------------------------------------------------------
if [[ "$REASSERT" -eq 1 ]]; then
  echo "===== configure-fabric --reassert: post-qualify re-assert (no save/reload) ====="
  for n in "${NODES[@]}"; do
    push_plan "$n"
    bgpcfgd_nudge "$n"
    persistence_reassert "$n"
    echo "PERSISTENCE-REASSERTED $n"
  done
  echo "===== configure-fabric --reassert: session + adoption gate ====="
  for n in "${NODES[@]}"; do
    echo "----- $n: post-reassert session verification -----"
    wait_sessions "$n"
    verify_overlay_adoption "$n"
  done
  echo "===== configure-fabric summary ====="
  if [[ "$failures" -eq 0 ]]; then
    echo "CONFIGURE-FABRIC-OK nodes=${NODES[*]} (reassert)"
    exit 0
  fi
  echo "CONFIGURE-FABRIC-FAIL failures=$failures"
  exit 1
fi

echo "===== configure-fabric: persistence (config save + config reload + re-assert) ====="
for n in "${NODES[@]}"; do
  c=$(container_of_node "$n")
  echo "----- $n: config save -----"
  node_run "$c" "sudo config save -y" >/dev/null 2>&1 || note_fail "$n config save failed"
  echo "----- $n: config reload (connection drops; bounded re-wait) -----"
  # systemd start-limit: a run of back-to-back bootstrap runs each restarting
  # the guest services through `config reload` arms StartLimitBurst and leaves
  # swss/syncd/bgp refused (`Result=start-limit-hit`, measured 2026-10-14).
  # Clear any armed or failed state immediately before the reload's service
  # restarts; each node reloads at most once per run.
  node_run "$c" "sudo systemctl reset-failed swss syncd bgp" >/dev/null 2>&1 || true
  node_run "$c" "sudo config reload -y" >/dev/null 2>&1 || true
  up=0
  for i in $(seq 1 36); do
    if node_run "$c" "true" >/dev/null 2>&1; then up=1; break; fi
    sleep 10
  done
  [[ "$up" -eq 1 ]] || { note_fail "$n guest SSH never returned after config reload"; continue; }
  # bgpd must answer again before any re-assert; a config reload restarts the
  # bgp container, but the dep gate can still hold neighbors back — nudge.
  for i in $(seq 1 24); do
    have=$(guest_count "$c" "vtysh -c 'show running-config' | grep -c 'neighbor .* remote-as'")
    [[ "$have" -ge 1 ]] 2>/dev/null && break
    sleep 5
  done
  bgpcfgd_nudge "$n"
  persistence_reassert "$n"
  echo "----- $n: post-reload state read-back -----"
  echo "$n identity: $(node_run "$c" "sudo redis-cli -n 4 --raw HMGET 'DEVICE_METADATA|localhost' hostname bgp_asn bgp_router_id" 2>/dev/null | paste -sd, -)"
  echo "$n locator row: $(node_run "$c" "sudo redis-cli -n 4 --raw HGET 'SRV6_MY_LOCATORS|loc-$n' prefix" 2>/dev/null)"
  echo "$n frr locator: $(guest_count "$c" "vtysh -c 'show segment-routing srv6 locator' | grep -c 'loc-$n'")"
  echo "PERSISTENCE-REASSERTED $n"
done

# ---------------------------------------------------------------------------
# Pass 4: authoritative post-reload BGP session gate — runs ONLY after every
# node has reloaded, so both ends of every session have re-rendered (see the
# render model note on wait_sessions; measuring per-node inside the reload
# loop false-fails the first-reloaded nodes — measured 2026-10-14: spines
# recorded 0<3 at their own reload yet all 12 sessions formed once the
# leaves finished their reloads).
# ---------------------------------------------------------------------------
echo "===== configure-fabric: post-reload BGP session gate ====="
for n in "${NODES[@]}"; do
  echo "----- $n: post-reload session verification -----"
  wait_sessions "$n"
  verify_overlay_adoption "$n"
done

echo "===== configure-fabric summary ====="
if [[ "$failures" -eq 0 ]]; then
  echo "CONFIGURE-FABRIC-OK nodes=${NODES[*]}"
  exit 0
fi
echo "CONFIGURE-FABRIC-FAIL failures=$failures"
exit 1
