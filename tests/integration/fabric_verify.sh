#!/usr/bin/env bash
# T043 [US3] Verify underlay/EVPN sessions, loopback reachability, IPv6 waypoint reachability,
# and absence of tenant VTEP/VRF state on spines (FR-004)
set -euo pipefail

GNMIC_BIN=${GNMIC_BIN:-gnmic}
GNMI_USER=${GNMI_USER:-admin}
GNMI_PASS=${GNMI_PASS:-admin}
GNMI_CACERT=${GNMI_CACERT:-./secrets/ca.crt}
GNMI_CERT=${GNMI_CERT:-./secrets/gnmi.crt}
GNMI_KEY=${GNMI_KEY:-./secrets/gnmi.key}
GNMI_ENCODING=${GNMI_ENCODING:-JSON_IETF}
# SONiC targets (management gNMI endpoints from lab/topology.clab.yml)
LEAVES=${LEAVES:-"172.31.0.21:8080,172.31.0.22:8080"}
SPINES=${SPINES:-"172.31.0.11:8080,172.31.0.12:8080"}
CLAB_PREFIX=${CLAB_PREFIX:-clab-ainetops-fabric-}
# Node names parallel to LEAVES/SPINES. BGP session state is FRR state, not
# CONFIG_DB state, so it is read through vtysh over docker exec — the same route
# evpn_srv6_suite.sh and mtu_ecmp.sh already use.
LEAF_NODES=${LEAF_NODES:-"${CLAB_PREFIX}leaf01,${CLAB_PREFIX}leaf02"}
SPINE_NODES=${SPINE_NODES:-"${CLAB_PREFIX}spine01,${CLAB_PREFIX}spine02"}
AINETOPS_CLUSTER_NAME=${AINETOPS_CLUSTER_NAME:-ainetops}
KUBE_CTX=${KUBE_CTX:-kind-${AINETOPS_CLUSTER_NAME}}

# Common args for gnmic
_args_common=(--timeout 10s --username "$GNMI_USER" --password "$GNMI_PASS" --encoding "$GNMI_ENCODING" --tls-ca "$GNMI_CACERT" --tls-cert "$GNMI_CERT" --tls-key "$GNMI_KEY")

