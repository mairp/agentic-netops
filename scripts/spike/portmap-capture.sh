#!/usr/bin/env bash
# portmap-capture.sh <node> — spike-portmap-<node> proof body (T044-T047).
# Shows which guest port (SONiC EthernetN, and the raw QEMU NIC ethX that
# carries it) receives the traffic of each containerlab link. Decisive and
# non-disruptive: for every link of <node>, a capture runs on the guest while
# the PEER of that link pings the all-nodes multicast on its link interface;
# the capture records the interface each packet arrived on.
#
# Link table = lab/topology.sonic-vm.clab.yml; peer trigger interfaces are the
# factory-numbered SONiC ports on the switch peers and eth1 on the Linux
# client peers. tcpdump runs with -t (no timestamps) so the recorded output is
# byte-reproducible (FR-039).
set -u
. "$(dirname "$0")/spike-env.sh"

n=${1:?node required}
c=$(container_of "$n")
[[ -n "$c" && "$c" != 'C_'* ]] || { echo "unknown node '$n'" >&2; exit 2; }

# peer_trigger <node> <launcher-if> — the command that makes the peer of this
# link emit traffic on the shared segment. Switch peers ping the all-nodes
# multicast on the SONiC port that faces <node>; client peers ping on eth1.
peer_trigger() {
    case "$n/$1" in
        leaf01/eth1) node_run "$(container_of spine01)" "ping6 -c2 -I Ethernet0 ff02::1 >/dev/null 2>&1" ;;
        leaf01/eth2) node_run "$(container_of spine02)" "ping6 -c2 -I Ethernet0 ff02::1 >/dev/null 2>&1" ;;
        leaf01/eth3) client_run "$C_client01"      "ping6 -c2 -I eth1 ff02::1 2>/dev/null" ;;
        leaf01/eth4) client_run "$C_srv6_client01" "ping6 -c2 -I eth1 ff02::1 2>/dev/null" ;;
        leaf02/eth1) node_run "$(container_of spine01)" "ping6 -c2 -I Ethernet4 ff02::1 >/dev/null 2>&1" ;;
        leaf02/eth2) node_run "$(container_of spine02)" "ping6 -c2 -I Ethernet4 ff02::1 >/dev/null 2>&1" ;;
        leaf02/eth3) client_run "$C_client02"      "ping6 -c2 -I eth1 ff02::1 2>/dev/null" ;;
        leaf02/eth4) client_run "$C_srv6_client02" "ping6 -c2 -I eth1 ff02::1 2>/dev/null" ;;
        spine01/eth1) node_run "$(container_of leaf01)" "ping6 -c2 -I Ethernet0 ff02::1 >/dev/null 2>&1" ;;
        spine01/eth2) node_run "$(container_of leaf02)" "ping6 -c2 -I Ethernet0 ff02::1 >/dev/null 2>&1" ;;
        spine02/eth1) node_run "$(container_of leaf01)" "ping6 -c2 -I Ethernet4 ff02::1 >/dev/null 2>&1" ;;
        spine02/eth2) node_run "$(container_of leaf02)" "ping6 -c2 -I Ethernet4 ff02::1 >/dev/null 2>&1" ;;
        *) echo "no trigger for $n/$1" >&2 ;;
    esac
}

: "${C_client01:=clab-agentic-netops-fabric-client01}"
: "${C_client02:=clab-agentic-netops-fabric-client02}"
: "${C_srv6_client01:=clab-agentic-netops-fabric-srv6-client01}"
: "${C_srv6_client02:=clab-agentic-netops-fabric-srv6-client02}"

echo "===== $n: containerlab links (topology.sonic-vm.clab.yml) and launcher ifs ====="
node_run "$c" "ip -br link | grep -E '^eth[0-9]' | sort" || true

for if in eth1 eth2 eth3 eth4; do
    echo "===== $n link via launcher $if: capture while the peer pings ====="
    node_run "$c" "sudo -n timeout 20 tcpdump -i any -t -l -nn icmp6 >/tmp/pm-$if.cap 2>&1 &" || true
    sleep 2
    peer_trigger "$if" >/dev/null
    sleep 4
    echo "-- capture (echo packets only, id/seq normalized, unique lines) --"
    node_run "$c" "grep 'echo' /tmp/pm-$if.cap | sed -E 's/id [0-9]+, seq [0-9]+, //; s/id [0-9]+, //' | sort -u" | sed -E 's/out via [a-f0-9:]+//g' || true
    node_run "$c" "rm -f /tmp/pm-$if.cap" >/dev/null 2>&1
done

echo "===== $n: resulting map (launcher-if -> guest NIC -> SONiC port) ====="
echo "record the observed arrivals above; launcher ethN of $n maps to the raw NIC"
echo "(ethX) that received each link's packets and to the SONiC port that forwarded them"
