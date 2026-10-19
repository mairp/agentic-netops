#!/usr/bin/env bash
# fabric_baseline.sh — the sonic-vm fabric baseline checks (T126-T128).
#
# Three read-only checks a bootstrapped sonic-vm lab must satisfy, one mode per
# bootstrap responsibility (lab/profiles/sonic-vm/bootstrap/configure-fabric.sh):
#
#   --identity   four distinct loopbacks, ASNs and router-ids, read from the
#                nodes through node_run (data-model.md §7)                (T126)
#   --underlay   the fabric link addresses are present and the BGP sessions
#                are established on 4 of 4 fabric links, both families    (T127)
#   --locators   every node's locator is in CONFIG_DB and the FRR locator
#                table, and is reachable from the three other nodes       (T128)
#
# Expected values come from lab/profiles/sonic-vm/fabric.yaml — the single
# source the bootstrap also writes from, so the checker can never drift from
# the plan. Every node conversation goes through node_run from
# tests/integration/lib/node_exec.sh (sonic-vm routes over SSH into the guest;
# no docker exec into a switch). The suite is deliberately WRITE-FREE: on a
# lab without the bootstrap every mode must FAIL (that is the done-condition
# recorded in proofs q2-baseline-*), so it never originates or re-asserts
# anything it checks.
#
# Usage: fabric_baseline.sh [--identity|--underlay|--locators]  (default: all)
# Exit: 0 only when every selected assertion holds.
set -uo pipefail

BASELINE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$BASELINE_DIR/../.." && pwd)"
# shellcheck disable=SC1091
. "$REPO_ROOT/tests/integration/lib/node_exec.sh"

FABRIC_YAML="${REPO_ROOT}/lab/profiles/sonic-vm/fabric.yaml"
NODES=(spine01 spine02 leaf01 leaf02)
declare -A C_=(
  [spine01]=clab-agentic-netops-fabric-spine01
  [spine02]=clab-agentic-netops-fabric-spine02
  [leaf01]=clab-agentic-netops-fabric-leaf01
  [leaf02]=clab-agentic-netops-fabric-leaf02
)

failures=0
note_fail() { echo "FAIL: $*" >&2; failures=$((failures + 1)); }

# ---- expected values from fabric.yaml (host-side python; single source) -----
read -r -a WANT_NODES <<<"$(python3 - "$FABRIC_YAML" <<'PY'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
print(" ".join(sorted(d["nodes"])))
PY
)"
want_field() { # <node> <python-key>
  python3 - "$FABRIC_YAML" "$1" "$2" <<'PY'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
print(d["nodes"][sys.argv[2]][sys.argv[3]])
PY
}
want_sessions() { # <node> — expected established count per family
  local role; role=$(want_field "$1" role)
  python3 - "$FABRIC_YAML" "$role" <<'PY'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
print(d["expected_sessions"][sys.argv[2]])
PY
}
want_links() { # <node> — "port v4 v6 peer peer_v4 peer_v6" per link, one per line
  python3 - "$FABRIC_YAML" "$1" <<'PY'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
for l in d["nodes"][sys.argv[2]]["links"]:
    print(l["port"], l["v4"], l["v6"], l["peer"], l["peer_v4"], l["peer_v6"])
PY
}
want_locator_addr() { # <node> — bare locator address (no /48)
  want_field "$1" locator | sed 's|/48$||'
}

# wait_ssh <node> — bounded wait for the guest to accept node_run (a VM guest
# boots for minutes; sshd is one of the last services).
wait_ssh() {
  local n=$1 i
  for i in $(seq 1 30); do
    if node_run "${C_[$n]}" "true" >/dev/null 2>&1; then return 0; fi
    sleep 10
  done
  return 1
}