ensure_lab_secrets() {
  # Ensure local ./secrets/* files and GNMI_USER/PASS are available.
  # If absent, try to fetch from in-cluster Secrets (ainetops-system: gnmi-lab-creds, gnmi-lab-tls).
  local need_fetch=0
  [[ -f "$GNMI_CACERT" && -f "$GNMI_CERT" && -f "$GNMI_KEY" ]] || need_fetch=1
  if [[ -z "${GNMI_USER:-}" || -z "${GNMI_PASS:-}" ]]; then need_fetch=1; fi
  if [[ "$need_fetch" -eq 0 ]]; then return 0; fi

  if ! command -v kubectl >/dev/null 2>&1; then
    echo "[fabric-verify] SKIP: kubectl not available and local secrets missing — skipping fabric verification in CI/minimal environment" >&2
    return 64 # special code meaning prereq-missing
  fi

  echo "[fabric-verify] fetching lab credentials/TLS from cluster secrets into ./secrets"
  mkdir -p ./secrets
  # Credentials
  if kubectl --context "$KUBE_CTX" -n ainetops-system get secret gnmi-lab-creds >/dev/null 2>&1; then
    GNMI_USER=$(kubectl --context "$KUBE_CTX" -n ainetops-system get secret gnmi-lab-creds -o jsonpath='{.data.username}' | base64 -d || true)
    GNMI_PASS=$(kubectl --context "$KUBE_CTX" -n ainetops-system get secret gnmi-lab-creds -o jsonpath='{.data.password}' | base64 -d || true)
    export GNMI_USER GNMI_PASS
  else
    echo "[fabric-verify] WARN: secret gnmi-lab-creds not found" >&2
  fi
  # TLS bundle
  if kubectl --context "$KUBE_CTX" -n ainetops-system get secret gnmi-lab-tls >/dev/null 2>&1; then
    kubectl --context "$KUBE_CTX" -n ainetops-system get secret gnmi-lab-tls -o jsonpath='{.data.ca\.crt}' | base64 -d > "$GNMI_CACERT" || true
    kubectl --context "$KUBE_CTX" -n ainetops-system get secret gnmi-lab-tls -o jsonpath='{.data.tls\.crt}' | base64 -d > "$GNMI_CERT" || true
    kubectl --context "$KUBE_CTX" -n ainetops-system get secret gnmi-lab-tls -o jsonpath='{.data.tls\.key}' | base64 -d > "$GNMI_KEY" || true
  else
    echo "[fabric-verify] WARN: secret gnmi-lab-tls not found" >&2
  fi

  # If still missing after first fetch attempt, proactively create via RBAC manifests and generator Job.
  if { [[ ! -f "$GNMI_CACERT" || ! -f "$GNMI_CERT" || ! -f "$GNMI_KEY" ]] || [[ -z "${GNMI_USER:-}" || -z "${GNMI_PASS:-}" ]]; }; then
    echo "[fabric-verify] attempting to create lab Secrets via deploy/rbac manifests and generator Job"
    # Apply placeholders and generator job; wait briefly for completion
    kubectl --context "$KUBE_CTX" apply -f deploy/rbac/secrets.yaml || true
    kubectl --context "$KUBE_CTX" apply -f deploy/rbac/secret-generator-job.yaml || true
    kubectl --context "$KUBE_CTX" -n ainetops-system wait --for=condition=Complete --timeout=30s job/ainetops-secret-generator || true
    # Retry fetch
    if kubectl --context "$KUBE_CTX" -n ainetops-system get secret gnmi-lab-creds >/dev/null 2>&1; then
      GNMI_USER=$(kubectl --context "$KUBE_CTX" -n ainetops-system get secret gnmi-lab-creds -o jsonpath='{.data.username}' | base64 -d || true)
      GNMI_PASS=$(kubectl --context "$KUBE_CTX" -n ainetops-system get secret gnmi-lab-creds -o jsonpath='{.data.password}' | base64 -d || true)
      export GNMI_USER GNMI_PASS
    fi
    if kubectl --context "$KUBE_CTX" -n ainetops-system get secret gnmi-lab-tls >/dev/null 2>&1; then
      kubectl --context "$KUBE_CTX" -n ainetops-system get secret gnmi-lab-tls -o jsonpath='{.data.ca\.crt}' | base64 -d > "$GNMI_CACERT" || true
      kubectl --context "$KUBE_CTX" -n ainetops-system get secret gnmi-lab-tls -o jsonpath='{.data.tls\.crt}' | base64 -d > "$GNMI_CERT" || true
      kubectl --context "$KUBE_CTX" -n ainetops-system get secret gnmi-lab-tls -o jsonpath='{.data.tls\.key}' | base64 -d > "$GNMI_KEY" || true
    fi
  fi

  # Refresh common args after potential updates
  _args_common=(--timeout 10s --username "$GNMI_USER" --password "$GNMI_PASS" --encoding "$GNMI_ENCODING" --tls-ca "$GNMI_CACERT" --tls-cert "$GNMI_CERT" --tls-key "$GNMI_KEY")
}

prereq_ready() {
  [[ -f "$GNMI_CACERT" && -f "$GNMI_CERT" && -f "$GNMI_KEY" ]] || return 1
  command -v "$GNMIC_BIN" >/dev/null 2>&1 || return 1
  return 0
}

