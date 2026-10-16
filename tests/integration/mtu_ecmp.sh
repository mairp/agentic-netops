#!/usr/bin/env bash
# T047a [US3] MTU and ECMP tests: verify maximum effective MTU accommodates VXLAN overhead and ECMP hashing
set -euo pipefail

CLAB_PREFIX=${CLAB_PREFIX:-clab-agentic-netops-fabric-}
SRC=${SRC:-${CLAB_PREFIX}client01}
DST_IP=${DST_IP:-192.0.2.21}

GNMIC_BIN=${GNMIC_BIN:-gnmic}
# gNMI credentials: env wins; otherwise resolve the lab's generated creds.
# The sonic-vs profile generates per-lab credentials (scripts/lib/containerlab.sh
# injects them into each node); admin/admin is only the sonic-vm guest default,
# so a bare suite run on vs must resolve them from the cluster Secret, same as
# the persistence stage does.
if [[ -z "${GNMI_USER:-}" || -z "${GNMI_PASS:-}" ]]; then
  # sonic-vm guard: the vm guests keep the factory admin/admin mgmt account —
  # the provision injects no per-lab creds into a guest — so resolving the
  # cluster's generated secret here would 401 every read on that profile
  # (gnmi-lab-creds exists whenever the kind stack does, profile-independently).
  # Only a docker-native SONiC lab (clab-node-kind != sonic-vm) resolves them.
  if [[ "$(docker inspect clab-agentic-netops-fabric-leaf01 \
        --format '{{index .Config.Labels "clab-node-kind"}}' 2>/dev/null)" != "sonic-vm" ]]; then
    # shellcheck disable=SC1091
    [[ -f scripts/lib/lab_secrets.sh ]] && source scripts/lib/lab_secrets.sh && lab_secrets::ensure >/dev/null 2>&1 || true
  fi
fi
GNMI_USER=${GNMI_USER:-admin}
GNMI_PASS=${GNMI_PASS:-admin}
GNMI_CACERT=${GNMI_CACERT:-./secrets/ca.crt}
GNMI_CERT=${GNMI_CERT:-./secrets/gnmi.crt}
GNMI_KEY=${GNMI_KEY:-./secrets/gnmi.key}
GNMI_ENCODING=${GNMI_ENCODING:-JSON_IETF}
LEAF1=${LEAF1:-172.31.0.21:8080}

# node_run/node_sudo: portable node-side dispatch (docker exec on sonic-vs,
# guest SSH on sonic-vm). Used by the ECMP counter read below.
# shellcheck disable=SC1091
source "$(dirname -- "${BASH_SOURCE[0]}")/lib/node_exec.sh"

_args_common=(--timeout 10s --username "$GNMI_USER" --password "$GNMI_PASS" --encoding "$GNMI_ENCODING" --tls-ca "$GNMI_CACERT" --tls-cert "$GNMI_CERT" --tls-key "$GNMI_KEY")

# Warm the data plane before the jumbo probe. The suite can run seconds after
# bring-up (or right after another suite), when client01's ARP entry for
# client02 may not exist yet — the first probe then answers "Destination Host
# Unreachable" (measured 2026-10-15: p4-vs-mtu_ecmp failed exactly there) and
# a single-packet jumbo test reads 100% loss for a reason that has nothing to
# do with MTU. Bounded standard-frame warm-up first: small frames cannot trip
# an MTU limit, so this cannot mask a real MTU failure — the jumbo assertion
# below stays strict. Worst case ~30 probes x (2s timeout + 2s gap).
warm_path() {
  local i
  for i in $(seq 1 30); do
    if docker exec "$SRC" ping -c 1 -W 2 "$DST_IP" >/dev/null 2>&1; then
      echo "[mtu-ecmp] path warm after $i probe(s): $SRC -> $DST_IP answers standard frames"
      return 0
    fi
    sleep 2
  done
  echo "[mtu-ecmp] ERROR: $SRC -> $DST_IP never answered a standard frame (path never converged; MTU verdict meaningless)" >&2
  return 1
}

# Verify effective MTU across the overlay accommodates VXLAN overhead
vxlan_mtu_test() {
  echo "[mtu-ecmp] maximum effective MTU accommodates VXLAN overhead"
  warm_path
  # attempt a near-jumbo payload; 8900 bytes payload should pass with 9216 underlay MTU
  docker exec "$SRC" ping -c 1 -W 2 -M do -s 8900 "$DST_IP"
}

