# spike-env.sh — common environment for the feature-004 feasibility spike
# (phase 3, plan 0-03 onwards). Every spike runner sources this file and talks
# to the sonic-vm guests only through node_run from
# tests/integration/lib/node_exec.sh (the sonic-vm kind routes over SSH into
# the guest VM; the launcher container is never exec'd for device commands).

SPIKE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SPIKE_DIR/../.." && pwd)"
# shellcheck disable=SC1091
. "$REPO_ROOT/tests/integration/lib/node_exec.sh"

C_spine01=clab-agentic-netops-fabric-spine01
C_spine02=clab-agentic-netops-fabric-spine02
C_leaf01=clab-agentic-netops-fabric-leaf01
C_leaf02=clab-agentic-netops-fabric-leaf02
C_srv6_client01=clab-agentic-netops-fabric-srv6-client01
C_srv6_client02=clab-agentic-netops-fabric-srv6-client02

# container_of <node> — the launcher container a node runs in
container_of() {
    eval echo "\${C_$1}"
}

# Ping output carries round-trip times, TTLs and sequence numbers; normalizing
# them keeps a re-run byte-identical (FR-039/SC-15).
ping_norm() {
    sed -E 's/time=[0-9.]+ ms/time=X ms/g; s/time [0-9]+ms/time Xms/g;
            s|rtt min/avg/max/mdev = [0-9./]+ ms|rtt min/avg/max/mdev = X ms|;
            s/ttl=[0-9]+/ttl=X/g; s/icmp_seq=[0-9]+/icmp_seq=N/g'
}

# addr_norm: container-side `ip -br addr` leaks the host-side veth ifindex
# (`eth1@if473`); docker recreates veths on every bring-up, so masking it
# keeps a re-run byte-identical across redeploys (FR-039/SC-15). The same
# applies to the other hardware-identity bytes a redeploy regenerates: the
# MACs themselves and the MAC-derived EUI-64 prefixes kernels auto-add on
# every interface (`fe80::…/64`, and the guest eth0 `fec0::…` local prefix).
# They are hardware identity, not recipe state; masking them keeps a re-run
# byte-identical across redeploys without hiding any recipe-relevant byte.
addr_norm() {
    sed -E 's/@if[0-9]+/@ifI/g;
            s/(fe80::|fec0::)[0-9a-f:]+\/(64|128)/\1LL\/\2/g;
            s/[0-9a-fA-F]{2}(:[0-9a-fA-F]{2}){5}/MAC/g'
}

# ---- bgp restart helper (owner directive 2026-10-13, cause A) --------------
# `docker restart bgp` is BANNED on this image: the guest's bgp.service then
# stop+auto-restarts through its own systemd start-limit, and a third restart
# within the limit window trips StartLimitBurst, after which systemd refuses
# the unit outright ("failed", zero sessions — measured on leaf01,
# 2026-10-13 21:03, and only `systemctl reset-failed bgp` clears it). Every
# bgp (re)start in the spike goes through bgp_unit_restart, which:
#   1. returns 0 immediately when the expected session count is Established —
#      a restart that is not needed is never issued (issuing it is how the
#      limit got tripped);
#   2. otherwise runs `systemctl reset-failed bgp` BEFORE anything else,
#   3. starts/restarts the unit through systemd (never docker),
#   4. waits, bounded, for the expected Established count,
#   5. REFUSES (rc 1) without restarting when this node already needed two
#      restarts in the last 20 minutes — a node that needs a third is sick;
#      the caller must fail instead of looping (budget persisted across
#      processes in /tmp/g3/bgp-restart-budget, outside the proofs tree).
_bgp_expected_sessions() { case "$1" in spine*) echo 6 ;; *) echo 4 ;; esac; }

# _bgp_established <node> — Established count across families, counted the
# same way the read-only observer probe counts it (show bgp summary json).
_bgp_established() {
    node_run "$(container_of "$1")" "vtysh -c 'show bgp summary json' 2>/dev/null | tr -d ' \n' | grep -o '\"state\":\"Established\"' | wc -l" 2>/dev/null || echo 0
}

# _bgp_restart_budget_ok <node> — false when 2 restarts already happened on
# this node in the last 20 minutes (file may span chains; prune while here).
_bgp_restart_budget_ok() {
    local n=$1 f=/tmp/g3/bgp-restart-budget now cut keep
    now=$(date +%s); cut=$((now - 1200)); keep=0
    mkdir -p /tmp/g3
    touch "$f" 2>/dev/null || return 1
    : > "$f.next" 2>/dev/null || return 1
    while read -r rn rts; do
        [ -n "$rts" ] || continue
        if [ "$rts" -ge "$cut" ]; then
            echo "$rn $rts" >> "$f.next"
            [ "$rn" = "$n" ] && keep=$((keep + 1))
        fi
    done < "$f"
    mv -f "$f.next" "$f"
    [ "$keep" -lt 2 ]
}