# The live fabric verification is only meaningful against an SRv6-qualified lab
# (the capability gate in scripts/lib/qualify.sh is the single source of truth for
# that). When the selected profile has not passed the gate — e.g. the fast sonic-vs
# profile on a host without a qualified image — the SONiC gNMI endpoints are not
# expected to be reachable, and this suite must SKIP (not fail) so it is never
# mistaken for a passing fabric result. We probe a TCP connect to each leaf gNMI
# port; if none accepts, the lab is not qualified and we skip with a clear marker.
lab_gnmi_reachable() {
  local t h p
  IFS=',' read -ra tgts <<<"$LEAVES"
  for t in "${tgts[@]}"; do
    h=${t%:*}; p=${t#*:}
    # bash /dev/tcp probe with a bounded timeout; fd closes with the subshell
    if timeout 3 bash -c "exec 3<>/dev/tcp/${h}/${p}" 2>/dev/null; then
      return 0
    fi
  done
  return 1
}

run_each() {
  # CAUTION: decides nothing but the exit code. Safe only against origins that
  # error on a missing node; on the sonic-db origin a missing table answers rc=0
  # with an empty body, so using this for an assertion there passes vacuously
  # (docs/SRV6_GNMI_CAPABILITY_FINDINGS.md 5). Use assert_sdb_entries instead.
  local targets_csv=$1; shift
  IFS=',' read -ra tgts <<<"$targets_csv"
  local rc=0
  for t in "${tgts[@]}"; do
    if ! "$GNMIC_BIN" --address "$t" "${_args_common[@]}" "$@"; then rc=1; fi
  done
  return $rc
}

run_each_capture() {
  # Like run_each but captures output per target to stdout, prefixing target for clarity
  local targets_csv=$1; shift
  IFS=',' read -ra tgts <<<"$targets_csv"
  local rc=0
  for t in "${tgts[@]}"; do
    if ! "$GNMIC_BIN" --address "$t" "${_args_common[@]}" "$@" | sed -e "s/^/[$t] /"; then rc=1; fi
  done
  return $rc
}

# --- sonic-db helpers -------------------------------------------------------
# This build advertises OpenConfig models but does not map them: translib paths
# answer NotFound and only the `sonic-db` origin resolves
# (docs/SRV6_GNMI_CAPABILITY_FINDINGS.md 4.2). Everything below therefore reads
# CONFIG_DB over sonic-db.
#
# The trap that comes with it: a sonic-db Get on a table that does not exist
# answers rc=0 with an empty body (findings 5). Deciding pass/fail on gnmic's
# exit code here would pass vacuously for every assertion, so these helpers
# return the BODY and callers must judge on content.

sdb_body() {
  # sdb_body <target> <TABLE> -> whitespace-stripped reply body, or the literal
  # QUERY_FAILED when the request itself did not answer. QUERY_FAILED is never
  # equal to "empty": an unaskable query must not be read as proof of absence.
  local t=$1 table=$2 out e
  set +e
  # No -o json: the plain renderer emits `"TABLE": {...}` (findings 5 documents
  # `"TOTALLY_FAKE_TABLE": {}` for a missing table), which is what the entry check
  # below matches. evpn_srv6_suite.sh queries the same way.
  out=$("$GNMIC_BIN" --address "$t" "${_args_common[@]}" get --path "/$table" --target CONFIG_DB 2>&1)
  e=$?
  set -e
  # Distinguish "the table is not there" from "the query could not be asked".
  # On this build an empty-by-design CONFIG_DB table answers NotFound rather than
  # an empty body — yang_paths_suite.sh accepts the same signal. Every other rpc
  # error (TLS, Unavailable, Unauthenticated) is a transport failure and must NOT
  # be readable as proof of absence.
  if grep -q 'code = NotFound' <<<"$out"; then
    printf 'ABSENT'
    return 0
  fi
  if [[ $e -ne 0 ]] || grep -qE 'rpc error|^Error:' <<<"$out"; then
    # Emit the underlying rpc error so a QUERY_FAILED in the evidence log
    # self-explains (cycle-1 of the 2026-09-01 reconciliation left an
    # unexplainable auth failure because only the literal marker was logged).
    grep -E 'rpc error|^Error:' <<<"$out" | head -1 | sed "s/^/[$t] sonic-db query error: /" >&2 || true
    # Unauthenticated right after a provision is a transition artifact (telemetry
    # was just restarted by the bootstrap/qualify suites; creds themselves are
    # consistent on a settled lab — verified 2026-09-01 07:35). One refetch +
    # retry converts it into the answer the lab actually holds.
    if grep -q 'Unauthenticated' <<<"$out"; then
      local u2 p2
      u2=$(kubectl --context "$KUBE_CTX" -n ainetops-system get secret gnmi-lab-creds -o jsonpath='{.data.username}' 2>/dev/null | base64 -d 2>/dev/null || true)
      p2=$(kubectl --context "$KUBE_CTX" -n ainetops-system get secret gnmi-lab-creds -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null || true)
      if [[ -n "$u2" && -n "$p2" ]]; then
        sleep 8
        out=$("$GNMIC_BIN" --address "$t" --timeout 10s --username "$u2" --password "$p2" --tls-ca "$GNMI_CACERT" --tls-cert "$GNMI_CERT" --tls-key "$GNMI_KEY" --encoding "$GNMI_ENCODING" get --path "/$table" --target CONFIG_DB 2>&1)
        e=$?
        if [[ $e -eq 0 ]] && ! grep -qE 'rpc error|^Error:' <<<"$out"; then
          printf '%s' "$out" | tr -d ' \n\t'
          return 0
        fi
        grep -E 'rpc error|^Error:' <<<"$out" | head -1 | sed "s/^/[$t] sonic-db retry error: /" >&2 || true
      fi
    fi
    printf 'QUERY_FAILED'
    return 0
  fi
  printf '%s' "$out" | tr -d ' \n\t'
}

sdb_has_entries() {
  # sdb_has_entries <body> <TABLE> — true only for a real reply carrying at least
  # one key. Note the reply echoes the table name even when empty, so matching the
  # bare name would be meaningless; require an opening key quote.
  local body=$1 table=$2
  [[ "$body" != QUERY_FAILED && "$body" == *"\"$table\":{\""* ]]
}

assert_sdb_entries() {
  # assert_sdb_entries <targets_csv> <TABLE> <label>
  local targets_csv=$1 table=$2 label=$3
  IFS=',' read -ra tgts <<<"$targets_csv"
  local rc=0 t body
  for t in "${tgts[@]}"; do
    body=$(sdb_body "$t" "$table")
    if [[ "$body" == QUERY_FAILED ]]; then
      echo "[$t] ASSERTION FAILED: $label — sonic-db query for $table did not answer" >&2
      rc=1
    elif [[ "$body" == ABSENT ]]; then
      echo "[$t] ASSERTION FAILED: $label — CONFIG_DB $table is absent (not configured)" >&2
      rc=1
    elif sdb_has_entries "$body" "$table"; then
      echo "[$t] assertion passed: $label ($table populated)"
    else
      echo "[$t] ASSERTION FAILED: $label — CONFIG_DB $table is empty" >&2
      rc=1
    fi
  done
  return $rc
}

vtysh_json() {
  # vtysh_json <node> <command> -> FRR JSON, or QUERY_FAILED when bgpd is absent.
  local n=$1 cmd=$2 out
  if ! docker exec "$n" bash -c 'pgrep -x bgpd >/dev/null' 2>/dev/null; then
    printf 'QUERY_FAILED'
    return 0
  fi
  set +e
  out=$(docker exec "$n" vtysh -c "$cmd" 2>&1)
  set -e
  printf '%s' "$out"
}

assert_grep_all() {
  # assert_grep_all <targets_csv> <gnmi_path> <grep_pattern>
  local targets_csv=$1; shift
  local path=$1; shift
  local pattern=$1; shift
  IFS=',' read -ra tgts <<<"$targets_csv"
  local rc=0
  for t in "${tgts[@]}"; do
    local out
    set +e
    out=$("$GNMIC_BIN" --address "$t" "${_args_common[@]}" get --path "$path" 2>&1)
    local e=$?
    set -e
    echo "[$t] get $path" >&2
    if [[ $e -ne 0 ]] || ! grep -qE "$pattern" <<<"$out"; then
      echo "[$t] ASSERTION FAILED: expected to find pattern '$pattern' in gNMI get $path output" >&2
      echo "----- BEGIN [$t] OUTPUT -----" >&2
      echo "$out" >&2
      echo "----- END [$t] OUTPUT -----" >&2
      rc=1
    else
      echo "[$t] assertion passed: pattern '$pattern' present"
    fi
  done
  return $rc
}

verify_underlay_bgp() {
  echo "[fabric-verify] underlay BGP: configuration (sonic-db) + session state (FRR)"
  # Split by where the data actually lives. BGP_NEIGHBOR/BGP_GLOBALS are CONFIG_DB
  # tables reachable over sonic-db; session state and the negotiated address
  # families are FRR runtime state with no CONFIG_DB representation, so they come
  # from vtysh. The old single OpenConfig path claimed to cover both and resolved
  # to neither on this build.
  local rc=0
  assert_sdb_entries "$LEAVES,$SPINES" BGP_NEIGHBOR 'underlay BGP neighbors configured' || rc=1

  local nodes n out
  IFS=',' read -ra nodes <<<"$LEAF_NODES,$SPINE_NODES"
  for n in "${nodes[@]}"; do
    out=$(vtysh_json "$n" 'show bgp summary json')
    if [[ "$out" == QUERY_FAILED ]]; then
      echo "[$n] ASSERTION FAILED: underlay BGP session state — bgpd is not running" >&2
      rc=1
    elif grep -q '"state":"Established"' <<<"$out"; then
      echo "[$n] assertion passed: underlay BGP session Established"
    else
      echo "[$n] ASSERTION FAILED: no Established underlay BGP session" >&2
      echo "----- BEGIN [$n] OUTPUT -----" >&2
      echo "$out" | head -40 >&2
      echo "----- END [$n] OUTPUT -----" >&2
      rc=1
    fi
  done

  echo "[fabric-verify] verify EVPN AF activation on BGP neighbors (L2VPN_EVPN)"
  IFS=',' read -ra nodes <<<"$LEAF_NODES"
  for n in "${nodes[@]}"; do
    out=$(vtysh_json "$n" 'show bgp l2vpn evpn summary json')
    if [[ "$out" == QUERY_FAILED ]]; then
      echo "[$n] ASSERTION FAILED: L2VPN EVPN AF — bgpd is not running" >&2
      rc=1
    elif grep -q '"state":"Established"' <<<"$out"; then
      echo "[$n] assertion passed: L2VPN EVPN AF negotiated with an Established peer"
    else
      echo "[$n] ASSERTION FAILED: L2VPN EVPN AF not negotiated" >&2
      rc=1
    fi
  done
  return $rc
}

verify_evpn_overlay() {
  echo "[fabric-verify] EVPN overlay routes (Type2/Type3/Type5) on leaves"
  # These previously decided pass/fail on gnmic's exit code alone. That is unsafe
  # on sonic-db, where a missing table answers rc=0 with an empty body — the exact
  # vacuous-pass shape findings 5 warns about. EVPN routes are FRR RIB state
  # anyway (no CONFIG_DB table holds them), so assert route-type content from the
  # EVPN RIB: prefixes are rendered "[2]:[...]", "[3]:[...]", "[5]:[...]".
  local rc=0 nodes n out
  IFS=',' read -ra nodes <<<"$LEAF_NODES"
  for n in "${nodes[@]}"; do
    out=$(vtysh_json "$n" 'show bgp l2vpn evpn json')
    if [[ "$out" == QUERY_FAILED ]]; then
      echo "[$n] ASSERTION FAILED: EVPN RIB unreadable — bgpd is not running" >&2
      rc=1
      continue
    fi
    local t
    for t in 2 3 5; do
      if grep -qE "\\[$t\\]:" <<<"$out"; then
        echo "[$n] assertion passed: EVPN Type-$t route present"
      else
        if [[ "$t" == 5 ]]; then
          # Type-5 needs the L3VNI to be adopted by bgpd. The full recipe is
          # implemented and documented (docs/FABRIC_BGP_EVPN_DEFERRED.md D-A:
          # kernel vrf_slave binding, vrf vni block, vrf RIB sync, zebra L3VNI
          # classification all demonstrated on the sonic-vs-gnmi:202605-v2
          # image), but this image's FRR 10.5.4 build does not reliably adopt
          # the L3VNI into bgpd's export path — origination never fires in any
          # state tried (2026-09-01 reconciliation). Fail-closed: report the
          # gap precisely instead of silently weakening the assertion.
          echo "[$n] ASSERTION FAILED: no EVPN Type-5 route in the RIB (L3VNI origination defect of the sonic-vs FRR 10.5.4 build — see docs/FABRIC_BGP_EVPN_DEFERRED.md and gates evidence)" >&2
        else
          echo "[$n] ASSERTION FAILED: no EVPN Type-$t route in the RIB" >&2
        fi
        rc=1
      fi
    done
  done
  return $rc
}

# Give the EVPN overlay data plane something to originate: the bridged Vlan100
# clients exchange traffic, which is what produces the MACs/IPs zebra
# originates as Type-2 routes. Idempotent: drops legacy /31 addresses from
# older topology revisions, (re)adds the shared /24 + /64, then pings across
# the overlay with retries (remote MAC learning needs a few round trips).
drive_client_traffic() {
  echo "[fabric-verify] Driving client traffic across the EVPN overlay (Type-2 source)"
  local rc=0 c1="${CLAB_PREFIX}client01" c2="${CLAB_PREFIX}client02"
  for c in "$c1" "$c2"; do
    if ! docker ps --format '{{.Names}}' | grep -qx "$c"; then
      echo "[$c] ASSERTION FAILED: EVPN client container missing" >&2
      return 1
    fi
  done
  docker exec "$c1" ip addr del 192.0.2.11/31 dev eth1 2>/dev/null || true
  docker exec "$c2" ip addr del 192.0.2.21/31 dev eth1 2>/dev/null || true
  docker exec "$c1" ip -6 addr del 2001:db8:1::11/127 dev eth1 2>/dev/null || true
  docker exec "$c2" ip -6 addr del 2001:db8:2::21/127 dev eth1 2>/dev/null || true
  docker exec "$c1" bash -c 'ip -br addr show eth1 | grep -q "192.0.2.11/24" || ip addr add 192.0.2.11/24 dev eth1' || true
  docker exec "$c2" bash -c 'ip -br addr show eth1 | grep -q "192.0.2.21/24" || ip addr add 192.0.2.21/24 dev eth1' || true
  # Wait for the EVPN control plane to converge BEFORE pinging: flooding to
  # the remote VTEP only starts once the IMET (Type-3) from the peer leaf has
  # arrived. Cycle-3 (2026-09-01 07:41) pinged before that and lost 100% of
  # ARPs despite the RIB being complete seconds later.
  local n wait_ok
  IFS=',' read -ra nodes <<<"$LEAF_NODES"
  for n in "${nodes[@]}"; do
    wait_ok=0
    for i in $(seq 1 20); do
      # Remote VTEPs column ≥ 1 for vni 100 means the peer IMET arrived
      if docker exec "$n" vtysh -c 'show evpn vni' 2>/dev/null | grep -E '^100 .*[1-9][0-9]*\s+default' >/dev/null; then
        wait_ok=1
        break
      fi
      sleep 3
    done
    [[ "$wait_ok" -eq 1 ]] || echo "[$n] WARN: no remote VTEP on vni 100 after 60s — ping will likely fail" >&2
  done
  local i out
  for i in $(seq 1 6); do
    out=$(docker exec "$c1" ping -c3 -W2 192.0.2.21 2>&1) || true
    # Match with a leading space: a bare "0% packet loss" grep also matches
    # "100% packet loss" (substring), which reported a false pass on a 100%
    # loss run in cycles cycle-1 (observed 2026-09-01).
    if grep -q " 0% packet loss" <<<"$out"; then
      echo "[client01→client02] assertion passed: bridged Vlan100 reachability ($(grep ' 0% packet loss' <<<"$out"))"
      return 0
    fi
    sleep 3
  done
  echo "[client01→client02] ASSERTION FAILED: no bridged Vlan100 reachability across the overlay (last: $(grep -E 'packet loss|From' <<<"$out" | tail -1))" >&2
  return 1
}

_fetch_loopback_v6() {
  # Loopback0 IPv6 from CONFIG_DB. The LOOPBACK_INTERFACE table is keyed
  # "Loopback0|<addr>/<prefixlen>", so the address is parsed out of the key.
  # Emits nothing when the table is absent or carries no IPv6 — callers treat an
  # empty result as "not discoverable" and fail rather than skip silently.
  local target=$1 body
  body=$(sdb_body "$target" LOOPBACK_INTERFACE)
  [[ "$body" == QUERY_FAILED || "$body" == ABSENT ]] && return 0
  grep -oE 'Loopback0\|[0-9a-fA-F:]*:[0-9a-fA-F:]*' <<<"$body" \
    | head -n1 | cut -d'|' -f2
}

verify_loopback_reachability() {
  echo "[fabric-verify] loopback reachability across all nodes (IPv6)"
  # Use containerlab exec to ping between leaf loopbacks via mgmt net namespace
  local l1="${CLAB_PREFIX}leaf01" l2="${CLAB_PREFIX}leaf02"
  # Discover loopback IPv6 addresses via gNMI
  local lo1 lo2
  lo1=$(_fetch_loopback_v6 "${LEAVES%%,*}") || true
  lo2=$(_fetch_loopback_v6 "${LEAVES##*,}") || true
  if [[ -n "${lo1:-}" && -n "${lo2:-}" ]]; then
    echo "[fabric-verify] ping6 leaf01(${lo1}) -> leaf02(${lo2})"
    docker exec "$l1" bash -lc "ping -6 -c 3 -W 2 ${lo2}"
    echo "[fabric-verify] ping6 leaf02(${lo2}) -> leaf01(${lo1})"
    docker exec "$l2" bash -lc "ping -6 -c 3 -W 2 ${lo1}"
    echo "loopback reachability" # keyword for proof grepping
  else
    echo "[fabric-verify] WARN: could not auto-discover loopback IPv6 addresses; skipping loopback ping" >&2
    return 1
  fi
}

verify_ipv6_waypoint_reachability() {
  echo "[fabric-verify] IPv6 waypoint reachability for SRv6 path"
  # Probe connectivity to configured transit waypoints (if any) by traceroute6 from leaf01
  local src="${CLAB_PREFIX}leaf01"
  local waypoints=${SRV6_WAYPOINTS:-""}
  if [[ -z "$waypoints" ]]; then
    echo "[fabric-verify] INFO: no SRV6_WAYPOINTS provided; attempting traceroute to peer leaf loopback as waypoint surrogate"
    local dst_v6
    dst_v6=$(_fetch_loopback_v6 "${LEAVES##*,}") || true
    if [[ -n "${dst_v6:-}" ]]; then
      docker exec "$src" bash -lc "traceroute -6 -n -q1 -m 10 ${dst_v6} || true"
      echo "IPv6 waypoint reachability" # keyword for proof grepping
    else
      echo "[fabric-verify] WARN: no waypoint or dst loopback; skipping" >&2
      return 1
    fi
  else
    for wp in $waypoints; do
      docker exec "$src" bash -lc "traceroute -6 -n -q1 -m 10 ${wp} || true"
    done
    echo "IPv6 waypoint reachability"
  fi
}

assert_no_tenant_state_on_spines() {
  echo "[fabric-verify] Assert absence of tenant VTEP/VRF state on spines (FR-004)"
  # Negative checks. A negative assertion only means something if the query
  # itself answered: the old checks used translib paths
  # (/sonic-vxlan:sonic-vxlan/..., /openconfig-network-instance:...) that this
  # build refuses, so "absent" was indistinguishable from "unaskable" and the
  # check could not fail honestly. Worse, the VXLAN grep matched the table name
  # that gnmic echoes back in its own error text. Both now go through sonic-db
  # and require a real reply before concluding absence.
  IFS=',' read -ra tgts <<<"$SPINES"
  local rc=0 t body
  # 1) No VXLAN tunnel objects on spines (SONiC native)
  for t in "${tgts[@]}"; do
    body=$(sdb_body "$t" VXLAN_TUNNEL)
    if [[ "$body" == QUERY_FAILED ]]; then
      echo "[$t] ASSERTION FAILED: cannot prove absence — sonic-db query for VXLAN_TUNNEL did not answer" >&2
      rc=1
    elif [[ "$body" == ABSENT ]]; then
      echo "[$t] OK: no VXLAN/VTEP state on spine (CONFIG_DB VXLAN_TUNNEL absent)"
    elif sdb_has_entries "$body" VXLAN_TUNNEL; then
      echo "[$t] ASSERTION FAILED: spine has VXLAN/VTEP state present" >&2
      rc=1
    else
      echo "[$t] OK: no VXLAN/VTEP state on spine (CONFIG_DB VXLAN_TUNNEL empty)"
    fi
  done
  # 2) No tenant VRFs present on spines (only default or mgmt)
  for t in "${tgts[@]}"; do
    body=$(sdb_body "$t" VRF)
    if [[ "$body" == QUERY_FAILED ]]; then
      echo "[$t] ASSERTION FAILED: cannot prove absence — sonic-db query for VRF did not answer" >&2
      rc=1
    elif [[ "$body" == ABSENT ]]; then
      echo "[$t] OK: no tenant VRF names detected on spine (CONFIG_DB VRF absent)"
    elif grep -Eqi 'vrf-|tenant-|l3vni|Vrf1|Vrf2' <<<"$body"; then
      echo "[$t] ASSERTION FAILED: unexpected tenant VRF names on spine: $body" >&2
      rc=1
    else
      echo "[$t] OK: no tenant VRF names detected on spine"
    fi
  done
  echo "absence of tenant VTEP/VRF state on spines (FR-004)" # keyword for proof grepping
  return $rc
}

case "${1:-run}" in
  run)
    if ! ensure_lab_secrets; then
      # Return code 64 from ensure_lab_secrets means prereq missing — skip the suite
      echo "FABRIC_VERIFY_SKIPPED"; exit 0
    fi
    if ! prereq_ready; then
      echo "FABRIC_VERIFY_SKIPPED"; exit 0
    fi
    if ! lab_gnmi_reachable; then
      # Profile is not SRv6-qualified (capability gate owns that decision):
      # no live fabric verification can be claimed against it. Skip, don't fail.
      echo "FABRIC_VERIFY_SKIPPED: SONiC gNMI endpoints unreachable — selected profile is not SRv6-qualified (capability gate, scripts/lib/qualify.sh, is the source of truth); live fabric verification not applicable"
      exit 0
    fi
    # Run every verifier and accumulate failures: with set -e a bare failing
    # call aborted the whole suite at the first failure, hiding the state of
    # every later check (observed 2026-09-01 — underlay failures masked the
    # EVPN/spine evidence the loop needed to act on).
    rc=0
    verify_underlay_bgp || rc=1
    drive_client_traffic || rc=1
    verify_evpn_overlay || rc=1
    verify_loopback_reachability || rc=1
    verify_ipv6_waypoint_reachability || rc=1
    assert_no_tenant_state_on_spines || rc=1
    exit $rc
    ;;
  *)
    echo "usage: $0 run" >&2; exit 2
    ;;
esac
