#!/usr/bin/env bash
# srv6_failover_path_change.sh — US5 (feature 004) failover and
# operator-directed path change (T527-T530; plan 6-10), quickstart q11.
#
# One mode per acceptance proof; the flag argument names the SRv6Service
# resource and every fact — attachments, the preferred/alternate spine, the
# per-leaf pin legs (spine-side link addresses and ports), the service SIDs,
# the client addresses — is read from the LIVE resource, the pinned lab
# profile (lab/profiles/sonic-vm/fabric.yaml, the same source the
# controller's SiteFacts pin) or the device itself. Nothing is typed here.
#
# The per-service mechanism under test (data-model §8.6): the controller
# pins the /64 to the peer's End.DT46 function space on the ingress leaf via
# the PREFERRED spine's leg
# (`ip -6 route replace <peer fn> from :: via <preferred leg> dev <port>
# metric 20`); `status.activePath` is read off that pin's via address. The
# operator's failure action (§3.2) is driving the pin itself: the script
# deletes the preferred pin and re-points it via the ALTERNATE spine's leg —
# the controller's next verification then reads the pin's via address, names
# the alternate in `status.activePath` and treats the switch as FAILOVER,
# not drift (FR-026: no drift repair would re-install the preferred pin and
# undo the operator's switch). Both pins gone is neither path usable: the
# service goes not-Ready PathDown naming the missing path.
#
# Modes:
#   --observe <name>         wire witness: while the clients probe, the
#                            ingress leaf's launcher-side uplink to the
#                            PREFERRED spine (eth1) carries SRH packets and
#                            the alternate's (eth2) carries none (§8.6)
#   --fail-preferred <name>  §3.2 failure action: delete the preferred pin,
#                            re-add it via the alternate spine's leg, with a
#                            1 Hz probe window across the switch; asserts
#                            the FR-026a bound after the switch (fail when
#                            more than 5 missed probes or more than 2
#                            consecutive losses), then polls
#                            status.activePath to name the alternate spine
#   --restore-preferred <name>  rollback: re-point the pin via the preferred
#                            spine's leg; same bound; activePath returns to
#                            the preferred spine
#   --fail-both <name>       both pins removed: Ready goes False with
#                            PathDown naming the missing path; the preferred
#                            pin is re-installed afterwards (self-restoring)
#   --assert-alert <name>    US8's SRv6PathDown alert proof — deliberately
#                            not implemented in US5 (exits 3)
#
# Honest SLO (printed by the failover modes): the FR-026a bound above holds
# for the operator-directed pin switch. The MEASURED bound for a real link
# death (the spike records, docs data-model §8.6) is wider — loss-bounded at
# missed <= 10 / longest run <= 10 probes at 1 Hz, because zebra must time
# the dead leg out (~10 s); SC-007's <= 5 missed / <= 2 consecutive bound is
# NOT met as measured for link-death failover, and there is no BFD.
#
# Node-side operations run ONLY through node_run/node_sudo
# (tests/integration/lib/node_exec.sh) — ssh into the sonic-vm guest or
# docker exec on a sonic-vs container, never docker exec into a switch from
# this file. The busybox probe clients are docker exec + sh -c (§8.7).
# Exit 0 only when the invoked mode's assertions pass.

set -u

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=tests/integration/lib/node_exec.sh
source "${ROOT_DIR}/tests/integration/lib/node_exec.sh"

