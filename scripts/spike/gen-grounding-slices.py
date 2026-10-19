#!/usr/bin/env python3
"""Generate p3-g-*.txt grounding slices (attempt-3 citation-budget fix).

Each slice quotes, with ORIGINAL line numbers, the decisive lines of a group
of stored proofs, plus each proof's exact stored command. The evidence cites
these slices FIRST so the critic's grounding snapshot renders them (plus the
few raw artifacts of this attempt's re-records) well inside its budget.

Attempt-7 addition: SECTIONS(node, titles, decisive) — used by the four
baseline blocks so p3-g-baseline.txt carries, per node, every
`===== <node>: … =====` section header plus the FULL `FRR routes` and
`kernel routes` sections (the route read-backs the T040–T043 acceptance
names). All other groups are unchanged by this mode.
"""
import re
from pathlib import Path

ROOT = Path("/root/agentic-netops")
PROOFS = ROOT / ".wiggum/features/004-srv6-service-requests/gates/proofs"
REL = ".wiggum/features/004-srv6-service-requests/gates/proofs"

# Whole-file mode (attempt-6 fix, T086/T093): entries set to WHOLE_FILE quote the
# ENTIRE .out with original line numbers instead of pattern-matched lines. Used
# for the two capture proofs, whose negative observation IS the whole short
# record (the "expect 0" header line plus the "0" count line) — no single
# "decisive" pattern covers a negative observation, which is why both blocks
# used to render "<no decisive lines matched>".
WHOLE_FILE = object()


# Section mode (attempt-7 fix, T040–T043): entries set to SECTIONS(node, titles,
# decisive) emit, after their decisive lines, EVERY `===== <node>: … =====`
# section header (the nine headers alone prove running config, routes and FRR
# state were all captured in that record) plus the FULL body of every section
# whose header contains one of `titles`, all with original line numbers and
# never truncated. Used by exactly the four baseline blocks.
def SECTIONS(node, titles, decisive):
    return ("SECTIONS", node, tuple(titles), decisive)


def _sections_lines(lines, node, titles):
    heads = [i for i, l in enumerate(lines)
             if l.startswith(f"===== {node}: ") and l.rstrip().endswith("=====")]
    picked = []
    for j, i in enumerate(heads):
        end = heads[j + 1] if j + 1 < len(heads) else len(lines)
        title = lines[i]
        picked.append(f"{i+1}: {title}")
        if any(t in title for t in titles):
            picked.extend(f"{k+1}: {lines[k]}" for k in range(i + 1, end))
    return picked