# Counter read from the node-side SONiC COUNTERS redis table (redis DB 2),
# reached through node_run. Replaces the earlier host-side gNMI
# /openconfig-interfaces:.../state/counters/out-octets read: the sonic-vs
# 202505 image's mgmt framework answers that path with "No entry found in
# xYangSpecMap for URI" (the OC counters mapping is absent there), so both
# vs receipts false-failed on empty reads while the same read worked on
# sonic-vm (measured 2026-10-15, p3-vs/p4-vs-mtu_ecmp). The raw COUNTERS
# table is the surface counterpoll itself feeds on every SONiC image —
# COUNTERS_PORT_NAME_MAP maps the port name to its oid, and DB 2 is
# COUNTERS_DB in both images' database_config.json (verified 2026-10-15:
# sonic-vs image ships /usr/bin/redis-cli + COUNTERS_DB id 2; sonic-vm guest
# answers the same read). Admin can read redis directly; no sudo needed.
#
# sonic-vs exception (measured 2026-10-15 21:23, p3/p4-vs-mtu_ecmp: every poll
# read empty on a fresh provision whose jumbo census was green): the deployed
# vs lab keeps the CONFIG_DB PORT table empty ON PURPOSE — PORT rows are the
# leafref targets of VLAN_MEMBER and would poison every GCU write image-wide
# (see configure-fabric-bgp.sh patch-2 comment) — so orchagent never creates
# SAI ports, COUNTERS_PORT_NAME_MAP never exists in DB 2, and this redis read
# is empty on EVERY poll there regardless of counterpoll. The uplink bytes are
# still directly observable kernel-side, which is the same measurement taken
# at the surface this profile actually feeds. sonic-vm keeps the redis read
# (its guest SONiC populates the SAI pipeline; the q3-mtu/q3-mtu-default
# increments came from there), and the kernel fallback below only arms when
# that read comes back empty.
_kernel_iface() { # SONiC port name -> kernel interface carrying it in the node
  local ifname=$1
  if node_is_vm "${CLAB_PREFIX}leaf01"; then printf '%s' "$ifname"; return; fi
  # sonic-vs: the topology binds leaf eth1 -> spine01 and eth2 -> spine02
  # (lab/topology.clab.yml links), which the port plan names Ethernet0/4.
  case "$ifname" in
    Ethernet0) printf 'eth1' ;;
    Ethernet4) printf 'eth2' ;;
    *) printf '%s' "$ifname" ;;
  esac
}

_read_counter() {
  local ifname=$1
  local c=${CLAB_PREFIX}leaf01
  local oid val kif
  oid=$(node_run "$c" "redis-cli --raw -n 2 HGET COUNTERS_PORT_NAME_MAP $ifname" 2>/dev/null || true)
  val=$(node_run "$c" "redis-cli --raw -n 2 HGET COUNTERS:$oid SAI_PORT_STAT_IF_OUT_OCTETS" 2>/dev/null || true)
  if [[ -z "$val" ]]; then
    kif=$(_kernel_iface "$ifname")
    val=$(node_run "$c" "cat /sys/class/net/$kif/statistics/tx_bytes" 2>/dev/null || true)
  fi
  printf '%s' "$val"
}