CTX="${CTX:-kind-agentic-netops}"
NS="${NS:-agentic-netops-intent}"
LAB="clab-agentic-netops-fabric"
PROBE_CLIENT_01="${PROBE_CLIENT_01:-${LAB}-srv6-client01}"
PROBE_CLIENT_02="${PROBE_CLIENT_02:-${LAB}-srv6-client02}"
# data-model §8.2: node ids per leaf (the SRv6 function space is
# fcbb:bbbb:<node id>:<fn>::/64); fn 11 is the pinned service function.
NODE_IDS="${NODE_IDS:-leaf01=3,leaf02=4}"
SRV6_FN="${SRV6_FN:-11}"
FABRIC_YAML="${FABRIC_YAML:-${ROOT_DIR}/lab/profiles/sonic-vm/fabric.yaml}"
# Launcher-side uplink map (measured, spike-portmap-leaf01): launcher eth1 is
# the guest's Ethernet0 (the spine01 leg), eth2 the guest's Ethernet4
# (spine02 leg) — the wire witness watches both and requires traffic on
# exactly the preferred spine's.
LEG1_LAUNCHER_IF="${LEG1_LAUNCHER_IF:-eth1}"
LEG2_LAUNCHER_IF="${LEG2_LAUNCHER_IF:-eth2}"
LEG1_GUEST_PORT="${LEG1_GUEST_PORT:-Ethernet0}"
LEG2_GUEST_PORT="${LEG2_GUEST_PORT:-Ethernet4}"
# The controller re-verifies on the §5 drift resync interval (5 min), so
# status.activePath settles within one interval of the switch.
AWAIT_ACTIVE_PATH_TIMEOUT="${AWAIT_ACTIVE_PATH_TIMEOUT:-420}"
# The probe window across the switch: 1 Hz, sized so the switch lands
# between probe 7 and 8 and ~12 post-switch probes remain.
PROBE_COUNT="${PROBE_COUNT:-20}"
SWITCH_AT_PROBE="${SWITCH_AT_PROBE:-7}"

die() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "PASS: $*"; }

container_of() { printf '%s-%s' "$LAB" "$1"; }
client_of() { # client_of <node> -> the probe client attached to it
  case "$1" in
    leaf01) printf '%s' "$PROBE_CLIENT_01" ;;
    leaf02) printf '%s' "$PROBE_CLIENT_02" ;;
    *) die "no probe client convention for node $1" ;;
  esac
}

svc_get() { # svc_get <name> <jsonpath>
  local p=$2
  [[ "$p" == .* || "$p" == \[* ]] || p=".$p"
  kubectl --context "$CTX" -n "$NS" get srv6service "$1" -o "jsonpath={$p}" 2>/dev/null
}

svc_json() { kubectl --context "$CTX" -n "$NS" get srv6service "$1" -o json 2>/dev/null; }

# svc_attachments <name> -> "<node> <port>" lines in spec order
svc_attachments() {
  svc_json "$1" | python3 -c '
import json, sys
svc = json.load(sys.stdin)
for a in svc.get("spec", {}).get("attachments", []):
    print(a.get("node", ""), a.get("port", ""))
'
}

# svc_path_field <name> <preferredSpine|alternateSpine> -> name or ""
svc_path_field() {
  svc_json "$1" | python3 -c '
import json, sys
svc = json.load(sys.stdin)
print((svc.get("spec", {}).get("path", {}) or {}).get(sys.argv[1], "") or "")
' "$2"
}

# status_active_path <name> -> the observed status.activePath (may be "")
status_active_path() { svc_get "$1" "status.activePath"; }

client_ip() { # client_ip <container> — primary IPv4 of the probe iface
  docker exec "$1" sh -c "ip addr show eth1" 2>/dev/null |
    sed -n 's/.*inet \([0-9.]*\)[ \/].*/\1/p' | head -1
}

node_id() { # node_id <node> -> id from NODE_IDS
  local want=$1 entry
  case ",${NODE_IDS}," in
  *",${want}="*) ;;
  *) return 1 ;;
  esac
  for entry in ${NODE_IDS//,/ }; do
    if [[ "${entry%%=*}" == "$want" ]]; then
      printf '%s' "${entry##*=}"
      return 0
    fi
  done
  return 1
}