GROUPS = {
    "p3-g-baseline.txt": [
        ("spike-baseline-spine01", SECTIONS("spine01", ("FRR routes", "kernel routes"),
                                            r"Established|hostname|bgp_asn|CAPTURE|^\s*\d+ bytes")),
        ("spike-baseline-spine02", SECTIONS("spine02", ("FRR routes", "kernel routes"),
                                            r"Established|hostname|bgp_asn|CAPTURE")),
        ("spike-baseline-leaf01", SECTIONS("leaf01", ("FRR routes", "kernel routes"),
                                           r"Established|hostname|bgp_asn|CAPTURE")),
        ("spike-baseline-leaf02", SECTIONS("leaf02", ("FRR routes", "kernel routes"),
                                           r"Established|hostname|bgp_asn|CAPTURE")),
        ("spike-portmap-spine01", r"eth[1-4]|Ethernet\d+|icmp6"),
        ("spike-portmap-spine02", r"eth[1-4]|Ethernet\d+|icmp6"),
        ("spike-portmap-leaf01", r"eth[1-4]|Ethernet\d+|icmp6"),
        ("spike-portmap-leaf02", r"eth[1-4]|Ethernet\d+|icmp6"),
        ("spike-identity-spine01", r"hostname|bgp_asn|LOOPBACK|10\.0\.0\.|2001:db8:ff::"),
        ("spike-identity-spine02", r"hostname|bgp_asn|LOOPBACK|10\.0\.0\.|2001:db8:ff::"),
        ("spike-identity-leaf01", r"hostname|bgp_asn|LOOPBACK|10\.0\.0\.|2001:db8:ff::"),
        ("spike-identity-leaf02", r"hostname|bgp_asn|LOOPBACK|10\.0\.0\.|2001:db8:ff::"),
    ],
    "p3-g-underlay.txt": [
        ("spike-underlay-v4-spine01", r"APPLIED|/31|BGP v4 sessions|Neighbor|^10\.1\.0\.|ESTABLISHED=|session state"),
        ("spike-underlay-v4-spine02", r"APPLIED|/31|BGP v4 sessions|Neighbor|^10\.1\.0\.|ESTABLISHED=|session state"),
        ("spike-underlay-v4-leaf01", r"APPLIED|/31|BGP v4 sessions|Neighbor|^10\.1\.0\.|ESTABLISHED=|session state"),
        ("spike-underlay-v4-leaf02", r"APPLIED|/31|BGP v4 sessions|Neighbor|^10\.1\.0\.|ESTABLISHED=|session state"),
        ("spike-underlay-v4", r"TOTAL REACHABILITY|TOTAL v4 BGP|session state|ESTABLISHED=|12/12"),
        ("spike-underlay-v6-spine01", r"APPLIED|/127|BGP v6 sessions|Neighbor|ESTABLISHED=|session state"),
        ("spike-underlay-v6-spine02", r"APPLIED|/127|BGP v6 sessions|Neighbor|ESTABLISHED=|session state"),
        ("spike-underlay-v6-leaf01", r"APPLIED|/127|BGP v6 sessions|Neighbor|ESTABLISHED=|session state"),
        ("spike-underlay-v6-leaf02", r"APPLIED|/127|BGP v6 sessions|Neighbor|ESTABLISHED=|session state"),
        ("spike-underlay-v6", r"TOTAL REACHABILITY|TOTAL v6 BGP|session state|ESTABLISHED=|12/12|bgp_adv_lo_prefix_as_128"),
    ],
    "p3-g-kernel-prereq.txt": [
        ("spike-kernel-seg6", r"DECAP-DEPENDENCY|seg6_enabled|strict|received|dev Loopback0|Invalid argument"),
        ("spike-kernel-vrf-module", r"vrf|loaded|created"),
        ("spike-locator-leaf02", r"APPLIED|SRV6_MY_LOCATORS|loc-leaf02|Up"),
        ("spike-locator-spine01", r"APPLIED|SRV6_MY_LOCATORS|loc-spine01|Up"),
        ("spike-locator-spine02", r"APPLIED|SRV6_MY_LOCATORS|loc-spine02|Up"),
        ("spike-locator-all", r"APPLIED|loc-|Up|4 of 4"),
        ("spike-locator-reach", r"12 of 12|REACHABILITY|PASS"),
        ("spike-persistence", r"LOCATOR-VTYSH|kernel|reload|decap|steering|0\b"),
        ("p3-t104-fresh-redeploy", r"rc=0|provision|SUCCEED|exit"),
    ],
    "p3-g-vpn.txt": [
        ("spike-vpn-state-leaf01", r"APPLIED|Vrf1|Ethernet12|192\.168\.1\.1|field-level|\{\}"),
        ("spike-vpn-state-leaf02", r"APPLIED|Vrf1|Ethernet12|192\.168\.2\.1"),
        ("spike-vpn-clients", r"192\.168\.|2001:db8|received|gateway|APPLIED"),
        ("spike-vpn-ping", r"8900|3 received|0% packet loss|DF|probe size"),
        ("spike-vpn-capture", r"Routing header|type 4|segleft|fcbb:bbbb:4:11::|8900"),
        ("spike-vpn-rollback", r"INTERFACE-RESTORED|REMOVED /(INTERFACE|VRF)|VRF rows: none|attachment rows: none|SID rows: none|SRV6_MY_SIDS|seg6local routes: 0|Vrf1 device|loc-|Up$|locator|read back"),
        ("spike-sid-write", r"ACCEPTED|decap_vrf|not relied|leafref|bogus"),
    ],
    "p3-g-evpn3.txt": [
        ("spike-evpn3-state-leaf01", r"L3 VNI|Established|pfxRcd|Unknown command|vpn export|rd |rt "),
        ("spike-evpn3-state-leaf02", r"L3 VNI|Number of"),
        ("spike-evpn3-ping", r"100% packet loss|0 received|sanity|locator"),
        ("spike-evpn3-capture", WHOLE_FILE),
        ("spike-evpn3-kl006", r"KL-006|Type-5|Unknown|network"),
        ("spike-evpn3-rollback", r"End\.DT46|encap seg6|restored|assert"),
    ],
    "p3-g-evpn2.txt": [
        ("spike-evpn2-state-leaf01", r"L2 VNI|vxlan|Number of|IMET|\[3\]:"),
        ("spike-evpn2-state-leaf02", r"L2 VNI|Number of"),
        ("spike-evpn2-ping", r"100% packet loss|0 received|MAC-ENTRIES|Type-3 IMET"),
        ("spike-evpn2-capture", WHOLE_FILE),
        ("spike-evpn2-rollback", r"MAC-ENTRIES|restored|0 entries"),
    ],
    "p3-g-steering.txt": [
        ("spike-steering-path", r"ETH1-SRH|ETH2-SRH|NONZERO|metric 5|via 2001"),
        ("spike-steering-failover-launcher", r"LOSS-BOUNDED|missed|longest|received"),
        ("spike-steering-failover-guest-if", r"LOSS-BOUNDED|missed|longest|received"),
        ("spike-steering-failover-bgp", r"LOSS-BOUNDED|missed|longest|received"),
        ("spike-steering-return", r"LOSS-BOUNDED|PROBES|proto 196|via 2001"),
    ],
    "p3-g-rerun.txt": [
        ("spike-rerun-baseline", r"ok spike|checked, no difference"),
        ("spike-rerun-vpn", r"ok spike|skip spike|checked, no difference"),
        ("spike-rerun-evpn3", r"ok spike|checked, no difference"),
        ("spike-rerun-evpn2", r"ok spike|checked, no difference"),
        ("spike-rerun-steering", r"ok spike|checked, no difference"),
    ],
}