_bgp_restart_record() {
    local n=$1 f=/tmp/g3/bgp-restart-budget
    mkdir -p /tmp/g3; echo "$n $(date +%s)" >> "$f"
}

bgp_unit_restart() {
    # bgp_unit_restart [--force] <node> — --force restarts even when the
    # expected session count is already Established (the bgpcfgd re-render
    # needs the unit restarted while sessions are up); the budget applies to
    # forced restarts too.
    local force=0
    if [[ "${1:-}" == "--force" ]]; then force=1; shift; fi
    local n=$1 c want est
    c=$(container_of "$n")
    want=$(_bgp_expected_sessions "$n")
    est=$(_bgp_established "$n")
    if [ "$force" != 1 ] && [ "${est:-0}" -ge "$want" ] 2>/dev/null; then
        return 0
    fi
    if ! _bgp_restart_budget_ok "$n"; then
        echo "LAB-SICK: bgp on $n would need a 3rd restart inside 20 min (sessions=${est:-0}/$want) — refusing; cure the node instead" >&2
        return 1
    fi
    _bgp_restart_record "$n"
    node_run "$c" "sudo systemctl reset-failed bgp 2>/dev/null; systemctl is-active bgp >/dev/null 2>&1 && sudo systemctl restart bgp 2>/dev/null || sudo systemctl start bgp 2>/dev/null" >/dev/null 2>&1 || true
    local i
    for i in $(seq 1 30); do
        est=$(_bgp_established "$n")
        [ "${est:-0}" -ge "$want" ] 2>/dev/null && return 0
        sleep 3
    done
    echo "LAB-SICK: bgp on $n did not reach $want Established after a systemd restart (got ${est:-0})" >&2
    return 1
}

# bgp_container_restart <node> — legacy name; all callers now get the systemd
# restart with the budget above (a docker restart can no longer be expressed).
bgp_container_restart() {
    local n=$1 ok i
    if bgp_unit_restart "$n"; then
        # frr must answer again before the caller re-renders/reads back
        c=$(container_of "$n")
        for i in $(seq 1 20); do
            ok=$(node_run "$c" "vtysh -c 'show version' >/dev/null 2>&1 && echo READY" 2>/dev/null || true)
            [[ "$ok" == *READY* ]] && return 0
            sleep 3
        done
        return 1
    fi
    return 1
}

# BGP summary tables carry per-session Up/Down timers ("never", "00:00:07",
# "1d03h"); nothing else in the table is timer-shaped. Normalizing those
# tokens keeps a re-run byte-identical (FR-039/SC-15) without hiding state.
bgp_norm() {
    sed -E 's/[0-9]{2}:[0-9]{2}:[0-9]{2}/UPTIME/g; s/([0-9]+[dhm])+[0-9]*/UPTIME/g;
            s/BGP table version [0-9]+/BGP table version X/g;
            s/RIB entries [0-9]+, using [0-9]+ bytes of memory/RIB entries X/g;
            # FRR summary-table counters (MsgRcvd MsgSent TblVer InQ OutQ)
            # grow between runs and carry no state; mask the five columns
            # between the AS number and the Up/Down timer.
            s/^(([0-9a-fA-F:.]+[[:space:]]+4[[:space:]]+[0-9]+)[[:space:]]+)[0-9]+([[:space:]]+[0-9]+){4}/\1C C C C C/'
}

# norm_volatile — bgp_norm plus the two kernel-route artefacts that are pure
# elapsed-time state: RA-learned route lifetimes ("expires 86348sec") and the
# time-derived RA route metric. Applied to kernel route listings.
norm_volatile() {
    bgp_norm | sed -E 's/expires [0-9]+sec/expires Xsec/g; s/metric [0-9]{8,}/metric RA/g'
}

# run_vtysh <node> <vtysh-commands...> — one SSH round trip per call group is
# slow, so batch: run_vtysh leaf01 "show ip bgp summary" "show ip route"
run_vtysh() {
    local n=$1; shift
    local args="" c
    for a in "$@"; do args+=" -c '$a'"; done
    c=$(container_of "$n")
    node_run "$c" "vtysh $args" || true
}

# The client containers are busybox images (no bash), so node_run's
# docker-exec-with-bash path cannot drive them. They are not the devices under
# test — client_run is only ever used as a traffic GENERATOR for portmap and
# service probes.
client_run() {
    local c=$1
    docker exec "$c" sh -c "$2"
}

