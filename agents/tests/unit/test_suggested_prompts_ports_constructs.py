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


def test_ui_fallback_list_is_identical_to_the_served_list():
    """US6/T542: the offline fallback is the served list, entry for entry.

    Three prompts said the old rule was enough — the fallback then kept three
    stale entries while the served set moved to eight, and an operator who
    lost the supervisor saw a different product from one who did not. The
    fallback must not merely agree with the served set, it must BE it.
    """
    served = _prompts()
    fallback = _ui_fallback_prompts()
    assert fallback == served, (
        "ui/src/App.tsx's offline fallback is not the served list "
        "(agents/supervisors/provisioning/suggested_prompts.json). "
        f"Only in the fallback: {[s for s in fallback if s not in served]!r}; "
        f"only served: {[s for s in served if s not in fallback]!r}"
    )


# The deployment mounts a ConfigMap over the JSON file baked into the image, so
# deploy/agents/supervisor.yaml — not agents/.../suggested_prompts.json — is
# what /suggested-prompts actually returns. Editing only the file changes
# nothing at runtime, which is how the served set stayed on VPWS/VPLS/L3VPN/IRB
# long after the vocabulary migration: every one of those is answered by the
# mapper with "unknown or unsupported service type".
SUPERVISOR_MANIFEST = ROOT / "deploy" / "agents" / "supervisor.yaml"


def _configmap_prompts() -> list[str]:
    text = SUPERVISOR_MANIFEST.read_text(encoding="utf-8")
    marker = "suggested_prompts.json: |"
    i = text.index(marker) + len(marker)
    block: list[str] = []
    for line in text[i:].splitlines()[1:]:
        if line.strip() == "---":
            break
        if line.strip() and not line.startswith("    "):
            break
        block.append(line.strip())
    return json.loads("\n".join(block))


def test_configmap_prompts_match_the_served_file():
    assert _configmap_prompts() == _prompts(), (
        "deploy/agents/supervisor.yaml and "
        "agents/supervisors/provisioning/suggested_prompts.json disagree. The "
        "ConfigMap is mounted over the file, so the ConfigMap is what operators "
        "actually get; the file alone changes nothing."
    )


# A prompt only reaches the provisioning path if the supervisor classifies it as
# a provisioning request. When the LLM classifier is unavailable or its reply is
# unparseable, that decision falls to two regexes in graph.py: one for the
# action verb, one for the construct. A suggested prompt that misses either is
# answered with "unknown or unsupported service type" — the suggestion the
# product itself offered, refused by the product itself.
#
# The patterns are read out of graph.py rather than imported, so this runs
# without the supervisor's runtime dependencies, and out of the source rather
# than copied, so it cannot drift from what actually classifies.
GRAPH_PY = ROOT / "agents" / "supervisors" / "provisioning" / "graph" / "graph.py"


def _fallback_patterns() -> tuple[re.Pattern[str], re.Pattern[str]]:
    src = GRAPH_PY.read_text(encoding="utf-8")

    def grab(name: str) -> re.Pattern[str]:
        m = re.search(
            rf"^{name} = re\.compile\(\s*\n\s*r\"(.+?)\",\s*\n\s*re\.I,\s*\n\)",
            src,
            re.M | re.S,
        )
        assert m, f"could not read {name} out of graph.py"
        return re.compile(m.group(1), re.I)

    return grab("_FALLBACK_PROVISION_ACTION"), grab("_FALLBACK_SERVICE_TYPE")


def test_every_prompt_classifies_as_a_provisioning_request():
    action, service = _fallback_patterns()
    for s in _prompts():
        assert action.search(s), (
            "no recognised action verb, so the supervisor's fallback classifier "
            f"refuses this with 'unknown or unsupported service type': {s!r}"
        )
        assert service.search(s), f"no recognised construct in: {s!r}"


def test_the_refusal_suggestion_itself_classifies():
    """DEFAULT_SUGGESTION tells the operator how to rephrase; that phrasing must work."""
    action, service = _fallback_patterns()
    src = GRAPH_PY.read_text(encoding="utf-8")
    m = re.search(r"DEFAULT_SUGGESTION = \(\s*(.*?)\)\n", src, re.S)
    assert m, "could not read DEFAULT_SUGGESTION out of graph.py"
    suggestion = " ".join(re.findall(r'"([^"]*)"', m.group(1)))
    for example in re.findall(r"'([^']+)'", suggestion):
        assert action.search(example) and service.search(example), (
            "the refusal suggests a phrasing its own fallback classifier rejects: "
            f"{example!r}"
        )


# ---------------------------------------------------------------------------
# US6 (T536/T537): every SRv6 example the tier offers is one this lab has
# proven it can carry (the (V:x) rule, tasks.md lines 39-42), on attachments a
# probe client can verify (R9). An example outside either set is a suggestion
# the product itself guarantees to refuse.
# ---------------------------------------------------------------------------
SRV6 = re.compile(r"\bsrv6\b", re.I)
EVPN = re.compile(r"\bevpn\b", re.I)
MAC_VRF = re.compile(r"\bmac[- ]?vrf\b", re.I)
IP_VRF = re.compile(r"\bip[- ]?vrf\b", re.I)
ATTACHMENT = re.compile(r"\b(leaf\d+|spine\d+)\s+(ethernet\d+|wan\d+|eth\d+)\b", re.I)