MAXLINES = 40

for fname, proofs in GROUPS.items():
    out = [f"# Grounding slice {fname} — decisive stored-proof lines (original line numbers)",
           "# Each block: the exact stored command (<name>.cmd) then matched lines of <name>.out.",
           ""]
    for name, pattern in proofs:
        cmdf = PROOFS / f"{name}.cmd"
        outf = PROOFS / f"{name}.out"
        out.append(f"### PROOF {REL}/{name}.cmd")
        if cmdf.exists():
            out.append(cmdf.read_text().rstrip())
        else:
            out.append("<MISSING>")
        if pattern is WHOLE_FILE:
            out.append(f"### PROOF {REL}/{name}.out (WHOLE FILE — every line, original line numbers)")
            if outf.exists():
                out.extend(f"{i+1}: {l}" for i, l in enumerate(outf.read_text().splitlines()))
            else:
                out.append("<MISSING>")
            out.append("")
            continue
        sections = None
        if isinstance(pattern, tuple) and pattern and pattern[0] == "SECTIONS":
            _, sections_node, sections_titles, pattern = pattern
            sections = (sections_node, sections_titles)
        out.append(f"### PROOF {REL}/{name}.out (decisive lines)")
        if outf.exists():
            lines = outf.read_text().splitlines()
            rx = re.compile(pattern)
            picked = [f"{i+1}: {l}" for i, l in enumerate(lines) if rx.search(l)]
            if len(picked) > MAXLINES:
                picked = picked[:MAXLINES] + [f"... ({len(picked)-MAXLINES} more matched lines not shown)"]
            out.extend(picked or ["<no decisive lines matched>"])
            if sections:
                node, titles = sections
                out.append(f"### PROOF {REL}/{name}.out (every '===== {node}: … =====' section header"
                           f" + FULL {' and '.join(titles)} sections, original line numbers)")
                sec = _sections_lines(lines, node, titles)
                out.extend(sec or ["<no sections matched>"])
        else:
            out.append("<MISSING>")
        out.append("")
    (PROOFS / fname).write_text("\n".join(out) + "\n")
    print(f"wrote {fname}: {len(out)} lines, {len(proofs)} proofs")
