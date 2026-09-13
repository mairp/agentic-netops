#!/usr/bin/env bash
# Verify the SR Linux underlay/EVPN sessions, overlay data plane, loopback
# reachability, and the absence of tenant VTEP/VRF state on the spines (FR-003,
# FR-011).
#
# Every assertion here reads device state over gNMI against the native
# srl_nokia-* models — the same surface the fabric-executor verifies against, so
# a pass is evidence about the real system and not about a parallel one. Three
# rules are non-negotiable in this file:
#
#   1. A query that could not be asked (TLS, Unavailable, Unauthenticated,
#      deadline) is NEVER readable as proof of absence. It is reported as
#      QUERY_FAILED and fails the assertion that depended on it.
#   2. Route presence is asserted on the RECEIVED side of the EVPN RIB
#      (rib-in-post). A leaf originates its own Type-2/Type-3 routes, so the
#      local RIB is satisfied by an overlay that has never exchanged anything.
#   3. Every verifier runs and accumulates; the suite does not abort on the
#      first failure, because the state of the later checks is exactly what a
#      diagnosis needs.
set -euo pipefail

GNMIC_BIN=${GNMIC_BIN:-gnmic}
GNMI_USER=${GNMI_USER:-admin}
GNMI_PASS=${GNMI_PASS:-admin}
GNMI_CACERT=${GNMI_CACERT:-./secrets/ca.crt}
GNMI_ENCODING=${GNMI_ENCODING:-json_ietf}
# SR Linux management gNMI endpoints from lab/topology.clab.yml
LEAVES=${LEAVES:-"172.31.0.21:57400,172.31.0.22:57400"}
SPINES=${SPINES:-"172.31.0.11:57400,172.31.0.12:57400"}
CLAB_PREFIX=${CLAB_PREFIX:-clab-agentic-netops-fabric-}
LEAF_NODES=${LEAF_NODES:-"${CLAB_PREFIX}leaf01,${CLAB_PREFIX}leaf02"}
SPINE_NODES=${SPINE_NODES:-"${CLAB_PREFIX}spine01,${CLAB_PREFIX}spine02"}
# Bootstrap tenants from lab/profiles/srlinux/config/leaf0*.cfg
L2VNI=${L2VNI:-100}
L3VNI=${L3VNI:-2000}
VXLAN_TUNNEL=${VXLAN_TUNNEL:-vxlan1}
# Network-instances every node legitimately has. Anything else on a spine is
# tenant state and a violation of the fabric's separation contract.
BASE_NIS=${BASE_NIS:-"default mgmt"}
CONVERGE_TRIES=${CONVERGE_TRIES:-30}
CONVERGE_SLEEP=${CONVERGE_SLEEP:-10}
AGENTIC_NETOPS_CLUSTER_NAME=${AGENTIC_NETOPS_CLUSTER_NAME:-agentic-netops}
KUBE_CTX=${KUBE_CTX:-kind-${AGENTIC_NETOPS_CLUSTER_NAME}}

BGP_NEIGHBOR="/network-instance[name=default]/protocols/bgp/neighbor[peer-address=*]"
EVPN_RIB_IN="/network-instance[name=default]/bgp-rib/afi-safi[afi-safi-name=evpn]/evpn/rib-in-out/rib-in-post"

# Common args for gnmic. No client certificate: the SR Linux gNMI server
# authenticates username/password over a server-authenticated TLS channel.
_args_common=(--timeout 10s --username "$GNMI_USER" --password "$GNMI_PASS" --encoding "$GNMI_ENCODING" --tls-ca "$GNMI_CACERT")