# pin_legs <node> -> "<spine> <spine-side v6> <spine-side port>" per spine,
# from the pinned profile (fabric.yaml: the leaf's links; peer_v6 is the
# spine-side address the pin's `via` uses; peer_port is the SPINE's port —
# the leaf's own dev comes from the device, see leg_of).
pin_legs() {
  python3 - "$FABRIC_YAML" "$1" <<'PY'
import sys
try:
    import yaml
except Exception as exc:  # pragma: no cover
    sys.exit(f"PyYAML unavailable: {exc}")
path, node = sys.argv[1], sys.argv[2]
with open(path, encoding="utf-8") as fh:
    doc = yaml.safe_load(fh)
nodes = doc.get("nodes") or {}
for link in (nodes.get(node) or {}).get("links") or []:
    peer = link.get("peer", "")
    if (nodes.get(peer) or {}).get("role", "") != "spine":
        continue
    v6 = (link.get("peer_v6") or "").split("/")[0]
    print(peer, v6, link.get("peer_port", ""))
PY
}

# leg_of <node> <spine> -> "<spine-side v6> <guest port>": the spine-side
# `via` address comes from the pinned profile (fabric.yaml `peer_v6`); the
# leaf's own dev for that leg is read off the DEVICE (`ip -6 route show` over
# node_run) because fabric.yaml's `peer_port` names the SPINE-side port, not
# the leaf's. Any route via that address carries the dev — the bootstrap
# locator pins (metric 5) ride the same legs and survive service-pin changes.
leg_of() { # leg_of <node> <spine> -> "<spine-side v6> <guest port>"
  local node=$1 want=$2 spine v6 port line dev c
  while read -r spine v6 port; do
    [[ "$spine" == "$want" ]] || continue
    c=$(container_of "$node")
    line=$(node_run "$c" "ip -6 route show" 2>/dev/null | grep -F "via ${v6} " | head -1)
    dev=$(awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}' <<<"$line")
    [[ -n "$dev" ]] || return 1
    # trailing newline: `read` populates the fields either way but returns 1
    # on EOF-without-newline, and every caller does `read ... || die`.
    printf '%s %s\n' "$v6" "$dev"
    return 0
  done < <(pin_legs "$node")
  return 1
}

# current_pin <node> <peer fn> -> the live pin line, e.g.
# "fcbb:bbbb:4:11:: from :: via 2001:db8:1::3 dev Ethernet0 metric 20"
current_pin() {
  local c; c=$(container_of "$1")
  node_run "$c" "ip -6 route show" 2>/dev/null | grep -F "$2 " | grep "from ::" | head -1
}

# spine_via <node> <pin line> -> the spine the pin's via address belongs to
spine_via() {
  local via
  via=$(awk '{for(i=1;i<=NF;i++) if($i=="via"){print $(i+1); exit}}' <<<"$2")
  [[ -n "$via" ]] || return 1
  local spine v6 port
  while read -r spine v6 port; do
    [[ "$v6" == "$via" ]] && { printf '%s' "$spine"; return 0; }
  done < <(pin_legs "$1")
  return 1
}

# flip_pin <node> <peer fn> <spine> — the §3.2 failure action, driven on the
# node: delete the current pin exactly as it reads, re-add it via <spine>'s
# leg (the controller's own op shape, metric 20).
flip_pin() {
  local node=$1 fn=$2 spine=$3 c line via port s
  c=$(container_of "$node")
  s=$(node_sudo "$c")
  line=$(current_pin "$node" "$fn")
  [[ -n "$line" ]] || die "$node: no pin for $fn to flip"
  read -r via port < <(leg_of "$node" "$spine") || die "no $spine leg on $node"
  echo "--- $node: deleting the current pin ($line)"
  node_run "$c" "${s} ip -6 route del ${line}" || die "$node: pin delete failed"
  echo "--- $node: re-pointing the pin via $spine ($via on $port)"
  node_run "$c" "${s} ip -6 route replace ${fn} from :: via ${via} dev ${port} metric 20" \
    || die "$node: pin re-add via $spine failed"
  line=$(current_pin "$node" "$fn")
  [[ "$line" == *"via ${via}"* ]] || die "$node: pin not via $spine after the flip ($line)"
}