# push_file <container> <local-file> <remote-path> — deterministic script push
# over the SSH exec channel, base64 through the ARGUMENT list. The stdin-piped
# node_run_i push truncates/corrupts intermittently on the sonic-vm guest
# (measured: /tmp/.spike_vpn_rb2.py landed as 658 truncated bytes with a
# SyntaxError, silently, behind >/dev/null — the vpn-rollback fabric restore
# then never ran and the whole-table /INTERFACE remove stood alone). base64
# has no stdin to lose; the remote side writes exactly the local bytes.
push_file() {
    local c=$1 src=$2 dst=$3 b64
    b64=$(base64 -w0 "$src") || return 1
    node_run "$c" "echo $b64 | base64 -d > $dst" >/dev/null 2>&1
}

# The per-node identity and link addressing plan. Identity is data-model.md
# §7 (spines 65000, leaf01 65101, leaf02 65102; loopbacks 10.0.0.<11,12,21,22>
# and 2001:db8:ff::<11,12,21,22>). The /31 and /127 pairs are the sonic-vs
# plan (lab/profiles/sonic-vs/bootstrap/configure-fabric-bgp.sh, FABRIC), so
# both profiles describe the same fabric. Guest port names are the SONiC
# EthernetN names (portmap proofs record the launcher-if <-> EthernetN map).
# iface,local-v4,peer-v4,peer-asn,local-v6,peer-v6;...
SPIKE_FABRIC='
spine01|65000|10.0.0.11|2001:db8:ff::11|Ethernet0,10.1.0.0,10.1.0.1,65101,2001:db8:1::3,2001:db8:1::2;Ethernet4,10.1.0.2,10.1.0.3,65102,2001:db8:1::5,2001:db8:1::4
spine02|65000|10.0.0.12|2001:db8:ff::12|Ethernet0,10.1.0.4,10.1.0.5,65101,2001:db8:2::3,2001:db8:2::2;Ethernet4,10.1.0.6,10.1.0.7,65102,2001:db8:2::5,2001:db8:2::4
leaf01|65101|10.0.0.21|2001:db8:ff::21|Ethernet0,10.1.0.1,10.1.0.0,65000,2001:db8:1::2,2001:db8:1::3;Ethernet4,10.1.0.5,10.1.0.4,65000,2001:db8:2::2,2001:db8:2::3
leaf02|65102|10.0.0.22|2001:db8:ff::22|Ethernet0,10.1.0.3,10.1.0.2,65000,2001:db8:1::4,2001:db8:1::5;Ethernet4,10.1.0.7,10.1.0.6,65000,2001:db8:2::4,2001:db8:2::5
'

# fabric_field <node> <field-index> — 2:asn 3:lo4 4:lo6 5:peers
fabric_field() {
    awk -F'|' -v n="$1" -v f="$2" '$1==n{print $f}' <<<"$SPIKE_FABRIC"
}

# Locator plan (recipe candidate): one classic /64 locator block per node cut
# from fcbb:bbbb:<node>::/48, plus the End.DT46 function space. Written by the
# spike into FRR on each node (bootstrap-owned; services never touch it).
locator_of() {
    case "$1" in
        spine01) echo "fcbb:bbbb:1::/64" ;;
        spine02) echo "fcbb:bbbb:2::/64" ;;
        leaf01)  echo "fcbb:bbbb:3::/64" ;;
        leaf02)  echo "fcbb:bbbb:4::/64" ;;
    esac
}

# ensure_bgp <node> — the sonic-vm bgp container occasionally exits cleanly
# (external SIGTERM) under heavy config churn. Every runner calls this before
# its vtysh work: if frr does not answer, bring the unit back through
# bgp_unit_restart (systemd start with reset-failed first, Established wait
# and the 2-per-20-min budget inside — NEVER a docker restart, which is what
# trips the unit's start-limit), wait for frr to answer, and re-assert the
# whole as-built state (vpn-setup.sh is the idempotent builder for it).
ensure_bgp() {
    local n=$1 c ok
    c=$(container_of "$n")
    ok=$(node_run "$c" "vtysh -c 'show version' >/dev/null 2>&1 && echo READY" 2>/dev/null || true)
    [[ "$ok" == *READY* ]] && return 0
    bgp_unit_restart "$n" || true
    for ok in $(seq 1 40); do
        ok=$(node_run "$c" "vtysh -c 'show version' >/dev/null 2>&1 && echo READY" 2>/dev/null || true)
        [[ "$ok" == *READY* ]] && break
        sleep 3
    done
    bash "$SPIKE_DIR/vpn-setup.sh" >/dev/null 2>&1 || true
    return 0
}
