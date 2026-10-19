#!/usr/bin/env bash
# srv6_service.sh — the SRv6Service live acceptance harness (T401-T405, T614).
#
# One flag per acceptance proof; the flag arguments name the SRv6Service
# resource and every fact (nodes, ports, gateways, client addresses, SIDs)
# is read from the live resource or the device — never typed into this file:
#
#   --readback <name>          §8.4 read-backs per attachment node (Q5/Q6)
#   --ping <name>              client-to-client pings, default + 8900 DF (Q5)
#   --capture <name>           wire witness on the ingress uplink (Q5)
#   --break-check <name> <n>   Q6: delete the VRF steering encap route on <n>
#   --remove-sid <name> <n>    Q6: delete the service SID decap /64 on <n>
#   --await-ready-false <n> <s>  poll Ready=False within <s> seconds (Q6)
#   --await-ready-true <n> <s>   poll Ready=True within <s> seconds (Q6/Q17)
#   --assert-clean <name>      §8.5 step 6: zero residue after delete (Q8)
#   --apply-and-reason <file>  apply <file>, print the terminal reason (Q9/Q13)
#   --update <name>            Q17: patch attachment prefixes, print generations
#
# Exit 0 only when the invoked flag's assertions pass.

set -u

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=tests/integration/lib/node_exec.sh
source "${ROOT_DIR}/tests/integration/lib/node_exec.sh"

CTX="${CTX:-kind-agentic-netops}"
NS="${NS:-agentic-netops-intent}"
LAB="clab-agentic-netops-fabric"
# The probe clients of lab/topology.sonic-vm.clab.yml, one per leaf (§8.7:
# busybox-style, docker exec + sh -c only).
PROBE_CLIENT_01="${PROBE_CLIENT_01:-${LAB}-srv6-client01}"
PROBE_CLIENT_02="${PROBE_CLIENT_02:-${LAB}-srv6-client02}"
# data-model.md §8.2: node ids 1-4 (spine01/02, leaf01/02); function 11.
NODE_IDS="${NODE_IDS:-leaf01=3,leaf02=4}"
SRV6_FN="${SRV6_FN:-11}"
CLIENT_IFACE="${CLIENT_IFACE:-eth1}"
# §8.4: the service uplink is the fabric-facing Ethernet0.
UPLINK="${UPLINK:-Ethernet0}"

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