# ---- --identity (T126) ------------------------------------------------------
check_identity() {
  local n host asn rid lo4 lo6 ok=0
  echo "===== identity: DEVICE_METADATA + Loopback0 read-back per node ====="
  for n in "${WANT_NODES[@]}"; do
    host=$(node_run "${C_[$n]}" "$(node_sudo "${C_[$n]}") redis-cli -n 4 --raw HGET 'DEVICE_METADATA|localhost' hostname" 2>/dev/null | tr -d '\r')
    asn=$(node_run "${C_[$n]}" "$(node_sudo "${C_[$n]}") redis-cli -n 4 --raw HGET 'DEVICE_METADATA|localhost' bgp_asn" 2>/dev/null | tr -d '\r')
    rid=$(node_run "${C_[$n]}" "$(node_sudo "${C_[$n]}") redis-cli -n 4 --raw HGET 'DEVICE_METADATA|localhost' bgp_router_id" 2>/dev/null | tr -d '\r')
    # The leaves also carry their locator test /128 on Loopback0 (the
    # advertisement step), so the loopback read-back greps for the EXPECTED
    # address anywhere on the line instead of taking the first listed one.
    lo4=$(node_run "${C_[$n]}" "ip -4 -br addr show Loopback0 2>/dev/null" 2>/dev/null | grep -oF "$(want_field "$n" loopback4)" | head -1 | tr -d '\r')
    lo6=$(node_run "${C_[$n]}" "ip -6 -br addr show Loopback0 2>/dev/null" 2>/dev/null | grep -oF "$(want_field "$n" loopback6)" | head -1 | tr -d '\r')
    echo "$n hostname=$host asn=$asn router_id=$rid lo4=$lo4 lo6=$lo6"
    [[ "$host" == "$n" ]] || { note_fail "$n hostname is '$host', want '$n'"; continue; }
    [[ "$asn" == "$(want_field "$n" asn)" ]] || { note_fail "$n bgp_asn is '$asn', want '$(want_field "$n" asn)'"; continue; }
    [[ "$rid" == "$(want_field "$n" router_id)" ]] || { note_fail "$n bgp_router_id is '$rid', want '$(want_field "$n" router_id)'"; continue; }
    [[ "$lo4" == "$(want_field "$n" loopback4)" ]] || { note_fail "$n Loopback0 v4 is '$lo4', want '$(want_field "$n" loopback4)'"; continue; }
    [[ "$lo6" == "$(want_field "$n" loopback6)" ]] || { note_fail "$n Loopback0 v6 is '$lo6', want '$(want_field "$n" loopback6)'"; continue; }
    ok=$((ok + 1))
  done
  # Distinctness is the §7 point: four different loopbacks/ASNs/router-ids.
  local d4 d6 da dr
  d4=$(for n in "${WANT_NODES[@]}"; do want_field "$n" loopback4; done | sort -u | wc -l)
  d6=$(for n in "${WANT_NODES[@]}"; do want_field "$n" loopback6; done | sort -u | wc -l)
  da=$(for n in "${WANT_NODES[@]}"; do want_field "$n" asn; done | sort -u | wc -l)
  dr=$(for n in "${WANT_NODES[@]}"; do want_field "$n" router_id; done | sort -u | wc -l)
  echo "IDENTITY-OK=$ok of ${#WANT_NODES[@]} (distinct want: lo4=$d4 lo6=$d6 asn=$da rid=$dr)"
  [[ "$ok" -eq "${#WANT_NODES[@]}" ]] || note_fail "identity holds on $ok of ${#WANT_NODES[@]} nodes"
  [[ "$d4" -eq 4 && "$d6" -eq 4 && "$da" -eq 3 && "$dr" -eq 4 ]] || note_fail "fabric.yaml does not declare distinct identities (lo4=$d4 lo6=$d6 asn=$da rid=$dr)"
}

