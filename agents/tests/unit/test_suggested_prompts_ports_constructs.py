"""T068 [P] [US5] Suggested prompts validity test.

Every entry in agents/supervisors/provisioning/suggested_prompts.json must be a
scenario an operator can actually run on this site, not just a well-formed
sentence. That means:

- it names a construct (vlan, mac-vrf, ip-vrf, acl);
- every node and port it names resolves in FABRIC_PORT_MAP (R-06);
- it does not sit in the reserved derived-L3VLAN band, which ForNetwork
  rejects as an intent-shape error;
- and no two prompts ask for an ingress access list on the same physical port.

That last one is the difference between a list of valid sentences and a list of
working scenarios. The logical port names at this site are aliases: ethernet1
through ethernet4 all resolve to eth3, the single client-facing port on each
leaf. Two prompts naming "ethernet1" and "ethernet2" therefore land on the same
port, and the deployer's pre-flight refuses the second access list bound to a
port that already carries one at the same stage (FR-018). A suggestion set
containing both would offer the operator a scenario that is guaranteed to be
refused.
"""

from __future__ import annotations

import json
import os
import re
from pathlib import Path

CONSTRUCT = re.compile(r"\b(vlan|mac[- ]?vrf|ip[- ]?vrf|acl)\b", re.I)
NODE = re.compile(r"\b(leaf\d+|spine\d+|site-[a-z0-9-]+)\b", re.I)
PORT = re.compile(r"\b(ethernet\d+|wan\d+|eth\d+)\b", re.I)
VLAN_ID = re.compile(r"\bvlan\s+(\d+)\b", re.I)

# An access-list request: either the explicit construct or the verbs the ACL
# corpus uses. "permitting only ..." is the composed mac-vrf + ACL shape.
ACL_INTENT = re.compile(r"\b(acl|access list|permit|permitting|allow|deny)\b", re.I)
EGRESS = re.compile(r"\begress\b", re.I)

# The framing the construct vocabulary replaced (US5). These name no retired
# service, so the vocabulary guard does not see them, but they are exactly what
# the stale UI fallback said.
STALE_FRAMING = re.compile(r"\b(service[- ]types?|L2 service|L3 service)\b", re.I)

# The site map the provider actually runs with; the test may be pointed at a
# different site through FABRIC_PORT_MAP.
DEFAULT_PORT_MAP = {
    "wan1": "eth4",
    "ethernet1": "eth3",
    "ethernet2": "eth3",
    "ethernet3": "eth3",
    "ethernet4": "eth3",
    "eth1": "eth1",
    "eth2": "eth2",
    "eth3": "eth3",
    "eth4": "eth4",
}

# 4001-4094 is the derived-L3VLAN band (pkg/fabricplan): a service VLAN there is
# rejected, so a prompt must never suggest one.
L3VLAN_BASE = 4000

ROOT = Path(__file__).resolve().parents[3]
PROMPTS = ROOT / "agents" / "supervisors" / "provisioning" / "suggested_prompts.json"


def _port_map() -> dict[str, str]:
    raw = os.getenv("FABRIC_PORT_MAP") or ""
    if not raw:
        return dict(DEFAULT_PORT_MAP)
    try:
        data = json.loads(raw)
    except json.JSONDecodeError:
        return dict(DEFAULT_PORT_MAP)
    if not isinstance(data, dict):
        return dict(DEFAULT_PORT_MAP)
    return {str(k): str(v) for (k, v) in data.items()}


def _prompts() -> list[str]:
    arr = json.loads(PROMPTS.read_text(encoding="utf-8"))
    assert isinstance(arr, list) and all(isinstance(s, str) for s in arr)
    assert arr, "suggested_prompts.json is empty"
    return arr


def test_prompts_name_construct_and_ports_exist():
    pmap = _port_map()
    assert pmap, "FABRIC_PORT_MAP must be non-empty for this test"

    for s in _prompts():
        assert CONSTRUCT.search(s), f"no construct named in: {s!r}"
        assert NODE.search(s), f"no node named in: {s!r}"
        ports = PORT.findall(s)
        assert ports, f"no port named in: {s!r}"
        for p in ports:
            assert p in pmap, f"port {p!r} not in FABRIC_PORT_MAP: {s!r}"


def test_prompts_avoid_the_reserved_l3vlan_band():
    for s in _prompts():
        for vid in VLAN_ID.findall(s):
            assert int(vid) <= L3VLAN_BASE, (
                f"vlan {vid} is inside the reserved derived-L3VLAN band "
                f"({L3VLAN_BASE + 1}-4094) and would be refused: {s!r}"
            )


def test_no_two_prompts_bind_an_ingress_acl_to_the_same_port():
    """FR-018: a port carries at most one access list per stage.

    Logical port names alias onto the same physical port at this site, so the
    check resolves through FABRIC_PORT_MAP before comparing.
    """
    pmap = _port_map()
    claimed: dict[tuple[str, str], str] = {}

    for s in _prompts():
        if not ACL_INTENT.search(s):
            continue
        if EGRESS.search(s):
            continue  # a different stage cannot conflict with ingress
        nodes = [n.lower() for n in NODE.findall(s)]
        ports = {pmap[p] for p in PORT.findall(s) if p in pmap}
        for node in nodes:
            for phys in ports:
                key = (node, phys)
                prev = claimed.get(key)
                assert prev is None, (
                    f"two prompts bind an ingress access list to {node}:{phys}; "
                    f"the deployer pre-flight refuses the second.\n  first:  {prev!r}\n  second: {s!r}"
                )
                claimed[key] = s


# The UI keeps its own copy of a few prompts, shown when /suggested-prompts is
# unreachable. Nothing else checks it, and it had drifted a whole vocabulary
# behind the served set ("Create an L2 service ...", "What service types do you
# support?") — the first thing an operator saw whenever the supervisor was down.
APP_TSX = ROOT / "ui" / "src" / "App.tsx"
FALLBACK_BLOCK = re.compile(r"const fallback = useMemo\(\s*\(\)\s*=>\s*\[(.*?)\]", re.S)
QUOTED = re.compile(r"'((?:[^'\\]|\\.)*)'")


def _ui_fallback_prompts() -> list[str]:
    m = FALLBACK_BLOCK.search(APP_TSX.read_text(encoding="utf-8"))
    assert m, "could not find the suggested-prompt fallback array in ui/src/App.tsx"
    return [q.replace("\\'", "'") for q in QUOTED.findall(m.group(1))]


def test_ui_fallback_prompts_match_the_served_set():
    """The offline fallback must teach the same vocabulary as the served set.

    Three rules, because the old fallback broke all of them without naming a
    single retired service name (so the vocabulary guard never saw it):

    1. at least one entry names a construct — otherwise the surface an operator
       meets when the supervisor is down teaches no vocabulary at all;
    2. an entry that names a construct must be one of the served prompts, so it
       is covered by the port and conflict checks above;
    3. no entry may use the framing constructs replaced ("service type").
    """
    served = set(_prompts())
    fallback = _ui_fallback_prompts()
    assert fallback, "ui fallback prompt list is empty"

    named = [s for s in fallback if CONSTRUCT.search(s)]
    assert named, (
        "no ui fallback prompt names a construct; the offline surface teaches "
        f"none of the vocabulary: {fallback!r}"
    )

    for s in named:
        assert s in served, (
            "ui/src/App.tsx offers a construct prompt that is not in "
            f"suggested_prompts.json, so nothing checks it resolves here: {s!r}"
        )

    for s in fallback:
        assert not STALE_FRAMING.search(s), (
            f"ui fallback uses the framing constructs replaced: {s!r}"
        )