# probe_window <client> <peer ip> <outfile> — the 1 Hz window the caller
# runs across the switch (iputils -O open-codes every unanswered sequence).
probe_window() {
  docker exec "$1" sh -c "ping -c ${PROBE_COUNT} -i 1 -W 2 -O $2 >$3 2>&1"
}

# classify_post_switch <ping output> -> "missed=<n> longest=<n>" — the pure
# parser behind the FR-026a bound: counts the probes with no answer AFTER the
# switch (icmp_seq beyond ${SWITCH_AT_PROBE}) and the longest consecutive run
# among them (iputils -O open-codes every unanswered sequence).
classify_post_switch() {
  local out=$1 post_lost=0 longest=0 run=0 prev=$((SWITCH_AT_PROBE)) seq s
  while read -r s; do
    seq=${s#icmp_seq=}
    [[ "$seq" =~ ^[0-9]+$ ]] || continue
    (( seq <= SWITCH_AT_PROBE )) && continue
    if (( seq == prev + 1 )); then run=$((run + 1)); else run=1; fi
    (( run > longest )) && longest=$run
    prev=$seq
    post_lost=$((post_lost + 1))
  done < <(grep -o 'icmp_seq=[0-9]*' <<<"$(grep 'no answer yet' <<<"$out" || true)" | sort -t= -k2 -n)
  printf 'missed=%d longest=%d\n' "$post_lost" "$longest"
}

# assert_post_switch_bound <client> <outfile> — FR-026a: after the switch,
# at most 5 missed probes and at most 2 consecutive losses. The switch lands
# between probe ${SWITCH_AT_PROBE} and ${SWITCH_AT_PROBE}+1 (the caller
# sleeps that long before flipping), so post-switch = icmp_seq beyond that.
assert_post_switch_bound() {
  local cl=$1 out cls missed longest sent
  out=$(docker exec "$cl" sh -c "cat $2" 2>/dev/null || true)
  [[ -n "$out" ]] || die "no probe output in $2 inside $cl (the window never ran)"
  sent=$(awk -F'[ ,]+' '/packets transmitted/{print $1; exit}' <<<"$out")
  cls=$(classify_post_switch "$out")
  missed=${cls#missed=}; missed=${missed%% *}
  longest=${cls##*longest=}
  echo "PROBES: ${sent:-0} at 1 Hz (switch between probe ${SWITCH_AT_PROBE} and $((SWITCH_AT_PROBE + 1)))"
  echo "POST-SWITCH LOSS: missed=${missed} longest-run=${longest}"
  echo "HONEST SLO: the FR-026a bound (missed<=5, consecutive<=2 after the switch) holds for the"
  echo "operator-directed pin switch. For a real LINK DEATH the measured bound is wider — loss-bounded"
  echo "at missed<=10 / longest-run<=10 at 1 Hz (zebra times the dead leg out, ~10 s); SC-007's bound"
  echo "is NOT met as measured for link-death failover, and there is no BFD (docs data-model §8.6)."
  if (( missed > 5 )) || (( longest > 2 )); then
    die "FR-026a bound exceeded after the switch: missed=${missed} (<=5), longest-run=${longest} (<=2)"
  fi
}

# await_active_path <name> <want spine> — poll status.activePath until it
# names <want> (the controller's resync re-verifies every 5 min).
await_active_path() {
  local name=$1 want=$2 i got=""
  for ((i = 0; i < AWAIT_ACTIVE_PATH_TIMEOUT; i += 10)); do
    got=$(status_active_path "$name")
    [[ "$got" == "$want" ]] && { echo "status.activePath = $got (after $((i))s)"; return 0; }
    sleep 10
  done
  die "status.activePath = '${got}', want '${want}' (waited ${AWAIT_ACTIVE_PATH_TIMEOUT}s)"
}

# await_ready <name> <True|False> [timeout]
await_ready() {
  local name=$1 want=$2 t=${3:-120} i got=""
  for ((i = 0; i < t; i += 5)); do
    got=$(svc_get "$name" "status.conditions[?(@.type=='Ready')].status")
    [[ "$got" == "$want" ]] && { echo "Ready=$got (after $((i))s)"; return 0; }
    sleep 5
  done
  die "Ready='${got}', want '${want}' (waited ${t}s)"
}

ready_reason_msg() { # "<reason>|<message>" of the Ready condition
  kubectl --context "$CTX" -n "$NS" get srv6service "$1" -o json 2>/dev/null | python3 -c '
import json, sys
svc = json.load(sys.stdin)
for cond in svc.get("status", {}).get("conditions", []) or []:
    if cond.get("type") == "Ready":
        print(cond.get("reason", "") + "|" + cond.get("message", ""))
        raise SystemExit
print("|")
'
}

preflight() { # preflight <node> <peer client ip> <what> — refuse to
              # measure a dead dataplane (the 2026-10-13 lesson)
  local cl
  cl=$(client_of "$1")
  docker exec "$cl" sh -c "ping -c 3 -i 1 -W 2 $2 >/dev/null 2>&1" ||
    die "PREFLIGHT-FAILED: $cl -> $2 does not pass; $3 refused (dead dataplane)"
}

# facts_of <name> -> sets INGRESS PEER PEER_FN PREF_SPINE ALT_SPINE
facts_of() {
  local name=$1 nodes=()
  mapfile -t nodes < <(svc_attachments "$name" | awk '{print $1}')
  [[ "${#nodes[@]}" -eq 2 ]] || die "need exactly 2 attachments, got ${#nodes[@]}"
  # The renderer's ingress is the sorted-first attachment node.
  INGRESS=$(printf '%s\n' "${nodes[@]}" | sort | head -1)
  PEER=$(printf '%s\n' "${nodes[@]}" | sort | tail -1)
  local cidr
  cidr=$(node_id "$PEER") || die "no node id for $PEER (NODE_IDS=$NODE_IDS)"
  PEER_FN="fcbb:bbbb:${cidr}:${SRV6_FN}::"
  PREF_SPINE=$(svc_path_field "$name" "preferredSpine")
  ALT_SPINE=$(svc_path_field "$name" "alternateSpine")
  [[ -n "$PREF_SPINE" ]] || die "$name is not steered: spec.path.preferredSpine is empty"
  [[ -n "$ALT_SPINE" ]] || die "$name names no alternate: spec.path.alternateSpine is empty"
}

# ---------------------------------------------------------------------------
# Modes
# ---------------------------------------------------------------------------
cmd_observe() { # --observe: the §8.6 wire witness on the launcher uplinks
  local name=$1
  facts_of "$name"
  local pin via_spine l1 pcap1 pcap2 n1 n2 cl peer_ip
  pin=$(current_pin "$INGRESS" "$PEER_FN")
  [[ -n "$pin" ]] || die "$INGRESS: no pin for $PEER_FN"
  via_spine=$(spine_via "$INGRESS" "$pin") || die "cannot read the pin's via spine ($pin)"
  echo "--- $INGRESS pin: $pin"
  echo "--- the pin's via address names ${via_spine} (spec.path.preferredSpine=${PREF_SPINE})"
  [[ "$via_spine" == "$PREF_SPINE" ]] || die "pin rides ${via_spine}, want the preferred ${PREF_SPINE}"
  l1=$(container_of "$INGRESS")
  cl=$(client_of "$INGRESS")
  peer_ip=$(client_ip "$(client_of "$PEER")")
  preflight "$INGRESS" "$peer_ip" "the wire witness"
  pcap1=$(mktemp /tmp/srv6-obs1.XXXXXX.txt); pcap2=$(mktemp /tmp/srv6-obs2.XXXXXX.txt)
  echo "--- tcpdump SRH on $l1 launcher ${LEG1_LAUNCHER_IF} (spine01 leg) and ${LEG2_LAUNCHER_IF} (spine02 leg)"
  docker exec "$l1" sh -c "timeout 14 tcpdump -i ${LEG1_LAUNCHER_IF} -t -l -nn 'ip6 and ip6[6]=43' >${pcap1} 2>/dev/null" &
  local cap1=$!
  docker exec "$l1" sh -c "timeout 14 tcpdump -i ${LEG2_LAUNCHER_IF} -t -l -nn 'ip6 and ip6[6]=43' >${pcap2} 2>/dev/null" &
  local cap2=$!
  sleep 2
  docker exec "$cl" sh -c "ping -c 6 -i 1 -W 2 $peer_ip >/dev/null 2>&1" || true
  wait $cap1 2>/dev/null || true
  wait $cap2 2>/dev/null || true
  # grep -c prints 0 AND exits 1 on an empty capture — the DESIRED outcome on
  # the alternate leg — so a `|| echo 0` fallback would append a second 0 and
  # break the arithmetic test; keep only the count line (empty exec -> 0).
  n1=$(docker exec "$l1" sh -c "grep -c . ${pcap1} 2>/dev/null" 2>/dev/null | tail -1)
  n2=$(docker exec "$l1" sh -c "grep -c . ${pcap2} 2>/dev/null" 2>/dev/null | tail -1)
  n1=${n1:-0}; n2=${n2:-0}
  docker exec "$l1" sh -c "rm -f ${pcap1} ${pcap2}" >/dev/null 2>&1 || true
  echo "--- ${LEG1_LAUNCHER_IF} (${PREF_SPINE} leg) SRH packets: ${n1:-0}; ${LEG2_LAUNCHER_IF} (${ALT_SPINE} leg): ${n2:-0}"
  [[ "${n1:-0}" -gt 0 ]] || die "wire witness: no SRH packets on the preferred ${PREF_SPINE} leg"
  [[ "${n2:-0}" -eq 0 ]] || die "wire witness: SRH packets on the alternate ${ALT_SPINE} leg (service not pinned)"
  ok "observe: service traffic rides ${PREF_SPINE} (${LEG1_LAUNCHER_IF} nonzero, ${LEG2_LAUNCHER_IF} zero)"
}

run_probe_window() { # shared by fail-preferred / restore-preferred
  local name=$1 want_spine=$2 cl peer_ip probe
  facts_of "$name"
  cl=$(client_of "$INGRESS")
  peer_ip=$(client_ip "$(client_of "$PEER")")
  preflight "$INGRESS" "$peer_ip" "the failover window"
  echo "--- 1 Hz probe window (${PROBE_COUNT} probes), switching the pin after ${SWITCH_AT_PROBE}s"
  probe_window "$cl" "$peer_ip" /tmp/sf-failover.ping &
  probe=$!
  sleep "$SWITCH_AT_PROBE"
  flip_pin "$INGRESS" "$PEER_FN" "$want_spine"
  wait $probe 2>/dev/null || true
  assert_post_switch_bound "$cl" /tmp/sf-failover.ping
  docker exec "$cl" sh -c "rm -f /tmp/sf-failover.ping" >/dev/null 2>&1 || true
}

cmd_fail_preferred() { # --fail-preferred: the §3.2 failure action
  local name=$1
  facts_of "$name" # ALT_SPINE is read below, before run_probe_window sets it
  run_probe_window "$name" "$ALT_SPINE"
  echo "--- awaiting status.activePath (the controller's §5 resync re-verifies every 5 min)"
  await_active_path "$name" "$ALT_SPINE"
  # The controller must treat the switch as FAILOVER, not drift: the service
  # stays Ready on the alternate path (FR-026).
  await_ready "$name" "True" "60"
  ok "fail-preferred: service switched to ${ALT_SPINE}, loss within the FR-026a bound, Ready held"
}

cmd_restore_preferred() { # --restore-preferred: the rollback to preferred
  local name=$1
  facts_of "$name" # PREF_SPINE is read below, before run_probe_window sets it
  run_probe_window "$name" "$PREF_SPINE"
  echo "--- awaiting status.activePath (the controller's §5 resync re-verifies every 5 min)"
  await_active_path "$name" "$PREF_SPINE"
  await_ready "$name" "True" "60"
  ok "restore-preferred: service back on ${PREF_SPINE}, loss within the FR-026a bound, Ready held"
}

cmd_fail_both() { # --fail-both: neither path usable -> PathDown
  local name=$1 c line s via port rm msg want
  facts_of "$name"
  c=$(container_of "$INGRESS")
  s=$(node_sudo "$c")
  echo "--- deleting the pin on $INGRESS (both paths down)"
  line=$(current_pin "$INGRESS" "$PEER_FN")
  [[ -n "$line" ]] || die "$INGRESS: no pin for $PEER_FN"
  node_run "$c" "${s} ip -6 route del ${line}" || die "pin delete failed"
  echo "--- awaiting Ready=False PathDown (the controller's §5 resync re-verifies every 5 min)"
  await_ready "$name" "False" "$((AWAIT_ACTIVE_PATH_TIMEOUT + 60))"
  rm=$(ready_reason_msg "$name")
  echo "--- Ready reason|message: ${rm%%|*} | ${rm#*|}"
  [[ "${rm%%|*}" == "PathDown" ]] || die "Ready reason is '${rm%%|*}', want PathDown"
  msg=${rm#*|}
  want="path down on node ${INGRESS}"
  [[ "$msg" == *"$want"* ]] || die "PathDown message does not name the node ($want): $msg"
  want="no route to ${PEER_FN} via ${PREF_SPINE}"
  [[ "$msg" == *"$want"* ]] || die "PathDown message does not name the preferred leg ($want): $msg"
  want="no route to ${PEER_FN} via ${ALT_SPINE}"
  [[ "$msg" == *"$want"* ]] || die "PathDown message does not name the alternate leg ($want): $msg"
  # Self-restoring: put the pin back the way the controller holds it.
  echo "--- restoring the preferred pin (self-restore)"
  read -r via port < <(leg_of "$INGRESS" "$PREF_SPINE") || die "no $PREF_SPINE leg on $INGRESS"
  node_run "$c" "${s} ip -6 route replace ${PEER_FN} from :: via ${via} dev ${port} metric 20" ||
    die "restore failed"
  await_ready "$name" "True" "180"
  ok "fail-both: PathDown named the missing path; service restored to ${PREF_SPINE}"
}

cmd_assert_alert() { # US8 adds this proof; US5 refuses to fake it.
  echo "FAIL: --assert-alert is US8's proof (SRv6PathDown alert via the Prometheus API) and is deliberately not implemented in US5" >&2
  exit 3
}

SKIP_LIVE() {
  echo "SKIP-LIVE: $1 requires a provisioned lab and Kind cluster; capability gate (scripts/lib/qualify.sh) is the source of truth"
  exit 0
}

require_live() {
  local mode=$1
  docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${LAB}-leaf01$" || SKIP_LIVE "$mode"
  kubectl --context "$CTX" -n "$NS" get srv6service --request-timeout=5s >/dev/null 2>&1 || SKIP_LIVE "$mode"
}

mode=${1:-}
name=${2:-}
case "$mode" in
  --observe|--fail-preferred|--restore-preferred|--fail-both|--assert-alert)
    [[ -n "$name" ]] || { echo "usage: $0 <mode> <srv6service-name>" >&2; exit 2; }
    require_live "$mode"
    ;;
  *) echo "usage: $0 --observe|--fail-preferred|--restore-preferred|--fail-both|--assert-alert <srv6service-name>" >&2; exit 2 ;;
esac

case "$mode" in
  --observe) cmd_observe "$name" ;;
  --fail-preferred) cmd_fail_preferred "$name" ;;
  --restore-preferred) cmd_restore_preferred "$name" ;;
  --fail-both) cmd_fail_both "$name" ;;
  --assert-alert) cmd_assert_alert ;;
esac