ensure_lab_secrets() {
  # Ensure ./secrets/ca.crt and GNMI_USER/PASS are available. If absent, fetch
  # from the in-cluster Secrets (agentic-netops-system: gnmi-lab-creds,
  # gnmi-lab-tls). scripts/lib/containerlab.sh bootstrap is what puts the
  # containerlab CA into gnmi-lab-tls in the first place.
  local need_fetch=0
  [[ -s "$GNMI_CACERT" ]] || need_fetch=1
  if [[ -z "${GNMI_USER:-}" || -z "${GNMI_PASS:-}" ]]; then need_fetch=1; fi
  if [[ "$need_fetch" -eq 0 ]]; then return 0; fi

  if ! command -v kubectl >/dev/null 2>&1; then
    echo "[fabric-verify] SKIP: kubectl not available and local secrets missing — skipping fabric verification in CI/minimal environment" >&2
    return 64 # special code meaning prereq-missing
  fi

  echo "[fabric-verify] fetching lab credentials/TLS from cluster secrets into ./secrets"
  mkdir -p ./secrets
  if kubectl --context "$KUBE_CTX" -n agentic-netops-system get secret gnmi-lab-creds >/dev/null 2>&1; then
    GNMI_USER=$(kubectl --context "$KUBE_CTX" -n agentic-netops-system get secret gnmi-lab-creds -o jsonpath='{.data.username}' | base64 -d || true)
    GNMI_PASS=$(kubectl --context "$KUBE_CTX" -n agentic-netops-system get secret gnmi-lab-creds -o jsonpath='{.data.password}' | base64 -d || true)
    export GNMI_USER GNMI_PASS
  else
    echo "[fabric-verify] WARN: secret gnmi-lab-creds not found" >&2
  fi
  if kubectl --context "$KUBE_CTX" -n agentic-netops-system get secret gnmi-lab-tls >/dev/null 2>&1; then
    kubectl --context "$KUBE_CTX" -n agentic-netops-system get secret gnmi-lab-tls -o jsonpath='{.data.ca\.crt}' | base64 -d > "$GNMI_CACERT" || true
  else
    echo "[fabric-verify] WARN: secret gnmi-lab-tls not found" >&2
  fi

  # If still missing, proactively create via RBAC manifests and generator Job.
  if [[ ! -s "$GNMI_CACERT" ]] || [[ -z "${GNMI_USER:-}" || -z "${GNMI_PASS:-}" ]]; then
    echo "[fabric-verify] attempting to create lab Secrets via deploy/rbac manifests and generator Job"
    kubectl --context "$KUBE_CTX" apply -f deploy/rbac/secrets.yaml || true
    kubectl --context "$KUBE_CTX" apply -f deploy/rbac/secret-generator-job.yaml || true
    kubectl --context "$KUBE_CTX" -n agentic-netops-system wait --for=condition=Complete --timeout=30s job/agentic-netops-secret-generator || true
    if kubectl --context "$KUBE_CTX" -n agentic-netops-system get secret gnmi-lab-creds >/dev/null 2>&1; then
      GNMI_USER=$(kubectl --context "$KUBE_CTX" -n agentic-netops-system get secret gnmi-lab-creds -o jsonpath='{.data.username}' | base64 -d || true)
      GNMI_PASS=$(kubectl --context "$KUBE_CTX" -n agentic-netops-system get secret gnmi-lab-creds -o jsonpath='{.data.password}' | base64 -d || true)
      export GNMI_USER GNMI_PASS
    fi
    if kubectl --context "$KUBE_CTX" -n agentic-netops-system get secret gnmi-lab-tls >/dev/null 2>&1; then
      kubectl --context "$KUBE_CTX" -n agentic-netops-system get secret gnmi-lab-tls -o jsonpath='{.data.ca\.crt}' | base64 -d > "$GNMI_CACERT" || true
    fi
  fi

  _args_common=(--timeout 10s --username "$GNMI_USER" --password "$GNMI_PASS" --encoding "$GNMI_ENCODING" --tls-ca "$GNMI_CACERT")
}

prereq_ready() {
  [[ -s "$GNMI_CACERT" ]] || return 1
  command -v "$GNMIC_BIN" >/dev/null 2>&1 || return 1
  return 0
}