SRV6_SUPPORTED_YAML = ROOT / "lab" / "profiles" / "sonic-vm" / "srv6-supported.yaml"
PROVISION_SH = ROOT / "scripts" / "provision.sh"


def _verdicts() -> dict[str, str]:
    """``{variant: status}`` out of srv6-supported.yaml.

    The same ``- name:`` / ``status:`` rows scripts/lib/capability.sh parses
    to derive the srv6-supported capability key, read here without a YAML
    dependency so the check runs anywhere the rest of this module does.
    """
    verdicts: dict[str, str] = {}
    in_verdicts = False
    name = ""
    for raw in SRV6_SUPPORTED_YAML.read_text(encoding="utf-8").splitlines():
        line = raw.rstrip()
        if re.match(r"^verdicts:\s*$", line):
            in_verdicts = True
            continue
        if in_verdicts and line and not line[0].isspace():
            break  # the next top-level key (honest_negatives, ...) ends the table
        if not in_verdicts:
            continue
        m = re.match(r"\s*- name:\s*(\S+)\s*$", line)
        if m:
            name = m.group(1)
            continue
        m = re.match(r"\s*status:\s*(\S+)\s*$", line)
        if m and name:
            verdicts[name] = m.group(1)
            name = ""
    assert verdicts, f"no verdict rows parsed out of {SRV6_SUPPORTED_YAML}"
    return verdicts


def _probe_attachments() -> set[str]:
    """The attachments a first-activation check can run from: the keys of the
    executor's FABRIC_PROBE_MAP, read out of scripts/provision.sh — the single
    source the compat-pins generation publishes as srv6-probe-attachments
    (T605) and the controller's rule C8 reads (spec KL-009)."""
    m = re.search(r"FABRIC_PROBE_MAP='(\{[^']*\})'", PROVISION_SH.read_text(encoding="utf-8"))
    assert m, "could not read FABRIC_PROBE_MAP out of scripts/provision.sh"
    keys = set(json.loads(m.group(1)).keys())
    assert keys, "FABRIC_PROBE_MAP in scripts/provision.sh registers no probe host"
    return keys


def _srv6_variant(prompt: str) -> str:
    """The (construct, signalling) variant an SRv6 prompt asks for, named the
    way srv6-supported.yaml names it. EVPN beside ip-vrf is ip-vrf/evpn; a
    mac-vrf is always mac-vrf/evpn (contract §1's signalling default)."""
    if MAC_VRF.search(prompt):
        return "mac-vrf/evpn"
    if IP_VRF.search(prompt):
        return "ip-vrf/evpn" if EVPN.search(prompt) else "ip-vrf/vpn"
    raise AssertionError(f"SRv6 prompt names no supported construct: {prompt!r}")


def test_no_srv6_prompt_outside_the_proven_verdicts():
    """The (V:x) rule: no example is written for an unproven variant.

    ip-vrf/evpn and mac-vrf/evpn are `not-achievable` on this profile (spike
    proofs spike-evpn3-* / spike-evpn2-*): the R2 guard refuses them by name.
    A suggested prompt for either is a scenario guaranteed to be refused.
    """
    verdicts = _verdicts()
    proven = {v for v, status in verdicts.items() if status == "proven"}
    assert {"ip-vrf/vpn", "steering"} <= proven, (
        "this test models the site as having proven ip-vrf/vpn and steering; "
        f"srv6-supported.yaml now records {sorted(verdicts.items())}"
    )
    srv6_prompts = [s for s in _prompts() if SRV6.search(s)]
    assert srv6_prompts, "expected at least one served SRv6 example"
    for s in srv6_prompts:
        variant = _srv6_variant(s)
        assert verdicts.get(variant) == "proven", (
            f"the tier offers an example for {variant}, which "
            f"srv6-supported.yaml records as {verdicts.get(variant)!r}: an "
            f"operator who clicks it is refused by name (R2, spec FR-005): {s!r}"
        )
    for s in _prompts():
        assert not (SRV6.search(s) and EVPN.search(s)), (
            f"a served prompt names evpn over srv6; ip-vrf/evpn and mac-vrf/evpn "
            f"are not-achievable on this profile (spike-evpn3-*, spike-evpn2-*): {s!r}"
        )


def test_every_srv6_prompt_resolves_to_attachments_with_a_probe_host():
    """R9 (T623/T624), fail-closed: an SRv6 request whose attachments cannot
    be verified is refused before anything is claimed. An ip-vrf over srv6
    only reaches Ready through the wan1 attachments the probe clients sit on
    — so the examples must name exactly those."""
    pmap = _port_map()
    probes = {a.lower() for a in _probe_attachments()}
    srv6_prompts = [s for s in _prompts() if SRV6.search(s)]
    assert srv6_prompts, "expected at least one served SRv6 example"
    for s in srv6_prompts:
        atts = ATTACHMENT.findall(s)
        assert atts, f"SRv6 prompt names no node/attachment pair: {s!r}"
        for node, port in atts:
            assert port.lower() in pmap, f"port {port!r} not in FABRIC_PORT_MAP: {s!r}"
            assert f"{node.lower()}/{port.lower()}" in probes, (
                f"{node}/{port} has no registered probe host "
                f"(FABRIC_PROBE_MAP: {sorted(probes)}), so the graph's R9 check "
                f"refuses this example before anything is claimed: {s!r}"
            )