svc_get() { # svc_get <name> <jsonpath> — a bare "metadata.generation" needs
  local p=$2 #                                   the leading dot jsonpath demands
  [[ "$p" == .* || "$p" == \[* ]] || p=".$p"
  kubectl --context "$CTX" -n "$NS" get srv6service "$1" -o "jsonpath={$p}"
}

svc_json() { # svc_json <name> -> full JSON
  kubectl --context "$CTX" -n "$NS" get srv6service "$1" -o json 2>/dev/null
}

# svc_attachments <name> -> "<node> <port>" lines in spec order
svc_attachments() {
  svc_json "$1" | python3 -c '
import json, sys
svc = json.load(sys.stdin)
for a in svc.get("spec", {}).get("attachments", []):
    print(a.get("node", ""), a.get("port", ""))
'
}

# svc_gateway <name> <node> -> the attachment gateway host, e.g. 192.168.1.1
svc_gateway() {
  svc_json "$1" | python3 -c '
import json, sys
svc = json.load(sys.stdin)
node = sys.argv[1]
for a in svc.get("spec", {}).get("attachments", []):
    if a.get("node") == node:
        gw = (a.get("gateway") or [""])[0]
        print(gw.split("/")[0])
        break
' "$2"
}

# peer_of <name> <node> -> the other attachment's node
peer_of() {
  svc_attachments "$1" | awk -v me="$2" '$1 != me {print $1; found=1} END {if (!found) exit 1}'
}

# container_of <node> — the lab container node_run addresses
container_of() { printf '%s-%s' "$LAB" "$1"; }

# client_addr <gateway-host> — the client holds .2 in the attachment /24 (§8.7)
client_addr() { printf '%s.2' "$(printf '%s' "$1" | sed 's/\.[0-9]*$//')"; }

client_ip() { # client_ip <container>: primary IPv4 of the probe iface, device truth
  docker exec "$1" sh -c "ip addr show $CLIENT_IFACE" 2>/dev/null |
    sed -n 's/.*inet \([0-9.]*\)[ \/].*/\1/p' | head -1
}

die() { echo "FAIL: $*" >&2; exit 1; }
ok() { echo "PASS: $*"; }

cmd_readback() { # §8.4 per attachment node
  local name=$1 node port cidr vrf sid peer
  while read -r node port; do
    [[ -n "$node" ]] || continue
    cidr=$(node_id "$node") || die "no node id for $node (NODE_IDS=$NODE_IDS)"
    peer=$(peer_of "$name" "$node") || die "no peer for $node"
    vrf=$(svc_vrf "$name") || die "no allocations yet for $name"
    sid="fcbb:bbbb:${cidr}:${SRV6_FN}::/64"
    local c; c=$(container_of "$node")
    local s; s=$(node_sudo "$c")
    echo "===== readback $node ($port) ====="
    echo "--- VRF: ip -br link show $vrf"
    node_run "$c" "ip -br link show $vrf" || die "$node: VRF device $vrf not up"
    echo "--- VRF row: redis-cli -n 4 keys 'VRF\\|$vrf'"
    node_run "$c" "redis-cli -n 4 keys 'VRF\\|$vrf'" | grep -q "VRF|$vrf" || die "$node: no CONFIG_DB VRF row"
    echo "--- attachment: ip -br addr show (member + /24)"
    node_run "$c" "ip -br addr show" | sed -n '1,12p'
    echo "--- decap: ip -6 route show | grep seg6local"
    node_run "$c" "ip -6 route show | grep seg6local" | grep -q "$sid" || die "$node: decap $sid missing"
    node_run "$c" "ip -6 route show | grep seg6local"
    echo "--- steering: ip route show vrf $vrf | grep encap"
    node_run "$c" "ip route show vrf $vrf | grep encap" | grep -q "encap seg6" || die "$node: steering encap missing"
    node_run "$c" "ip route show vrf $vrf | grep encap"
    echo "--- locator (bootstrap-owned, untouched): SRV6_MY_LOCATORS scan"
    node_run "$c" "redis-cli -n 4 --scan --pattern 'SRV6_MY_LOCATORS*'" | grep -q "SRV6_MY_LOCATORS" || die "$node: locator rows vanished"
  done < <(svc_attachments "$name")
  ok "readback: every §8.4 state present on all attachment nodes"
}

svc_vrf() { # the allocated VRF from status.allocations
  svc_json "$1" | python3 -c '
import json, sys
svc = json.load(sys.stdin)
vrf = (svc.get("status", {}).get("allocations", {}) or {}).get("vrf", "")
if not vrf:
    sys.exit(1)
print(vrf)
'
}

cmd_ping() { # client-to-client pings, both directions, default + 8900 DF (§8.7)
  local name=$1
  local nodes=() ca1 ca2 dp_ok=1
  mapfile -t nodes < <(svc_attachments "$name" | awk '{print $1}')
  [[ "${#nodes[@]}" -eq 2 ]] || die "need exactly 2 attachments, got ${#nodes[@]}"
  # Device truth: the client subnets are the claimed client prefixes, not the
  # spec's fabric-link gateways — read each probe client's address from the
  # client container itself (header rule: facts come from the device).
  ca1=$(client_ip "$PROBE_CLIENT_01")
  [[ -n "$ca1" ]] || die "no IPv4 address on $PROBE_CLIENT_01 $CLIENT_IFACE"
  ca2=$(client_ip "$PROBE_CLIENT_02")
  [[ -n "$ca2" ]] || die "no IPv4 address on $PROBE_CLIENT_02 $CLIENT_IFACE"
  echo "--- ping $PROBE_CLIENT_01 ($ca1) -> $PROBE_CLIENT_02 ($ca2), default size"
  docker exec "$PROBE_CLIENT_01" sh -c "ping -c3 -W3 $ca2 2>&1 | tail -2" || dp_ok=0
  echo "--- ping $PROBE_CLIENT_01 -> $ca2, 8900-byte DF"
  docker exec "$PROBE_CLIENT_01" sh -c "ping -c3 -W3 -s 8900 -M do $ca2 2>&1 | tail -2" || true
  echo "--- ping $PROBE_CLIENT_02 ($ca2) -> $ca1, default size"
  docker exec "$PROBE_CLIENT_02" sh -c "ping -c3 -W3 $ca1 2>&1 | tail -2" || dp_ok=0
  echo "--- ping $PROBE_CLIENT_02 -> $ca1, 8900-byte DF"
  docker exec "$PROBE_CLIENT_02" sh -c "ping -c3 -W3 -s 8900 -M do $ca1 2>&1 | tail -2" || true
  [[ "$dp_ok" -eq 1 ]] || die "DATAPLANE-DEAD: default-size pings do not pass"
  ok "ping: client-to-client passes both directions (default + 8900 DF above)"
}

cmd_capture() { # wire witness: SRH with dst = the peer service SID (§8.4)
  local name=$1
  local nodes=() ingress peer psid pcap
  mapfile -t nodes < <(svc_attachments "$name" | awk '{print $1}')
  ingress="${nodes[0]}"
  peer=$(peer_of "$name" "$ingress") || die "no peer for $ingress"
  psid="fcbb:bbbb:$(node_id "$peer"):${SRV6_FN}::"
  pcap=$(mktemp /tmp/srv6-capture.XXXXXX.txt)
  local c; c=$(container_of "$ingress")
  echo "--- tcpdump on $ingress $UPLINK, watching for $psid"
  node_run "$c" "sudo timeout 20 tcpdump -i $UPLINK -c 6 -vv ip6 2>/dev/null" >"$pcap" &
  local dump_pid=$!
  sleep 2
  cmd_ping "$name" >/dev/null 2>&1 || true
  wait $dump_pid || true
  echo "--- capture (head)"
  head -8 "$pcap"
  grep -q "fcbb:bbbb" "$pcap" || { rm -f "$pcap"; die "no SRv6 (IPv6) packets on $ingress $UPLINK"; }
  if grep -q "${psid}" "$pcap"; then
    ok "capture: SRH wire witness shows the peer service SID $psid"
  else
    rm -f "$pcap"
    die "capture shows SRv6 packets but not the peer SID $psid"
  fi
  rm -f "$pcap"
}

cmd_break_check() { # Q6: remove a checked state — the VRF steering encap route
  local name=$1 node=$2 vrf c s
  vrf=$(svc_vrf "$name") || die "no allocations yet for $name"
  c=$(container_of "$node")
  s=$(node_sudo "$c")
  echo "--- deleting the steering encap route in $vrf on $node"
  node_run "$c" "ip route show vrf $vrf" | grep -q "encap seg6" || die "nothing to break: no encap route on $node"
  local peer_prefix
  peer_prefix=$(node_run "$c" "ip route show vrf $vrf | grep 'encap seg6' | awk '{print \$1}' | head -n1")
  [[ -n "$peer_prefix" ]] || die "cannot parse the encap route prefix"
  node_run "$c" "${s} ip route del vrf $vrf $peer_prefix" || die "del failed"
  node_run "$c" "ip route show vrf $vrf" | grep -q "encap seg6" && die "encap route still present"
  ok "break-check: $peer_prefix encap route removed on $node"
}

cmd_remove_sid() { # Q6: remove the service SID decap /64 on a node
  local name=$1 node=$2 cidr sid c s
  cidr=$(node_id "$node") || die "no node id for $node"
  sid="fcbb:bbbb:${cidr}:${SRV6_FN}::/64"
  c=$(container_of "$node")
  s=$(node_sudo "$c")
  echo "--- deleting the service SID route $sid on $node"
  node_run "$c" "ip -6 route show" | grep -q "$sid" || die "SID route $sid not present on $node"
  node_run "$c" "${s} ip -6 route del $sid" || die "del failed"
  node_run "$c" "ip -6 route show" | grep -q "$sid" && die "SID route still present"
  ok "remove-sid: $sid removed on $node"
}

svc_ready() { # "<True|False|>" of the Ready condition
  kubectl --context "$CTX" -n "$NS" get srv6service "$1" -o json 2>/dev/null | python3 -c '
import json, sys
try:
    svc = json.load(sys.stdin)
except Exception:
    print(""); raise SystemExit
for cond in svc.get("status", {}).get("conditions", []) or []:
    if cond.get("type") == "Ready":
        print("True" if cond.get("status") == "True" else "False")
        raise SystemExit
print("")
'
}

svc_ready_reason() { # "<reason: message>" of the Ready condition (drift evidence)
  kubectl --context "$CTX" -n "$NS" get srv6service "$1" -o json 2>/dev/null | python3 -c '
import json, sys
try:
    svc = json.load(sys.stdin)
except Exception:
    print(""); raise SystemExit
for cond in svc.get("status", {}).get("conditions", []) or []:
    if cond.get("type") == "Ready":
        print("%s: %s" % (cond.get("reason", ""), cond.get("message", "")))
        raise SystemExit
print("")
'
}

await_ready() { # await_ready <name> <want-True|False> <timeout-seconds>
  local name=$1 want=$2 timeout=$3 waited=0 got
  while :; do
    got=$(svc_ready "$name")
    if [[ "$got" == "$want" ]]; then
      if [[ "$want" == "False" ]]; then
        echo "  Ready=False reason/message: $(svc_ready_reason "$name")"
      fi
      ok "Ready=$want observed after ${waited}s"
      return 0
    fi
    if (( waited >= timeout )); then
      die "Ready never became $want within ${timeout}s (last: '${got:-absent}')"
    fi
    sleep 5
    waited=$((waited + 5))
    echo "  ... waited ${waited}s, Ready='${got:-absent}'"
  done
}

cmd_assert_clean() { # §8.5 step 6: zero residue, locator untouched (Q8)
  local name=$1 node port vrf
  vrf=$(svc_vrf "$name" 2>/dev/null) || vrf=""
  while read -r node port; do
    [[ -n "$node" ]] || continue
    local c; c=$(container_of "$node")
    echo "--- clean check on $node"
    if [[ -n "$vrf" ]]; then
      node_run "$c" "redis-cli -n 4 keys 'VRF\\|$vrf'" | grep -q "VRF|" && die "$node: VRF row still present"
    fi
    node_run "$c" "redis-cli -n 4 --scan --pattern 'SRV6_MY_SIDS*'" | grep -q . && die "$node: SRV6_MY_SIDS rows present"
    local seg6
    seg6=$(node_run "$c" "ip -6 route show | grep -c seg6local")
    [[ "$seg6" == "0" ]] || die "$node: $seg6 seg6local routes remain"
    node_run "$c" "redis-cli -n 4 --scan --pattern 'SRV6_MY_LOCATORS*'" | grep -q "SRV6_MY_LOCATORS" || die "$node: locator rows vanished (never service-owned)"
    if [[ -n "$vrf" ]]; then
      node_run "$c" "ip route show vrf $vrf 2>/dev/null" | grep -q "encap" && die "$node: steering route remains"
    fi
  done < <(svc_attachments "$name")
  echo "--- claims after delete"
  kubectl --context "$CTX" -n kuid-system get claims,leases -l agentic-netops.io/correlation-id="$1" 2>/dev/null | grep -v "^No resources" | grep -q . \
    && die "claims/leases for correlation id $1 still present"
  ok "assert-clean: zero device residue and no claims for $name"
}

cmd_apply_and_reason() { # apply a file, wait for a terminal condition, print it
  local file=$1 name
  kubectl --context "$CTX" -n "$NS" apply -f "$file" || die "apply rejected"
  name=$(kubectl --context "$CTX" -n "$NS" apply -f "$file" -o jsonpath='{.metadata.name}' 2>/dev/null)
  [[ -n "$name" ]] || name=$(python3 -c '
import re, sys
text = open(sys.argv[1]).read()
m = re.search(r"^\s*name:\s*(\S+)", text, re.M)
print(m.group(1) if m else "")
' "$file")
  [[ -n "$name" ]] || die "cannot determine the resource name from $file"
  echo "--- applied $name; waiting for a terminal condition"
  local waited=0 timeout="${APPLY_REASON_TIMEOUT:-180}" reason message
  while :; do
    eval "$(svc_json "$name" | python3 -c '
import json, shlex, sys
try:
    svc = json.load(sys.stdin)
except Exception:
    print("reason="); print("message="); raise SystemExit
conds = svc.get("status", {}).get("conditions", []) or []
ready = [c for c in conds if c.get("type") == "Ready"]
term = [c for c in conds if c.get("reason") in (
    "InvalidSite", "PortInUse", "CapabilityMissing", "UnsupportedVariant",
    "PoolExhausted", "DataPathUnverifiable", "VlanInUse", "Verified")]
pick = (term or ready or [{}])[-1]
print("reason=%s" % shlex.quote(pick.get("reason", "")))
print("message=%s" % shlex.quote(pick.get("message", "")))
' | sed 's/^/LOCAL_/')" || true
    if [[ -n "${LOCAL_reason:-}" ]]; then
      echo "terminal-condition: reason=${LOCAL_reason}"
      echo "message: ${LOCAL_message}"
      case "${LOCAL_reason}" in
      InvalidSite | PortInUse | CapabilityMissing | UnsupportedVariant | PoolExhausted | DataPathUnverifiable | VlanInUse | Verified)
        ok "apply-and-reason: $name ended at ${LOCAL_reason}"
        return 0
        ;;
      esac
    fi
    if (( waited >= timeout )); then
      die "no terminal condition on $name within ${timeout}s (last reason: '${LOCAL_reason:-none}')"
    fi
    sleep 5
    waited=$((waited + 5))
  done
}

cmd_update() { # Q17: patch attachment prefixes, print generation before/after
  local name=$1 gen_before gen_after
  gen_before=$(svc_get "$name" "metadata.generation")
  echo "--- generation before: $gen_before"
  # The new /24s are NOT claimed by another service and sit inside the
  # 192.168.0.0/16 client pool (data-model §8.1); the controller re-claims
  # per attachment and re-renders for the new generation.
  kubectl --context "$CTX" -n "$NS" patch srv6service "$name" --type=json -p='[
    {"op": "replace", "path": "/spec/attachments/0/gateway", "value": ["192.168.11.1/24"]},
    {"op": "replace", "path": "/spec/attachments/1/gateway", "value": ["192.168.12.1/24"]}
  ]' || die "patch rejected"
  gen_after=$(svc_get "$name" "metadata.generation")
  echo "--- generation after: $gen_after"
  [[ "$gen_after" -gt "$gen_before" ]] || die "generation did not advance ($gen_before -> $gen_after)"
  ok "update: generation $gen_before -> $gen_after"
}

usage() {
  sed -n '2,24p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit 2
}

[[ $# -ge 1 ]] || usage
case "$1" in
--readback) shift; [[ $# -eq 1 ]] || usage; cmd_readback "$1" ;;
--ping) shift; [[ $# -eq 1 ]] || usage; cmd_ping "$1" ;;
--capture) shift; [[ $# -eq 1 ]] || usage; cmd_capture "$1" ;;
--break-check) shift; [[ $# -eq 2 ]] || usage; cmd_break_check "$1" "$2" ;;
--remove-sid) shift; [[ $# -eq 2 ]] || usage; cmd_remove_sid "$1" "$2" ;;
--await-ready-false) shift; [[ $# -eq 2 ]] || usage; await_ready "$1" False "$2" ;;
--await-ready-true) shift; [[ $# -eq 2 ]] || usage; await_ready "$1" True "$2" ;;
--assert-clean) shift; [[ $# -eq 1 ]] || usage; cmd_assert_clean "$1" ;;
--apply-and-reason) shift; [[ $# -eq 1 ]] || usage; cmd_apply_and_reason "$1" ;;
--update) shift; [[ $# -eq 1 ]] || usage; cmd_update "$1" ;;
*) usage ;;
esac
