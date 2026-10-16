#!/usr/bin/env bash
# Read-only capture inside the sonic-vm leaf01 guest (feature 004, T229/T264):
# the two nexthops to the peer VTEP, the multipath hash policy, and the absence
# of any port- or mark-keyed flow split (ebtables chain, fwmark rule, mangle MARK).
# Uses the suite's own guest path (tests/integration/lib/node_exec.sh node_run),
# not `docker exec` into the vrnetlab launcher. Changes nothing.
set -u
cd "$(dirname "${BASH_SOURCE[0]}")/../.."
# shellcheck source=tests/integration/lib/node_exec.sh
source tests/integration/lib/node_exec.sh
C=clab-agentic-netops-fabric-leaf01
node_is_vm "$C" || { echo "leaf01 is not a sonic-vm guest; this capture is for sonic-vm only"; exit 2; }
S="$(node_sudo "$C")"
echo "--- peer-VTEP route (10.0.0.22) ---"
node_run "$C" "ip route show 10.0.0.22"
echo "--- fib_multipath_hash_policy ---"
node_run "$C" "cat /proc/sys/net/ipv4/fib_multipath_hash_policy"
echo "--- ip rule (expect no fwmark rule) ---"
node_run "$C" "$S ip rule"
echo "fwmark rules: $(node_run "$C" "$S ip rule" | grep -c fwmark)"
echo "--- ebtables chains named AGNT* (expect 0) ---"
echo "ebtables AGNT chains: $(node_run "$C" "$S ebtables -t filter -L 2>/dev/null; $S ebtables -t broute -L 2>/dev/null; $S ebtables -t nat -L 2>/dev/null" | grep -c AGNT)"
echo "--- iptables mangle MARK rules (expect 0) ---"
echo "mangle MARK rules: $(node_run "$C" "$S iptables -t mangle -S 2>/dev/null" | grep -ci mark)"