# ECMP hashing verification (distribution across spines)
ecmp_hashing_test() {
  echo "[mtu-ecmp] ECMP hashing where qualified"
  # The leaf's two uplinks, per the fabric plan (fabric.yaml §7: leaf01
  # Ethernet0 -> spine01, Ethernet4 -> spine02; the sonic-vs plan rides the
  # same SONiC port names — eth1/eth2 in the container map to them). The old
  # defaults Ethernet1/Ethernet2 were the 001 sketch's names; no node in
  # either profile has them, so both counters read empty and the test
  # false-failed on "missing interface counters".
  local IF_A=${IF_A:-Ethernet0} # uplink to spine01
  local IF_B=${IF_B:-Ethernet4} # uplink to spine02
  # Burst sizing and the pass floor (owner directive 2026-10-16 00:56, after
  # the idle-sample finding): the uplinks carry a periodic control-plane tick
  # of a few hundred bytes (measured 2026-10-16 00:56 on an idle sonic-vs lab:
  # +342 and +412 B per ~60 s window), so a ">0 increment" assertion is
  # provable by BACKGROUND traffic alone — the 23:21/00:51 "greens" were
  # exactly that (deltas +754/+754 and +438/+190, one tick in the window, on a
  # burst of ~32 x 9-byte echo lines that never crossed the fabric in
  # quantity). The burst must therefore stand clear of the background BY
  # CONSTRUCTION: 32 flows x 40 packets x 1000-byte payload = 1,280,000
  # payload bytes, and each uplink must move >= 25% of that burst (320,000 B),
  # roughly 800x the observed tick. The floor and the bytes sent are printed
  # into the receipt so the arithmetic is checkable; a miss is an honest exit
  # 1 naming the deltas, and the floor is never lowered.
  local BURST_FLOWS=32
  local BURST_PACKETS=40
  local BURST_PAYLOAD_BYTES=1000
  local BURST_BYTES=$(( BURST_FLOWS * BURST_PACKETS * BURST_PAYLOAD_BYTES )) # 1,280,000
  local BURST_FLOOR_PCT=25
  local BURST_FLOOR=$(( BURST_BYTES * BURST_FLOOR_PCT / 100 ))              # 320,000
  local pre_a pre_b post_a post_b
  pre_a=$(_read_counter "$IF_A"); pre_b=$(_read_counter "$IF_B")
  # Send the burst: 32 distinct UDP flows (one busybox nc per flow, dst ports
  # 20000-20031). ECMP hashing is per-flow (per outer-tuple), so n=32 keeps
  # the both-uplinks floor meaningful (p≈2^-32 for a one-sided miss) without
  # asserting any particular split. The flows ride the client's nc: the
  # image's busybox sh has no /dev/udp (measured: every >/dev/udp write failed
  # with "can't create", so an earlier /dev/udp burst sent nothing at all) and
  # busybox nc does carry -u. The payload is a 40,040-byte file of 40 newline-
  # terminated 1000-byte lines, built host-side once and fed to each flow via
  # `docker exec -i`, so every flow carries the full 40 packets (the old
  # `echo -n flow-$p | nc` form sent one ~9-byte packet per flow — the noise
  # the idle-sample finding rejected). Payload bytes are exact: 1000 payload
  # characters per line; the trailing newline is transport framing, not
  # counted in BURST_BYTES.
  local line p
  # The payload file path lives in a GLOBAL (not a local): the cleanup trap
  # fires after this function returns, and a local name is then unset — under
  # `set -u` the trap aborted the run AFTER the pass verdict was printed
  # (measured 2026-10-16: "payload: unbound variable", exit 1 on a green
  # assertion set).
  BURST_PAYLOAD_FILE=$(mktemp /tmp/mtu-ecmp-burst.XXXXXX)
  local payload=$BURST_PAYLOAD_FILE
  line=$(printf 'x%.0s' $(seq 1 "$BURST_PAYLOAD_BYTES"))
  : > "$payload"
  for p in $(seq 1 "$BURST_PACKETS"); do printf '%s\n' "$line" >> "$payload"; done
  trap '[[ -n "${BURST_PAYLOAD_FILE:-}" ]] && rm -f "$BURST_PAYLOAD_FILE"' EXIT
  for p in $(seq 20000 $(( 20000 + BURST_FLOWS - 1 ))); do
    docker exec -i "$SRC" sh -lc "nc -u -w1 $DST_IP $p || true" < "$payload" >/dev/null 2>&1 || true
  done
  echo "[mtu-ecmp] burst sent: $BURST_FLOWS flows x $BURST_PACKETS packets x ${BURST_PAYLOAD_BYTES}-byte payload = $BURST_BYTES bytes"
  # ECMP mechanism, stated plainly (measured live 2026-10-16 on the sonic-vm
  # leaf): the kernel-vxlan encap route lookup builds a flow with NO L4 fields,
  # so even fib_multipath_hash_policy=1 pins every encapped flow to ONE
  # multipath bucket (tcpdump: every outer frame carried the same spine dst
  # MAC while `ip route get` alternated per sport). NO port- or mark-keyed
  # flow split is installed to paper over this (owner amendment 2026-10-16
  # forbids one): hash policy 1 (L4) and BGP maximum-paths 2 are asserted,
  # and the both-uplinks floor below is expected to FAIL HONESTLY until the
  # limitation is fixed at the source — the receipts record the failure live
  # and the evidence cites the cause (installed two-nexthop route +
  # L4-less encap lookup on sonic-vm; peer-VTEP route over mgmt on sonic-vs).
  echo "[mtu-ecmp] ECMP mechanism: kernel-vxlan encap lookup carries no L4 fields — fib_multipath_hash_policy=1 (L4) and BGP maximum-paths 2 underneath, yet every encapped flow pins to one multipath bucket; NO flow split is installed (owner amendment 2026-10-16), so the both-uplinks floor below fails honestly"
  echo "[mtu-ecmp] ECMP floor: each uplink delta must be >= $BURST_FLOOR bytes ($BURST_FLOOR_PCT% of the burst); background ticks (~1 KB/min, measured 2026-10-16) cannot reach it"
  # counterpoll feeds the COUNTERS table on its poll interval (10 s default);
  # an immediate single read can predate the last sample taken over the burst
  # (measured 2026-10-15 on sonic-vm: the same DB behind the old gNMI read
  # only showed the delta after the poll tick). Bounded poll: up to 6 x 3 s
  # until BOTH uplinks clear the floor — the strict assertion below still
  # fires if they never do.
  local try ok=1
  for try in 1 2 3 4 5 6; do
    sleep 3
    post_a=$(_read_counter "$IF_A"); post_b=$(_read_counter "$IF_B")
    echo "[mtu-ecmp] counters after poll $try: ${IF_A}=$post_a ${IF_B}=$post_b"
    if [[ "$pre_a" =~ ^[0-9]+$ && "$pre_b" =~ ^[0-9]+$ \
       && "$post_a" =~ ^[0-9]+$ && "$post_b" =~ ^[0-9]+$ ]] \
       && (( post_a - pre_a >= BURST_FLOOR && post_b - pre_b >= BURST_FLOOR )); then
      ok=0
      break
    fi
  done
  if [[ "$pre_a" =~ ^[0-9]+$ && "$post_a" =~ ^[0-9]+$ ]]; then
    echo "[mtu-ecmp] ${IF_A} out-octets: $pre_a -> $post_a (delta $(( post_a - pre_a )), floor $BURST_FLOOR)"
  else
    echo "[mtu-ecmp] ${IF_A} out-octets: $pre_a -> $post_a (floor $BURST_FLOOR)"
  fi
  if [[ "$pre_b" =~ ^[0-9]+$ && "$post_b" =~ ^[0-9]+$ ]]; then
    echo "[mtu-ecmp] ${IF_B} out-octets: $pre_b -> $post_b (delta $(( post_b - pre_b )), floor $BURST_FLOOR)"
  else
    echo "[mtu-ecmp] ${IF_B} out-octets: $pre_b -> $post_b (floor $BURST_FLOOR)"
  fi
  # Assert both interfaces moved by at least the burst floor. A numeric
  # failure is still an honest exit 1 (no counters = no verdict, not a pass).
  if [[ -z "$pre_a" || -z "$post_a" || -z "$pre_b" || -z "$post_b" ]] \
     || [[ ! "$pre_a" =~ ^[0-9]+$ || ! "$post_a" =~ ^[0-9]+$ \
        || ! "$pre_b" =~ ^[0-9]+$ || ! "$post_b" =~ ^[0-9]+$ ]]; then
    echo "[mtu-ecmp] ERROR: missing or non-numeric interface counters (a=${pre_a}->${post_a} b=${pre_b}->${post_b})" >&2; exit 1
  fi
  if (( ok != 0 )); then
    echo "[mtu-ecmp] ERROR: ECMP floor not met: ${IF_A} delta $(( post_a - pre_a )), ${IF_B} delta $(( post_b - pre_b )); floor $BURST_FLOOR = $BURST_FLOOR_PCT% of the $BURST_BYTES-byte burst" >&2
    echo "[mtu-ecmp] ERROR: a delta below the floor means the burst is not crossing the fabric as encapped ECMP traffic (or an uplink received no flows); background ticks cannot produce a pass" >&2
    exit 1
  fi
  echo "[mtu-ecmp] ECMP PASS: both uplinks moved >= $BURST_FLOOR bytes ($BURST_FLOOR_PCT% of the $BURST_BYTES-byte burst)"
}

case "${1:-run}" in
  run)
    vxlan_mtu_test
    ecmp_hashing_test
    ;;
  *) echo "usage: $0 run" >&2; exit 2 ;;
esac