# The live fabric verification is only meaningful against a deployed lab. When no
# SR Linux gNMI endpoint accepts a connection the lab is not up, and this suite
# must SKIP (not fail) so it is never mistaken for a passing fabric result. The
# capability gate (scripts/lib/qualify.sh) remains the single source of truth for
# whether the profile qualified.
lab_gnmi_reachable() {
  local t h p
  IFS=',' read -ra tgts <<<"$LEAVES"
  for t in "${tgts[@]}"; do
    h=${t%:*}; p=${t#*:}
    if timeout 3 bash -c "exec 3<>/dev/tcp/${h}/${p}" 2>/dev/null; then
      return 0
    fi
  done
  return 1
}

# --- gNMI helpers -------------------------------------------------------------

# gnmi_body <target> <path> -> raw reply, or the literal QUERY_FAILED when the
# request itself did not answer. QUERY_FAILED is never equal to "empty": an
# unaskable query must not be read as proof of absence.
gnmi_body() {
  local t=$1 path=$2 out e
  set +e
  out=$("$GNMIC_BIN" --address "$t" "${_args_common[@]}" get --path "$path" 2>&1)
  e=$?
  set -e
  if grep -q 'NotFound' <<<"$out"; then
    printf 'ABSENT'
    return 0
  fi
  if [[ $e -ne 0 ]] || grep -qE 'rpc error|^Error:' <<<"$out"; then
    grep -E 'rpc error|^Error:' <<<"$out" | head -1 | sed "s|^|[$t] gNMI query error: |" >&2 || true
    printf 'QUERY_FAILED'
    return 0
  fi
  printf '%s' "$out"
}

# gnmi_leaf_values <target> <path> -> one value per line, or QUERY_FAILED/ABSENT
gnmi_leaf_values() {
  local body
  body=$(gnmi_body "$1" "$2")
  if [[ "$body" == QUERY_FAILED || "$body" == ABSENT ]]; then printf '%s' "$body"; return 0; fi
  jq -r '[.[].updates[].values] | map(to_entries[].value) | .[] | if type=="string" then . else tojson end' <<<"$body" 2>/dev/null || true
}

# rib_entry_count <body> — EVPN RIB entries in a reply; every entry carries
# exactly one route-distinguisher.
rib_entry_count() {
  grep -o '"route-distinguisher"' <<<"$1" | wc -l | tr -d ' '
}

# --- assertions ---------------------------------------------------------------

verify_underlay_bgp() {
  echo "[fabric-verify] BGP session state on every node (gNMI: ${BGP_NEIGHBOR}/session-state)"
  local rc=0 t i body total est
  IFS=',' read -ra tgts <<<"$LEAVES,$SPINES"
  for t in "${tgts[@]}"; do
    local ok=0
    for i in $(seq 1 "$CONVERGE_TRIES"); do
      body=$(gnmi_body "$t" "${BGP_NEIGHBOR}/session-state")
      if [[ "$body" == QUERY_FAILED || "$body" == ABSENT ]]; then sleep "$CONVERGE_SLEEP"; continue; fi
      total=$(grep -oi '"session-state"' <<<"$body" | wc -l | tr -d ' ')
      est=$(grep -oi '"established"' <<<"$body" | wc -l | tr -d ' ')
      if [[ "$total" =~ ^[0-9]+$ ]] && (( total > 0 )) && (( est == total )); then
        echo "[$t] assertion passed: all ${total} BGP session(s) Established"
        ok=1
        break
      fi
      sleep "$CONVERGE_SLEEP"
    done
    if (( ok == 0 )); then
      if [[ "$body" == QUERY_FAILED ]]; then
        echo "[$t] ASSERTION FAILED: BGP session state — the gNMI query never answered; this is a transport failure, not an absence of sessions" >&2
      else
        echo "[$t] ASSERTION FAILED: not every BGP session reached Established (${est:-0}/${total:-0} after $((CONVERGE_TRIES*CONVERGE_SLEEP))s)" >&2
        echo "----- BEGIN [$t] OUTPUT -----" >&2
        echo "$body" | head -40 >&2
        echo "----- END [$t] OUTPUT -----" >&2
      fi
      rc=1
    fi
  done

  echo "[fabric-verify] EVPN address family negotiated on the overlay sessions"
  IFS=',' read -ra tgts <<<"$LEAVES,$SPINES"
  for t in "${tgts[@]}"; do
    body=$(gnmi_body "$t" "${BGP_NEIGHBOR}/afi-safi[afi-safi-name=evpn]/active")
    if [[ "$body" == QUERY_FAILED ]]; then
      echo "[$t] ASSERTION FAILED: EVPN AF — the gNMI query did not answer" >&2
      rc=1
    elif [[ "$body" == ABSENT ]]; then
      echo "[$t] ASSERTION FAILED: EVPN AF — no neighbor carries an evpn afi-safi" >&2
      rc=1
    elif grep -q 'true' <<<"$body"; then
      echo "[$t] assertion passed: EVPN address family negotiated with at least one peer"
    else
      echo "[$t] ASSERTION FAILED: EVPN address family not negotiated with any peer" >&2
      rc=1
    fi
  done
  return $rc
}

verify_evpn_overlay() {
  echo "[fabric-verify] EVPN routes RECEIVED from peers on the leaves (Type-2/3/5)"
  local rc=0 t list label body n i ok
  IFS=',' read -ra tgts <<<"$LEAVES"
  for t in "${tgts[@]}"; do
    for pair in "mac-ip-routes:Type-2" "imet-routes:Type-3" "ip-prefix-routes:Type-5"; do
      list=${pair%%:*}; label=${pair##*:}
      ok=0
      for i in $(seq 1 "$CONVERGE_TRIES"); do
        body=$(gnmi_body "$t" "${EVPN_RIB_IN}/${list}")
        if [[ "$body" != QUERY_FAILED ]]; then
          n=$(rib_entry_count "$body")
          if [[ "$n" =~ ^[0-9]+$ ]] && (( n > 0 )); then
            echo "[$t] assertion passed: EVPN ${label} — ${n} route(s) received from a peer"
            ok=1
            break
          fi
        fi
        sleep "$CONVERGE_SLEEP"
      done
      if (( ok == 0 )); then
        echo "[$t] ASSERTION FAILED: no EVPN ${label} route received from a peer (self-originated routes are not evidence of exchange)" >&2
        rc=1
      fi
    done

    # Peer-arrival assertion: the remote VTEP list for the L2VNI is the one
    # signal self-origination cannot satisfy. It is non-zero only once the peer
    # leaf's IMET has been received AND installed in the bridge table.
    local path="/tunnel-interface[name=${VXLAN_TUNNEL}]/vxlan-interface[index=${L2VNI}]/bridge-table/multicast-destinations/destination"
    ok=0
    for i in $(seq 1 "$CONVERGE_TRIES"); do
      body=$(gnmi_body "$t" "$path")
      if [[ "$body" != QUERY_FAILED ]]; then
        n=$(grep -o '"destination-index"\|"vtep-address"' <<<"$body" | wc -l | tr -d ' ')
        if [[ "$n" =~ ^[0-9]+$ ]] && (( n > 0 )); then
          echo "[$t] assertion passed: ${n} remote VTEP(s) on ${VXLAN_TUNNEL}.${L2VNI} — peer EVPN routes received"
          ok=1
          break
        fi
      fi
      sleep "$CONVERGE_SLEEP"
    done
    if (( ok == 0 )); then
      echo "[$t] ASSERTION FAILED: 0 remote VTEPs on ${VXLAN_TUNNEL}.${L2VNI} — no EVPN route has been received from the peer leaf, so the overlay cannot forward" >&2
      rc=1
    fi
  done
  return $rc
}

# Give the EVPN overlay data plane something to originate: the bridged vlan100
# clients exchange traffic, which is what produces the MACs/IPs the leaves
# originate as Type-2 routes. Idempotent.
drive_client_traffic() {
  echo "[fabric-verify] Driving client traffic across the EVPN overlay (Type-2 source)"
  local c1="${CLAB_PREFIX}client01" c2="${CLAB_PREFIX}client02" c i out
  for c in "$c1" "$c2"; do
    if ! docker ps --format '{{.Names}}' | grep -qx "$c"; then
      echo "[$c] ASSERTION FAILED: EVPN client container missing" >&2
      return 1
    fi
  done
  # Client image is busybox (no bash).
  docker exec "$c1" sh -c 'ip -br addr show eth1 | grep -q "192.0.2.11/24" || ip addr add 192.0.2.11/24 dev eth1' || true
  docker exec "$c2" sh -c 'ip -br addr show eth1 | grep -q "192.0.2.21/24" || ip addr add 192.0.2.21/24 dev eth1' || true
  for i in $(seq 1 "$CONVERGE_TRIES"); do
    out=$(docker exec "$c1" ping -c3 -W2 192.0.2.21 2>&1) || true
    # Match with a leading space: a bare "0% packet loss" grep also matches
    # "100% packet loss" as a substring.
    if grep -q " 0% packet loss" <<<"$out"; then
      echo "[client01→client02] assertion passed: bridged vlan100 reachability ($(grep ' 0% packet loss' <<<"$out"))"
      return 0
    fi
    sleep "$CONVERGE_SLEEP"
  done
  echo "[client01→client02] ASSERTION FAILED: no bridged vlan100 reachability across the overlay (last: $(grep -E 'packet loss|From' <<<"$out" | tail -1))" >&2
  return 1
}

_fetch_system_v6() {
  # system0 IPv6 address from the node's own state. Emits nothing when it is not
  # discoverable — callers fail rather than skip silently.
  local target=$1 vals
  vals=$(gnmi_leaf_values "$target" '/interface[name=system0]/subinterface[index=0]/ipv6/address')
  [[ "$vals" == QUERY_FAILED || "$vals" == ABSENT ]] && return 0
  grep -oE '[0-9a-fA-F:]{2,}:[0-9a-fA-F:]+/[0-9]+' <<<"$vals" | head -n1 | cut -d'/' -f1
}

# sr_cli_ping6 <container> <addr> — read-only ping from the node's default
# network-instance. `sr_cli` is the honest source for a data-plane probe from a
# node; nothing is configured through it.
# VERIFY LIVE (config/NOTES.md): confirm `ping6 <addr> network-instance default`
# on 26.7; the fallback below covers the `ping` spelling.
sr_cli_ping6() {
  local c=$1 addr=$2 out
  out=$(docker exec "$c" sr_cli "ping6 ${addr} network-instance default -c 3" 2>&1) || true
  if ! grep -qE 'packet loss' <<<"$out"; then
    out=$(docker exec "$c" sr_cli "ping ${addr} network-instance default -c 3" 2>&1) || true
  fi
  printf '%s' "$out"
}

verify_loopback_reachability() {
  echo "[fabric-verify] loopback reachability between the leaves (IPv6, system0)"
  local l1="${CLAB_PREFIX}leaf01" l2="${CLAB_PREFIX}leaf02"
  local lo1 lo2
  lo1=$(_fetch_system_v6 "${LEAVES%%,*}") || true
  lo2=$(_fetch_system_v6 "${LEAVES##*,}") || true
  if [[ -z "${lo1:-}" || -z "${lo2:-}" ]]; then
    echo "[fabric-verify] ASSERTION FAILED: could not discover the leaves' system0 IPv6 addresses over gNMI" >&2
    return 1
  fi
  local rc=0 i out ok src dst dst_addr pair
  for pair in "1:2" "2:1"; do
    if [[ "$pair" == "1:2" ]]; then src="$l1"; dst="$l2"; dst_addr="$lo2";
    else src="$l2"; dst="$l1"; dst_addr="$lo1"; fi
    echo "[fabric-verify] ping6 ${src#"$CLAB_PREFIX"} -> ${dst#"$CLAB_PREFIX"} [$dst_addr]"
    ok=0
    for i in $(seq 1 "$CONVERGE_TRIES"); do
      # Ping the peer's system0 ADDRESS, not a container name: a name would
      # exercise Docker's embedded DNS on the management network rather than the
      # underlay, and could never pass at all.
      out=$(sr_cli_ping6 "$src" "$dst_addr")
      if grep -q " 0% packet loss" <<<"$out"; then ok=1; break; fi
      sleep "$CONVERGE_SLEEP"
    done
    if [[ "$ok" -eq 1 ]]; then
      echo "[${src#"$CLAB_PREFIX"}→${dst#"$CLAB_PREFIX"}] assertion passed: loopback IPv6 reachable ($(grep ' 0% packet loss' <<<"$out"))"
    else
      echo "[${src#"$CLAB_PREFIX"}→${dst#"$CLAB_PREFIX"}] ASSERTION FAILED: loopback IPv6 unreachable after convergence wait (last: $(grep -E 'packet loss' <<<"$out" | tail -1))" >&2
      rc=1
    fi
  done
  echo "loopback reachability" # keyword for proof grepping
  return $rc
}

assert_no_tenant_state_on_spines() {
  echo "[fabric-verify] Assert absence of tenant VTEP/VRF state on spines (FR-003)"
  # Negative checks only mean something if the query itself answered.
  IFS=',' read -ra tgts <<<"$SPINES"
  local rc=0 t body names extra n
  # 1) No VXLAN tunnel objects on spines
  for t in "${tgts[@]}"; do
    body=$(gnmi_body "$t" "/tunnel-interface")
    if [[ "$body" == QUERY_FAILED ]]; then
      echo "[$t] ASSERTION FAILED: cannot prove absence — the gNMI query for /tunnel-interface did not answer" >&2
      rc=1
    elif [[ "$body" == ABSENT ]]; then
      echo "[$t] OK: no VXLAN/VTEP state on spine (/tunnel-interface absent)"
    elif grep -q 'vxlan-interface' <<<"$body"; then
      echo "[$t] ASSERTION FAILED: spine carries VXLAN/VTEP state: $body" >&2
      rc=1
    else
      echo "[$t] OK: no VXLAN/VTEP state on spine (/tunnel-interface carries no vxlan-interface)"
    fi
  done
  # 2) Only the base network-instances exist on spines
  for t in "${tgts[@]}"; do
    body=$(gnmi_body "$t" "/network-instance")
    if [[ "$body" == QUERY_FAILED ]]; then
      echo "[$t] ASSERTION FAILED: cannot prove absence — the gNMI query for /network-instance did not answer" >&2
      rc=1
      continue
    fi
    if [[ "$body" == ABSENT ]]; then
      echo "[$t] ASSERTION FAILED: /network-instance is absent — a spine must at least carry 'default'" >&2
      rc=1
      continue
    fi
    names=$(jq -r '[.[].updates[].values] | map(to_entries[].value) | .. | objects | select(has("name")) | .name' <<<"$body" 2>/dev/null | sort -u || true)
    if [[ -z "$names" ]]; then
      echo "[$t] ASSERTION FAILED: could not read any network-instance name from the reply" >&2
      rc=1
      continue
    fi
    extra=""
    while read -r n; do
      [[ -z "$n" ]] && continue
      case " $BASE_NIS " in
        *" $n "*) ;;
        *) extra="${extra} ${n}" ;;
      esac
    done <<<"$names"
    if [[ -n "$extra" ]]; then
      echo "[$t] ASSERTION FAILED: tenant network-instance(s) present on a spine:${extra}" >&2
      rc=1
    else
      echo "[$t] OK: only base network-instances on spine ($(tr '\n' ' ' <<<"$names"))"
    fi
  done
  echo "absence of tenant VTEP/VRF state on spines (FR-003)" # keyword for proof grepping
  return $rc
}

case "${1:-run}" in
  run)
    if ! ensure_lab_secrets; then
      # 64 from ensure_lab_secrets means prereq missing — skip the suite
      echo "FABRIC_VERIFY_SKIPPED"; exit 0
    fi
    if ! prereq_ready; then
      echo "FABRIC_VERIFY_SKIPPED"; exit 0
    fi
    if ! lab_gnmi_reachable; then
      echo "FABRIC_VERIFY_SKIPPED: SR Linux gNMI endpoints unreachable — no lab is deployed; live fabric verification not applicable (the capability gate, scripts/lib/qualify.sh, is the source of truth)"
      exit 0
    fi
    # Run every verifier and accumulate failures: aborting at the first failure
    # hides the state of every later check, which is exactly what a diagnosis
    # needs.
    rc=0
    verify_underlay_bgp || rc=1
    drive_client_traffic || rc=1
    verify_evpn_overlay || rc=1
    verify_loopback_reachability || rc=1
    assert_no_tenant_state_on_spines || rc=1
    exit $rc
    ;;
  *)
    echo "usage: $0 run" >&2; exit 2
    ;;
esac