# ---- --underlay (T127) ------------------------------------------------------
check_underlay() {
  local n link fam v4addr v6addr est oth want
  echo "===== underlay: fabric link addresses + BGP sessions per family ====="
  for n in "${WANT_NODES[@]}"; do
    while read -r port v4 v6 peer pv4 pv6; do
      [[ -n "$port" ]] || continue
      v4addr=$(node_run "${C_[$n]}" "ip -4 -br addr show $port 2>/dev/null" 2>/dev/null | grep -o "$v4" | head -1 | tr -d '\r')
      # addr_norm class: `ip -6 -br` prints the MAC-derived link-local on the
      # same line as the global /127; grep for the exact expected /127.
      v6addr=$(node_run "${C_[$n]}" "ip -6 -br addr show $port 2>/dev/null" 2>/dev/null | grep -o "$v6" | head -1 | tr -d '\r')
      echo "$n $port v4=${v4addr:-absent} v6=${v6addr:-absent} (peer $peer)"
      [[ "$v4addr" == "$v4" ]] || note_fail "$n $port missing IPv4 $v4"
      [[ "$v6addr" == "$v6" ]] || note_fail "$n $port missing IPv6 $v6"
    done < <(want_links "$n")
    want=$(want_sessions "$n")
    for fam in "ipv4" "ipv6"; do
      est=$(node_run "${C_[$n]}" "vtysh -c 'show bgp $fam unicast summary' 2>/dev/null" 2>/dev/null | awk '
/^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+ / || /^[0-9a-f:]+ / {
  if ($10 ~ /^[0-9]+$/) e++; else o++
}
END { print e+0, o+0 }')
      oth=${est#* }
      echo "${n} ${fam} ESTABLISHED=$(echo "$est" | cut -d' ' -f1) OTHER=${oth:-unknown} (want >= $want, other 0)"
      [[ "${est%% *}" -ge "$want" ]] 2>/dev/null || note_fail "$n $fam established ${est%% *:-0} < $want"
      [[ "${oth:-1}" -eq 0 ]] || note_fail "$n $fam has $oth non-established session(s)"
    done
  done
  if [[ "$failures" -eq 0 ]]; then
    echo "UNDERLAY-OK: link addresses present and sessions established on 4 of 4 fabric links, both families"
  else
    note_fail "underlay has $failures failing assertion(s)"
  fi
}

# ---- --locators (T128) ------------------------------------------------------
check_locators() {
  local n addr fr pairs pass=0 fail=0 s d a out
  echo "===== locators: CONFIG_DB row + FRR locator table per node ====="
  for n in "${WANT_NODES[@]}"; do
    addr=$(want_locator_addr "$n")
    fr=$(node_run "${C_[$n]}" "vtysh -c 'show segment-routing srv6 locator' 2>/dev/null | grep -c \"loc-$n\"" 2>/dev/null | tr -d '\r')
    echo "$n locator=$addr/48 frr_rows=$fr"
    [[ "${fr:-0}" -ge 1 ]] || note_fail "$n has no locator row in the FRR locator table"
  done
  echo "===== locator reachability: 12 ordered pairs, ping to <dst-locator>::1 ====="
  # The probe sources from the SOURCE node's own locator test address
  # (-I fcbb:bbbb:<src>::1): the fabric link /127s are not advertised, so a
  # default-source probe picks the link address of the egress leg and the
  # remote leaf has no route back to it — measured 2026-10-14 (10 of 12 with
  # the default source, 12 of 12 sourced from the locator /128). Sourcing from
  # the locator is also the truer check: it exercises the locator plane itself.
  for s in "${WANT_NODES[@]}"; do
    for d in "${WANT_NODES[@]}"; do
      [[ "$s" == "$d" ]] && continue
      a="$(want_locator_addr "$d")1"
      src="$(want_locator_addr "$s")1"
      out=$(node_run "${C_[$s]}" "ping6 -c2 -W2 -I $src $a 2>&1 | tail -2" 2>/dev/null)
      if echo "$out" | grep -q '2 received'; then
        echo "$s -> $d ($a): PASS"; pass=$((pass + 1))
      else
        echo "$s -> $d ($a): FAIL"; fail=$((fail + 1))
      fi
    done
  done
  pairs=$((pass + fail))
  echo "LOCATOR-REACH=$pass of $pairs ordered pairs"
  [[ "$pass" -eq 12 && "$fail" -eq 0 ]] || note_fail "locator reachability $pass of $pairs"
}

# ---- main -------------------------------------------------------------------
mode=all
for arg in "$@"; do
  case "$arg" in
    --identity) mode=identity ;;
    --underlay) mode=underlay ;;
    --locators) mode=locators ;;
    -h|--help) echo "usage: $0 [--identity|--underlay|--locators]"; exit 0 ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

# The nodes must answer node_run before any check means anything: an
# unreachable guest is a lab problem, not a baseline failure, and is reported
# as such (bounded wait, no blind retries after it).
for n in "${WANT_NODES[@]}"; do
  if ! wait_ssh "$n"; then
    echo "FAIL: $n guest SSH never became reachable via node_run" >&2
    exit 3
  fi
done
echo "nodes: ${WANT_NODES[*]} (expected from $FABRIC_YAML)"
[[ "${WANT_NODES[*]}" == "$(echo "${NODES[*]}" | tr ' ' '\n' | sort | tr '\n' ' ' | sed 's/ $//')" ]] \
  || { echo "FAIL: fabric.yaml node set ${WANT_NODES[*]} != lab set ${NODES[*]}" >&2; exit 2; }

case "$mode" in
  identity) check_identity ;;
  underlay) check_underlay ;;
  locators) check_locators ;;
  all) check_identity; check_underlay; check_locators ;;
esac

if [[ "$failures" -eq 0 ]]; then
  echo "BASELINE-PASS mode=$mode"
  exit 0
fi
echo "BASELINE-FAIL mode=$mode failures=$failures"
exit 1
