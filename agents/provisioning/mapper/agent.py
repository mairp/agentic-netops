"""Network Mapping Agent (US1 — Phase 5)

Implements the mapper worker's core logic:

- T189: class MappingAgent skeleton in agents/provisioning/mapper/agent.py
- T190: mapper prompt loading from agents/provisioning/mapper/catalogue.json
- T191: single-node LangGraph `_map_node`
- T192: validate mapper output against Interpretation
- T198–T205/T206: generator, detection, completeness discipline, and payload emission

Notes
-----
The mapper turns plain-language requests into FR-009's published
Interpretation schema (agents/common/schemas/interpretation.py). The
Interpretation is the artifact the operator confirms at the first gate.

The subject project used an LLM-prompted mapping. This mapper is built as a
single-node LangGraph for parity with that shape and to keep the seam
consistent; the mapping itself is deterministic (regex + a small set of
heuristics) so unit tests are stable and there is no translation logic in
Python beyond the schema (FR-011 remains: the only translation to cluster
objects is the Go translator used in the deployer).

NetworkMapping shape (subject parity; citation for Interpretation docs):
- service_id (<=15 chars),
- service_type (vlan | mac-vrf | ip-vrf | acl),
- tenant (RFC 1123 label),
- endpoints: list of {site_or_node, attachment, vlan?},
- optional: bandwidth, sla,
- terminal flags: missing_fields[], unsupported_properties[] (mutually exclusive)

Data carriage (Decision 7): the DataPart is authoritative; the TextPart
contains a human summary plus the compatibility marker `<!-- MAPPED_JSON: ... -->`.
"""

from __future__ import annotations

import json
import logging
import re
from pathlib import Path
from typing import Any
from uuid import uuid4

from a2a.types import DataPart, Message, Part, Role, TextPart
from ioa_observe.sdk.decorators import agent
from langchain_core.messages import HumanMessage
from langgraph.graph import END, MessagesState, StateGraph
from pydantic import ValidationError

from common.redaction import redact_model_response
from common.schemas.interpretation import EndpointIntent, Interpretation, ServiceType

logger = logging.getLogger("agentic_netops.network_mapping.agent")

CATALOGUE_PATH = Path(__file__).resolve().parent / "catalogue.json"
MAPPER_MARKER = "MAPPED_JSON"


# -------------------- Helpers --------------------
# Order matters. "extend vlan 150 as a mac-vrf across ..." names both a
# construct and the tag it carries, and the construct is the request: the vlan
# is an attribute of the mac-vrf. With VLAN first — where it used to be — every
# overlay phrasing the tier itself suggests mapped to a plain vlan, dropping the
# EVPN service the operator asked for. VLAN is therefore matched last, exactly
# as the corpus runner's parser does.
_SERVICE_PATTERNS: list[tuple[ServiceType, list[re.Pattern[str]]]] = [
    (
        ServiceType.MAC_VRF,
        [
            re.compile(r"\bmac[- _]?vrf\b", re.I),
            re.compile(r"\bl2vpn\b|\bvpls\b|\bvpws\b|e-?line", re.I),
            re.compile(r"evpn|bridge\s+domain", re.I),
        ],
    ),
    (
        ServiceType.IP_VRF,
        [
            re.compile(r"\bip[- _]?vrf\b", re.I),
            re.compile(r"\bl3vpn\b|\blayer\s*3\b|\brouting\b|\bvrf\b", re.I),
        ],
    ),
    (
        ServiceType.ACL,
        [
            re.compile(r"\bacl\b|access[- ]list|filter", re.I),
        ],
    ),
    (
        ServiceType.VLAN,
        [
            re.compile(r"\bvlan\b", re.I),
            re.compile(r"access\s+port|untagged", re.I),
        ],
    ),
]

_UNSUPPORTED_FEATURES: list[tuple[re.Pattern[str], str]] = [
    (re.compile(r"traffic engineering|\bte[- ]policy|te[- ]path", re.I), "tePolicy"),
    # T487 — the contract's remaining §4 R6 phrasings (explicit path, SID
    # list, pin the flow): traffic engineering other than a preferred spine
    # on an SRv6 request, and the same refusal names the property.
    (re.compile(r"\bexplicit path\b|\bsid list\b|\bpin(?:ning)? the flow\b", re.I), "tePolicy"),
    (re.compile(r"pseudowire oam|\bpw oam\b|control word", re.I), "pseudowireOAM"),
    (re.compile(r"\bmulticast\b|\bpim\b|\bmsdp\b", re.I), "multicastVPN"),
    (re.compile(r"service chain\w*|chained services?", re.I), "serviceChain"),
    (re.compile(r"complex qos", re.I), "complexQoS"),
    (re.compile(r"\bcli\b|raw cli", re.I), "rawCLI"),
]

# Service types explicitly unsupported in US1 (T202): detect and flag distinctly
# from "missing". Examples: E-TREE, E-LAN, PBB-EVPN are outside the supported
# set (VPLS, VPWS, L3VPN, IRB) (migration alias)
# and must be reported as an unsupported service
# type rather than a missing service_type.
_UNSUPPORTED_SERVICE_TYPES: list[tuple[re.Pattern[str], str]] = [
    (re.compile(r"\be-?tree\b", re.I), "E-TREE"),
    (re.compile(r"\be-?lan\b", re.I), "E-LAN"),
    (re.compile(r"\bpbb[- ]?evpn\b", re.I), "PBB-EVPN"),
]

# --- SRv6 recognition (feature 004, T008; contracts/operator-phrasings.md §1)
# An SRv6 qualifier decides the TRANSPORT. Recognition runs BEFORE
# _detect_service_type and every alias/construct pattern in _SERVICE_PATTERNS:
# the SRv6 qualifier selects the SRv6 mapping below, and a legacy service name
# beside it is never enough to select a VXLAN construct (SC-008). A bare
# "segment routing" does not name SRv6 and stays with the existing patterns,
# so a refusal never claims a request named SRv6 when it did not.
_SRV6_PATTERNS: list[re.Pattern[str]] = [
    re.compile(r"\bsrv6\b", re.I),
    re.compile(r"\bsegment[- ]routing\s+over\s+ipv6\b", re.I),
    re.compile(r"\bsegment[- ]routing\s+v6\b", re.I),
]


def _detect_srv6(text: str) -> bool:
    """True when the request names SRv6 (contracts/operator-phrasings.md §1)."""
    return any(pat.search(text) for pat in _SRV6_PATTERNS)


# --- US4: the SRv6 token vocabulary (contracts/operator-phrasings.md §2/§3).
# The mapper emits TOKENS, never question or refusal prose: the supervisor
# renders every operator-facing text (the §2 question for each missing-field
# token, the §3 refusal for each terminal token).
# Clarification tokens (missing_fields):
SRV6_CONSTRUCT_FIELD = "srv6_construct"  # C1 — SRv6 named, no construct
SRV6_SIGNALLING_FIELD = "srv6_signalling"  # C2 — "EVPN over SRv6", routed/bridged unstated
SRV6_OTHER_ENDPOINT_FIELD = "srv6_other_endpoint"  # C4 — fewer than two attachments
SRV6_PREFIX_FIELD = "srv6_prefix"  # C5 — ip-vrf with no prefix
SRV6_VLAN_FIELD = "srv6_vlan"  # C6 — mac-vrf with no vlan
SRV6_PREFERRED_SPINE_FIELD = "srv6_preferred_spine"  # C7 — "prefer a spine", none named
# Terminal tokens (unsupported_properties):
SRV6_TRANSPORT_CONFLICT = "srv6TransportConflict"  # R3 — SRv6 together with VXLAN
SRV6_UNSUPPORTED_CONSTRUCT = "srv6UnsupportedConstruct"  # R5 — SRv6 with vlan/acl

# R3: vxlan/vni terms beside an SRv6 qualifier name two transports at once.
_SRV6_VXLAN_TERMS_RE = re.compile(r"\bvxlan\b|\bl[23]vni\b|\bvni\b", re.I)
_SRV6_EVPN_RE = re.compile(r"\bevpn\b", re.I)
# mac-vrf signals for an SRv6 request. Deliberately NOT the evpn pattern from
# _SERVICE_PATTERNS: "EVPN over SRv6" with no "routed"/"bridged" names no
# construct at all — it is clarification C2, not a mac-vrf.
_SRV6_MAC_VRF_RE = re.compile(r"\bmac[- _]?vrf\b|\bbridged\b|\bl2vpn\b|extend(?:ing)?\s+vlan\b", re.I)
_SRV6_IP_VRF_RE = re.compile(r"\bip[- _]?vrf\b|\brouted\b", re.I)
# The legacy routed-service aliases reuse the mapper's existing ip-vrf
# vocabulary (the contract's §1 migration-alias row) instead of
# restating it here.
_SRV6_IP_VRF_ALIAS_PATTERNS: list[re.Pattern[str]] = [
    p for st, pats in _SERVICE_PATTERNS if st is ServiceType.IP_VRF for p in pats
]
_SRV6_ACL_RE = re.compile(r"\bacl\b|access[- ]list", re.I)
# "via spine01 preferred" (contract §4) is one more preferred-spine form.
_SRV6_SPINE_VIA_RE = re.compile(r"\bvia\s+(?P<name>spine[\w.-]*)\s+preferred\b", re.I)
_SRV6_PREFER_RE = re.compile(r"\bprefer(?:ring)?\b(?P<tail>.*)", re.I)
_SRV6_SPINE_STOP = ("a", "an", "specific", "the")
_SRV6_WORD_RE = re.compile(r"[A-Za-z][\w.-]*")
# T487 — the ONE alternate form the contract names (§4): "... with spine02 as
# alternate" ("as the alternate" tolerated). The alternate is validated, not
# stored: it rides the interpretation only as far as the tier's R7.
_SRV6_ALTERNATE_RE = re.compile(
    r"\bwith\s+(?P<name>spine[\w.-]*)\s+as\s+(?:the\s+)?alternate\b", re.I
)


def _parse_alternate_spine(text: str) -> str | None:
    """The named alternate spine, or None — contract §4's single form."""
    m = _SRV6_ALTERNATE_RE.search(text)
    return m.group("name").lower() if m else None


def _parse_preferred_spine(text: str) -> tuple[str | None, bool]:
    """(spine name, preference mentioned) — contract §4.

    ``mentioned`` is True only when the request expresses a spine preference;
    ``name`` is None when none is stated ("prefer a spine") — clarification C7,
    never a guess.
    """
    m = _SRV6_SPINE_VIA_RE.search(text)
    if m:
        return m.group("name").lower(), True
    m = _SRV6_PREFER_RE.search(text)
    if m is None:
        return None, False
    words = [w for w in _SRV6_WORD_RE.findall(m.group("tail")) if w.lower() != "an"]
    spine_words = [w for w in words if w.lower().startswith("spine")]
    if not spine_words:
        return None, False
    first = words[0].lower() if words else ""
    if first in _SRV6_SPINE_STOP:
        # "prefer a spine", "prefer a specific spine": no name stated.
        named = [w for w in spine_words if w.lower() not in ("spine", "spines")]
        return (named[0].lower() if named else None), True
    w = spine_words[0].lower()
    return (None if w in ("spine", "spines") else w), True


def _detect_srv6_construct(text: str) -> tuple[ServiceType | None, str | None]:
    """(construct, terminal token) for an SRv6 request (contract §1 table).

    The token is R5's when the request names a vlan or an acl as the
    construct. The construct is None (with no token) while the service type is
    still unclear — clarification C1, or C2 when the request names EVPN
    without "routed"/"bridged".
    """
    if _SRV6_ACL_RE.search(text):
        return None, SRV6_UNSUPPORTED_CONSTRUCT
    if _SRV6_MAC_VRF_RE.search(text):
        return ServiceType.MAC_VRF, None
    if _SRV6_IP_VRF_RE.search(text) or any(
        p.search(text) for p in _SRV6_IP_VRF_ALIAS_PATTERNS
    ):
        return ServiceType.IP_VRF, None
    if _VLAN_RE.search(text):
        # A vlan named with no mac-vrf/bridged phrasing IS the construct (R5):
        # "extend vlan 100 ..." carries the vlan, "vlan 100 over srv6" asks
        # for one.
        return None, SRV6_UNSUPPORTED_CONSTRUCT
    return None, None


def _endpoint_prefix_clauses(text: str) -> list[str]:
    """The raw endpoint clause texts, in endpoint order (for per-endpoint
    prefix extraction; []-padded like the endpoints they describe)."""
    m = _ENDPOINT_BETWEEN.search(text) or _ENDPOINT_ATTACH.search(text)
    if not m:
        single = _ENDPOINT_SINGLE_ON.search(text)
        return [single.group(0)] if single else []
    return [m.group("left"), m.group("right")]


def _attach_endpoint_prefixes(
    text: str, eps: list[EndpointIntent], prefixes: list[str]
) -> list[EndpointIntent]:
    """Carry each endpoint's routed prefix on the endpoint itself
    (contracts/intent-srv6.md §2). A prefix named inside an endpoint's own
    clause stays with that endpoint; prefixes named elsewhere are distributed
    in the order they were given."""
    clauses = _endpoint_prefix_clauses(text)
    assigned: list[list[str]] = []
    for i in range(len(eps)):
        local: list[str] = []
        if i < len(clauses):
            v4, v6 = _parse_prefixes(clauses[i])
            local = v4 + v6
        if not local:
            local = prefixes[i : i + 1]
        assigned.append(local)
    return [
        ep.model_copy(update={"prefixes": local}) if local else ep
        for ep, local in zip(eps, assigned, strict=True)
    ]


def srv6_mapping(text: str) -> dict[str, Any]:
    """The deterministic SRv6 mapping (contracts/operator-phrasings.md §1–§3).

    Shared by the mapper node and the corpus harness's stub mapper so the two
    cannot drift. Returns the SRv6 interpretation fields: service_type
    (a schema-valid placeholder whenever the real construct is unknown or
    refused — the terminal flags are what route, never this value), tenant,
    endpoints, prefixes, transport/signalling/preferred_spine and the terminal
    flag lists (token vocabulary, no prose).
    """
    missing: list[str] = []
    unsupported: list[str] = []
    placeholder_eps = [EndpointIntent(site_or_node="missing", attachment="missing")]

    tenant = _detect_tenant(text)
    if not tenant:
        missing.append("tenant")
        tenant = "missing"

    def _result(
        st: ServiceType,
        *,
        eps: list[EndpointIntent] | None = None,
        v4: list[str] | None = None,
        v6: list[str] | None = None,
        transport: str | None = None,
    ) -> dict[str, Any]:
        return {
            "service_type": st,
            "tenant": tenant,
            "endpoints": placeholder_eps if eps is None else eps,
            "ipv4_prefixes": v4 or [],
            "ipv6_prefixes": v6 or [],
            "transport": transport,
            "signalling": None,
            "preferred_spine": None,
            "alternate_spine": None,
            "missing": missing,
            "unsupported": unsupported,
        }

    # R3 — SRv6 named together with VXLAN: two transports in one request, a
    # service uses one. Terminal before any construct mapping, no claim.
    if _SRV6_VXLAN_TERMS_RE.search(text):
        unsupported.append(SRV6_TRANSPORT_CONFLICT)
        return _result(ServiceType.VLAN)

    st, blocked = _detect_srv6_construct(text)
    if blocked is not None:
        # R5 — SRv6 applies to ip-vrf and mac-vrf; a vlan or an acl has no
        # transport. Terminal, no claim.
        unsupported.append(blocked)
        return _result(ServiceType.VLAN)

    transport: str | None = "srv6"
    signalling: str | None = None
    preferred_spine: str | None = None
    alternate_spine: str | None = None
    eps: list[EndpointIntent]
    v4: list[str] = []
    v6: list[str] = []

    if st is None:
        # Construct unclear: C2 when EVPN is named without routed/bridged,
        # C1 otherwise. The request named SRv6, so the transport claim is
        # honest — but signalling stays unset with the construct, and the
        # remaining checks need one, so nothing else is asked yet.
        missing.append(SRV6_SIGNALLING_FIELD if _SRV6_EVPN_RE.search(text) else SRV6_CONSTRUCT_FIELD)
        return _result(ServiceType.VLAN, transport="srv6")

    # The construct is known: fill the signalling default (contract §1).
    if st is ServiceType.MAC_VRF:
        signalling = "evpn"
    else:
        signalling = "evpn" if _SRV6_EVPN_RE.search(text) else "vpn"

    eps = list(_parse_endpoints(text))
    distinct_nodes = {ep.site_or_node.lower() for ep in eps}
    if len(eps) < 2 or len(distinct_nodes) < 2:
        # C4 — an SRv6 service joins two attachment points on distinct nodes.
        # Never the generic "endpoints" token: the supervisor asks the SRv6
        # question.
        missing.append(SRV6_OTHER_ENDPOINT_FIELD)
    while len(eps) < 1:
        eps.append(EndpointIntent(site_or_node="missing", attachment="missing"))

    if st is ServiceType.IP_VRF:
        v4, v6 = _parse_prefixes(text)
        if not v4 and not v6:
            # C5 — an ip-vrf routes; with no prefix anywhere there is nothing
            # to route.
            missing.append(SRV6_PREFIX_FIELD)
        else:
            eps = _attach_endpoint_prefixes(text, eps, v4 + v6)
    elif st is ServiceType.MAC_VRF and not _VLAN_RE.search(text):
        # C6 — a mac-vrf bridges a vlan; with no vlan anywhere there is
        # nothing to bridge.
        missing.append(SRV6_VLAN_FIELD)

    name, mentioned = _parse_preferred_spine(text)
    if mentioned:
        if name:
            preferred_spine = name
        else:
            # C7 — a preference with no spine named.
            missing.append(SRV6_PREFERRED_SPINE_FIELD)
    # T487 — the contract's single alternate form (§4). Parsed for R7
    # validation only; it is never stored past the tier (the allocator copies
    # only preferred_spine).
    alternate_spine = _parse_alternate_spine(text)

    # C1..C7 order, so the questions are asked in contract order.
    order = {
        SRV6_CONSTRUCT_FIELD: 0,
        SRV6_SIGNALLING_FIELD: 0,
        "tenant": 1,
        SRV6_OTHER_ENDPOINT_FIELD: 2,
        SRV6_PREFIX_FIELD: 3,
        SRV6_VLAN_FIELD: 4,
        SRV6_PREFERRED_SPINE_FIELD: 5,
    }
    missing.sort(key=lambda tok: order.get(tok, 9))
    return {
        "service_type": st,
        "tenant": tenant,
        "endpoints": eps,
        "ipv4_prefixes": v4,
        "ipv6_prefixes": v6,
        "transport": transport,
        "signalling": signalling,
        "preferred_spine": preferred_spine,
        "alternate_spine": alternate_spine,
        "missing": missing,
        "unsupported": unsupported,
    }

# "between A and B" and "across A and B" are the same two-attachment clause.
# "across" is the phrasing the served suggestions use for a mac-vrf, and the
# one DEFAULT_SUGGESTION and CLARIFICATION_HINT tell a refused operator to use,
# so a parser that knew only "between" answered three of the six suggested
# prompts — and its own worked example — with "Before I can map this service I
# need: endpoints", naming the endpoints the operator had just given.
_ENDPOINT_BETWEEN = re.compile(
    r"(?:between|across)\s+(?P<left>[^,;\n]+?)\s+and\s+(?P<right>[^,;\n]+)", re.I
)
_ENDPOINT_ATTACH = re.compile(
    r"\battach(?:ing)?\s+(?P<left>[^,;.\n]+?)\s+and\s+(?P<right>[^,;.\n]+)", re.I
)
# "<attachment> on <node>" — the node is ONE token: node names never contain
# whitespace, so anything past it is commentary ("... on leaf02 as an l2vpn").
# Letting the node run to end-of-clause is how "leaf02 as an l2vpn" became a
# node name the fabric could not resolve.
_ATTACHMENT_ON_NODE = re.compile(
    r"^(?P<attachment>\S+)\s+on\s+(?P<node>\S+)(?:\s.*)?$", re.I | re.DOTALL
)
# A single attachment: "on leaf01 ethernet1", "on leaf01 wan1". Three of the
# four constructs attach to one port (research.md Decision 11: vlan >=1,
# ip-vrf >=1, acl >=1, mac-vrf >=2), and without this clause every one-port
# request — "provision a vlan 130 on leaf01 ethernet1 for tenant acme", the
# first prompt the tier suggests — was answered by asking for the endpoints it
# had just been given.
# The node is any name that is not one of the words an operator puts after
# "on" when they are not naming a node ("on vlan 160", "on the fabric"); the
# attachment has to look like a port, which is what keeps this from reading
# "on 10.0.0.0/24 for tenant acme" as an endpoint.
_ENDPOINT_SINGLE_ON = re.compile(
    r"\bon\s+(?!vlan\b|the\b|a\b|an\b|its\b|both\b|each\b|all\b|every\b|port\b)"
    r"(?P<node>[A-Za-z][\w.-]*)\s+"
    r"(?P<attachment>(?:ethernet|eth|wan|port|xe|ge|te)[\w./-]*)",
    re.I,
)
_ATTACHMENT_SPLIT = re.compile(r"\s+")
_TENANT_RE = re.compile(r"tenant[:\s]+(?P<tenant>[a-z0-9-]+)", re.I)
_VLAN_RE = re.compile(r"vlan[:\s#]*(?P<vlan>\d{1,4})", re.I)
_ENDPOINT_TRAILING_CLAUSE_RE = re.compile(
    r"\s+(?:for\s+tenant|tenant|with|using)\b.*$",
    re.I,
)
_ENDPOINT_SENTENCE_END_RE = re.compile(r"[.!?](?:\s+|$).*$", re.DOTALL)
_PREFIX_TOKEN_RE = re.compile(
    r"(?<![0-9A-Za-z_:])(?P<prefix>[0-9A-Fa-f:.]+/\d{1,3})(?![0-9A-Za-z_:])"
)


class _MapState(MessagesState):
    messages: list
    result_text: str | None = None
    payload: dict[str, Any] | None = None


def _gen_service_id() -> str:
    """T198 — 15-character service identifier generator.

    The identifier is a lowercase hex prefix of a UUID4 — 15 characters,
    RFC 1123-safe (letters+digits), no punctuation.
    """
    return uuid4().hex[:15]


def _load_catalogue() -> dict[str, Any]:
    """T190 — Load mapper catalogue JSON.

    The catalogue records prompt snippets and mapping hints keyed by
    service type. The deterministic mapper does not invoke an LLM in this
    phase, but the hints and examples remain the single source of truth
    for vocabulary and guidance.
    """
    try:
        raw = CATALOGUE_PATH.read_text(encoding="utf-8")
        data = json.loads(raw)
        if not isinstance(data, dict):
            raise ValueError("catalogue.json must be a JSON object keyed by service type")
        return data
    except FileNotFoundError:
        logger.warning("mapper catalogue.json not found at %s", CATALOGUE_PATH)
        return {}
    except Exception:
        logger.exception("failed to load catalogue.json")
        return {}


def _detect_service_type(text: str) -> ServiceType | None:
    for st, pats in _SERVICE_PATTERNS:
        if any(p.search(text) for p in pats):
            return st
    return None


def _detect_unsupported_service_type(text: str) -> str | None:
    """T202 — Detect an explicitly unsupported service type.

    Returns a human label (e.g. "E-TREE") when a known unsupported type is
    present; None otherwise. This is distinct from missing service_type.
    """
    for pat, label in _UNSUPPORTED_SERVICE_TYPES:
        if pat.search(text):
            return label
    return None


def _detect_unsupported(text: str) -> list[str]:
    props: list[str] = []
    for pat, name in _UNSUPPORTED_FEATURES:
        if pat.search(text) and name not in props:
            props.append(name)
    return props


# --- access lists (US2) ---------------------------------------------------
# An interpretation whose service_type is acl MUST carry the acl block
# (contracts/interpretation.schema.json). Nothing here built one, so every acl
# request failed schema validation inside the mapper and the operator was told
# their endpoints were missing — a message about the one part of the request
# that was complete.
_ACL_STAGE_RE = re.compile(r"\b(?P<stage>ingress|egress)\b", re.I)
_ACL_PROTO_RE = re.compile(r"\b(?P<proto>tcp|udp|icmp|igmp|rsvp|gre|ah|pim|l2tp)\b", re.I)
# "port 443", "443/tcp" and the bare "tcp 443" an operator actually types.
_ACL_PORT_RE = re.compile(
    r"\bport\s+(?P<port>\d{1,5})\b"
    r"|\b(?P<slashed>\d{1,5})\s*/\s*(?:tcp|udp)\b"
    r"|\b(?:tcp|udp)\s+(?P<bare>\d{1,5})\b",
    re.I,
)
_ACL_SRC_PREFIX_RE = re.compile(r"\bfrom\s+(?P<prefix>[0-9A-Fa-f:.]+/\d{1,3})", re.I)
_ACL_DST_PREFIX_RE = re.compile(r"\bto\s+(?P<prefix>[0-9A-Fa-f:.]+/\d{1,3})", re.I)
_ACL_PERMIT_RE = re.compile(r"\b(?:permit|permitting|allow|allowing)\b", re.I)
_ACL_DENY_RE = re.compile(r"\b(?:deny|denying|drop|block)\b", re.I)
_ACL_DENY_REST_RE = re.compile(
    r"\b(?:deny|drop|block)\s+(?:everything\s+else|all\s+else|all\s+other|the\s+rest|everything|all)\b"
    r"|\bonly\b",
    re.I,
)
# A filter clause riding on another construct's request. Deliberately narrow:
# these words name a filter, and _parse_acl still has to find a rule in the
# text before anything is attached.
_ACL_FILTER_CLAUSE_RE = re.compile(
    r"\bacl\b|access[- ]list|\bpermitting\b|\bpermit\b|\ballowing\b|\ballow\b|\bdenying\b|\bdeny\b",
    re.I,
)
_ACL_V6_RE = re.compile(r"\bipv6\b|\bl3v6\b|[0-9A-Fa-f]{0,4}:[0-9A-Fa-f:]*/\d{1,3}", re.I)


def _parse_acl(text: str) -> tuple[dict[str, Any] | None, list[str]]:
    """The filter the request describes, or the fields it is missing.

    A stage and at least one rule are required; neither is ever guessed, so a
    request that names neither clarifies instead of being filled in.
    """

    missing: list[str] = []
    stage_match = _ACL_STAGE_RE.search(text)
    if stage_match is None:
        missing.append("acl.stage")

    rules: list[dict[str, Any]] = []
    proto = _ACL_PROTO_RE.search(text)
    port = _ACL_PORT_RE.search(text)
    src = _ACL_SRC_PREFIX_RE.search(text)
    dst = _ACL_DST_PREFIX_RE.search(text)
    if proto or port or src:
        rule: dict[str, Any] = {
            "name": "rule-1",
            "priority": 100,
            # An explicit permit wins: "permit tcp 443 ..., deny everything
            # else" is a permit rule plus a default deny, not a deny rule.
            "action": "permit" if _ACL_PERMIT_RE.search(text) else "deny",
        }
        if proto:
            rule["protocol"] = proto.group("proto").lower()
        if port:
            rule["destinationPort"] = port.group("port") or port.group("slashed") or port.group("bare")
        if src:
            rule["sourcePrefix"] = src.group("prefix")
        if dst:
            rule["destinationPrefix"] = dst.group("prefix")
        rules.append(rule)
    if not rules:
        missing.append("acl.rules")
    if missing:
        return None, missing

    acl: dict[str, Any] = {
        "stage": stage_match.group("stage").lower(),
        "type": "l3v6" if _ACL_V6_RE.search(text) else "l3",
        "rules": rules,
    }
    if _ACL_DENY_REST_RE.search(text) and rules[0]["action"] == "permit":
        acl["default_action"] = "deny"
    return acl, []


# --- anycast gateway (US3) ------------------------------------------------
# Naming a gateway is what makes a mac-vrf route. It is never invented and
# never dropped: an address makes the service symmetric IRB, and a gateway
# named without one is a clarification.
_GATEWAY_RE = re.compile(r"anycast\s+gateway", re.I)
_GATEWAY_ADDR_RE = re.compile(
    r"anycast\s+gateway\b[^.;]{0,24}?(?P<addr>[0-9A-Fa-f:.]+/\d{1,3}|\d{1,3}(?:\.\d{1,3}){3})",
    re.I,
)


def _parse_anycast_gateway(text: str) -> tuple[dict[str, str] | None, bool]:
    if _GATEWAY_RE.search(text) is None:
        return None, False
    m = _GATEWAY_ADDR_RE.search(text)
    if m is None:
        return None, True
    addr = m.group("addr")
    family = "ipv6" if ":" in addr else "ipv4"
    return {family: addr}, True


def _parse_endpoints(text: str) -> list[EndpointIntent]:
    m = _ENDPOINT_BETWEEN.search(text) or _ENDPOINT_ATTACH.search(text)
    if not m:
        single = _ENDPOINT_SINGLE_ON.search(text)
        if single is None:
            return []
        vlan = None
        vlan_match = _VLAN_RE.search(text)
        if vlan_match:
            try:
                vlan = int(vlan_match.group("vlan"))
            except ValueError:
                vlan = None
        endpoint = _endpoint_or_none(single.group("node"), single.group("attachment"), vlan)
        return [endpoint] if endpoint is not None else []
    left = m.group("left").strip()
    right = m.group("right").strip()
    global_vlan = None
    global_vlan_match = _VLAN_RE.search(text)
    if global_vlan_match:
        try:
            global_vlan = int(global_vlan_match.group("vlan"))
        except Exception:
            global_vlan = None

    def _endpoint(ep: str) -> EndpointIntent | None:
        vlan = None
        v = _VLAN_RE.search(ep)
        if v:
            try:
                vlan = int(v.group("vlan"))
            except Exception:
                vlan = None
        if vlan is None:
            vlan = global_vlan

        # The endpoint clause can be followed by another instruction. Stop at
        # sentence punctuation without breaking dotted attachment names such
        # as ``ethernet1.100`` (the dot there is not followed by whitespace).
        clean = _ENDPOINT_SENTENCE_END_RE.sub("", ep, count=1)
        clean = _ENDPOINT_TRAILING_CLAUSE_RE.sub("", clean)
        clean = _VLAN_RE.sub("", clean).strip(" ,.;")
        attachment_on_node = _ATTACHMENT_ON_NODE.fullmatch(clean)
        if attachment_on_node:
            return _endpoint_or_none(
                attachment_on_node.group("node"),
                attachment_on_node.group("attachment"),
                vlan,
            )
        # Bare "<node> <attachment>". Only the first two tokens are the
        # endpoint; trailing words are the next instruction, not part of a
        # name ("leaf02 wan1. Allocate the L3 VNI" is leaf02 / wan1, and
        # folding the tail into the names is what submitted an attachment
        # called "VNI" on a node called "leaf02 wan1. Allocate the L3").
        parts = [part for part in _ATTACHMENT_SPLIT.split(clean) if part]
        if len(parts) < 2:
            return None
        return _endpoint_or_none(parts[0], parts[1], vlan)

    return [endpoint for endpoint in (_endpoint(left), _endpoint(right)) if endpoint is not None]


def _endpoint_or_none(node: str, attachment: str, vlan: int | None) -> EndpointIntent | None:
    """Build an endpoint, or nothing when the text did not yield a real one.

    Node and attachment names are single tokens at every site this tier talks
    to. When what was extracted is not one, the parse failed — and returning
    None makes the mapper report ``endpoints`` as missing, so the operator is
    asked to restate the request instead of having a nonsense attachment
    submitted to the fabric on their behalf.
    """

    node = node.strip().strip(",.;:")
    attachment = attachment.strip().strip(",.;:")
    if not node or not attachment:
        return None
    if _ATTACHMENT_SPLIT.search(node) or _ATTACHMENT_SPLIT.search(attachment):
        return None
    return EndpointIntent(site_or_node=node, attachment=attachment, vlan=vlan)


def _parse_prefixes(text: str) -> tuple[list[str], list[str]]:
    """Extract and normalize IP network prefixes explicitly supplied by the operator."""

    import ipaddress

    ipv4: list[str] = []
    ipv6: list[str] = []
    for match in _PREFIX_TOKEN_RE.finditer(text):
        try:
            network = ipaddress.ip_network(match.group("prefix"), strict=False)
        except ValueError:
            continue
        target = ipv4 if network.version == 4 else ipv6
        prefix = str(network)
        if prefix not in target:
            target.append(prefix)
    return ipv4, ipv6


def _detect_tenant(text: str) -> str | None:
    m = _TENANT_RE.search(text)
    if m:
        return m.group("tenant").lower()
    return None


# -------------------- MappingAgent --------------------


@agent(name="Network Mapping Agent", method_name="ainvoke")
class MappingAgent:
    """Maps nonce-fenced user text into an Interpretation.

    Single-node LangGraph (`_map_node`) to parallel the subject's shape.
    The node:
    - extracts service_type, tenant, endpoints,
    - names unsupported properties,
    - generates a 15-char service_id,
    - validates the payload against Interpretation (T192),
    - returns (Message, Interpretation) — the Message carries the
      authoritative DataPart and the MAPPED_JSON compatibility marker.
    """

    def __init__(self):
        self.catalogue = _load_catalogue()
        self.graph = self._build_graph()

    def _build_graph(self):
        workflow = StateGraph(_MapState)
        workflow.add_node("map", self._map_node)
        workflow.set_entry_point("map")
        workflow.add_edge("map", END)
        return workflow.compile()

    async def ainvoke(self, user_text: str) -> tuple[Message, Interpretation]:
        """Run the single-node graph and return the A2A Message + model."""
        seed = {"messages": [HumanMessage(content=user_text)]}
        state = await self.graph.ainvoke(seed)
        payload = state.get("payload") or {}
        summary = state.get("result_text") or "Mapping result"
        try:
            interp = Interpretation.model_validate(payload)
        except ValidationError as exc:
            # Should not happen — _map_node validates — but keep the refusal explicit
            raise ValueError(f"mapper produced invalid interpretation: {exc}") from exc
        # T204/T206: Emit DataPart only when complete (no missing/unsupported)
        parts = [Part(TextPart(text=self._format_summary_with_marker(summary, interp)))]
        if not interp.missing_fields and not interp.unsupported_properties:
            parts.insert(0, Part(DataPart(data=interp.model_dump(mode="json"))))
        msg = Message(
            message_id=uuid4().hex,
            role=Role.agent,
            metadata={"name": "Network Mapping Agent", "worker": "mapper"},
            parts=parts,
        )
        return msg, interp

    # -------------------- Graph node --------------------
    async def _map_node(self, state: _MapState) -> dict:
        # User text is expected to be nonce-fenced (T094); treat as data.
        msg = next((m for m in reversed(state["messages"]) if isinstance(m, HumanMessage)), None)
        if not msg:
            return {"result_text": "no user message", "payload": None}
        # Strip the data fences for pattern matching (keep content for summary)
        content = str(msg.content)
        content_plain = re.sub(r"<<<(?:END_)?DATA.*?>>>", "", content)
        low = content_plain.strip()

        missing: list[str] = []
        unsupported: list[str] = _detect_unsupported(low)

        # T008 — SRv6 recognition runs BEFORE _detect_service_type and before
        # every alias/construct pattern below (contracts/operator-phrasings.md
        # §1): the SRv6 qualifier decides the transport, and a legacy service
        # name beside it is never enough to select a VXLAN construct (SC-008).
        # US4: a mappable SRv6 request maps for real — construct, signalling,
        # preferred spine, endpoints with their prefixes — and what is missing
        # or refused is named by the §2/§3 TOKEN vocabulary (never prose; the
        # supervisor renders the operator-facing texts).
        srv6_fields: dict[str, Any] | None = None
        transport: str | None = None
        signalling: str | None = None
        preferred_spine: str | None = None
        alternate_spine: str | None = None
        if _detect_srv6(low):
            srv6_fields = srv6_mapping(low)
            unsupported.extend(srv6_fields["unsupported"])
            missing.extend(srv6_fields["missing"])
            st: ServiceType | None = srv6_fields["service_type"]
            transport = srv6_fields["transport"]
            signalling = srv6_fields["signalling"]
            preferred_spine = srv6_fields["preferred_spine"]
            alternate_spine = srv6_fields["alternate_spine"]
        else:
            st = _detect_service_type(low)
            # T487 — contract §4: a preferred spine on a request that is NOT
            # SRv6 is traffic engineering (R6). The refusal names the same
            # tePolicy property the TE phrasings carry; no claim is made.
            _, spine_mentioned = _parse_preferred_spine(low)
            if spine_mentioned:
                unsupported.append("tePolicy")
        acl_block: dict[str, Any] | None = None
        gateway: dict[str, str] | None = None
        if srv6_fields is None:
            if st is None:
                # T202: check for explicitly unsupported service types (distinct from missing)
                ust = _detect_unsupported_service_type(low)
                if ust is not None:
                    unsupported.append(f"serviceType:{ust}")
                    # Coerce to a valid enum for schema validation only; terminal flag prevents routing
                    st = ServiceType.VLAN
                else:
                    # FR-004: refuse an unknown construct and list the supported constructs
                    unsupported.append("constructs: vlan, mac-vrf, ip-vrf, acl")
                    # Coerce to a valid construct for schema shape; unsupported_properties makes it terminal
                    st = ServiceType.VLAN
            tenant = _detect_tenant(low)
            if not tenant:
                missing.append("tenant")
                tenant = "missing"  # RFC 1123-valid placeholder; named in missing_fields
            eps = _parse_endpoints(low)
            # The per-construct endpoint minimum (research.md Decision 11): a
            # mac-vrf extends a bridge domain and needs two attachments; a vlan, an
            # ip-vrf and an acl are legitimately single-attachment. Requiring two of
            # everything — the feature-002 rule left in place here — made
            # "provision a vlan 130 on leaf01 ethernet1 for tenant acme"
            # unmappable.
            minimum = 2 if st is ServiceType.MAC_VRF else 1
            if len(eps) < minimum:
                missing.append("endpoints")
                # Placeholders keep the payload schema-valid; missing_fields is what
                # makes it terminal.
                while len(eps) < max(minimum, 1):
                    eps.append(EndpointIntent(site_or_node="missing", attachment="missing"))
            ipv4_prefixes, ipv6_prefixes = _parse_prefixes(low)
            # Only an ip-vrf routes prefixes. Every other construct still mentions
            # CIDRs — an anycast gateway address, an access-list match — and
            # carrying those into ipv4_prefixes put address families in the
            # proposal that the operator never asked for, next to a clarification
            # text promising that nothing is substituted for them.
            if st is not ServiceType.IP_VRF:
                ipv4_prefixes, ipv6_prefixes = [], []

            # The acl construct IS the filter; every other construct may carry one
            # that binds to its own attachment ports (contracts/interpretation.
            # schema.json: "optional on any other construct"). The composed shape —
            # "extend vlan 170 as a mac-vrf across ... , permitting only ingress tcp
            # 443 from 10.0.0.0/24" — is a suggestion this tier serves, so dropping
            # the filter clause and provisioning the bare mac-vrf would hand the
            # operator a service that forwards everything they asked to block.
            if st is ServiceType.ACL:
                acl_block, acl_missing = _parse_acl(low)
                missing.extend(acl_missing)
            elif _ACL_FILTER_CLAUSE_RE.search(low):
                attached, attached_missing = _parse_acl(low)
                if attached is not None:
                    acl_block = attached
                elif "acl.rules" not in attached_missing:
                    # A filter clause with a readable rule but no stage: ask, never
                    # guess which direction it binds.
                    missing.extend(attached_missing)

            gateway, gateway_named = _parse_anycast_gateway(low)
            if gateway_named and st is not ServiceType.MAC_VRF:
                unsupported.append("anycastGateway: only a mac-vrf carries an anycast gateway")
                gateway = None
            elif gateway_named and gateway is None:
                missing.append("anycast_gateway")
        else:
            # SRv6: srv6_mapping produced the whole interpretation — tenant,
            # endpoints (with their prefixes), construct, transport,
            # signalling, preferred spine and the terminal flags. Its
            # schema-valid placeholders ("missing") never route: the terminal
            # flags are what the supervisor reads.
            tenant = srv6_fields["tenant"]
            eps = list(srv6_fields["endpoints"])
            ipv4_prefixes = list(srv6_fields["ipv4_prefixes"])
            ipv6_prefixes = list(srv6_fields["ipv6_prefixes"])

        payload = {
            "service_id": _gen_service_id(),
            "service_type": st.value,
            "tenant": tenant,
            "endpoints": [ep.model_dump(mode="json") for ep in eps],
            "ipv4_prefixes": ipv4_prefixes,
            "ipv6_prefixes": ipv6_prefixes,
            "missing_fields": [] if unsupported else missing,
            "unsupported_properties": unsupported,
        }
        # US4: set only for an SRv6 request — a non-SRv6 payload never carries
        # these keys, so legacy interpretation dumps stay byte-identical
        # (SC-016). None values are left unset: absent, not null.
        if transport is not None:
            payload["transport"] = transport
        if signalling is not None:
            payload["signalling"] = signalling
        if preferred_spine is not None:
            payload["preferred_spine"] = preferred_spine
        if alternate_spine is not None:
            payload["alternate_spine"] = alternate_spine
        if acl_block is not None:
            payload["acl"] = acl_block
        if gateway is not None:
            payload["anycast_gateway"] = gateway

        # Optional hints (bandwidth/SLA) from catalogue keywords (best-effort)
        try:
            hints = self.catalogue.get("hints", {})
            bw_hint = hints.get("bandwidth") or []
            if any(re.compile(p, re.I).search(low) for p in bw_hint if isinstance(p, str)):
                m = re.search(r"(\d+\s?(?:gbps|g|mbps|m))", low, re.I)
                if m:
                    payload["bandwidth"] = m.group(1).replace(" ", "").lower()
        except Exception:
            pass

        # T192: validate against Interpretation; enforce mutual exclusion already in the model
        try:
            interp = Interpretation.model_validate(payload)
        except ValidationError as exc:
            # If validation fails, return the error in text and no payload
            text = f"Mapping failed schema validation: {exc}"
            logger.error("Interpretation validation failed: %s", exc)
            return {"result_text": text, "payload": None}

        # Summarize without revealing fences; redact and add marker later
        summary = self._format_human_summary(interp)
        return {"result_text": summary, "payload": interp.model_dump(mode="json")}

    # -------------------- Formatting --------------------
    def _format_human_summary(self, interp: Interpretation) -> str:
        eps = ", ".join(
            f"{e['site_or_node']} {e['attachment']}{(' vlan '+str(e['vlan'])) if e.get('vlan') else ''}"
            for e in interp.model_dump(mode="json").get("endpoints", [])
        )
        text = (
            f"Service {interp.service_type.value} for tenant {interp.tenant}: {eps}."
        )
        if interp.missing_fields:
            text += " Missing: " + ", ".join(interp.missing_fields) + "."
        if interp.unsupported_properties:
            text += " Unsupported: " + ", ".join(interp.unsupported_properties) + "."
        return redact_model_response(text)

    def _format_summary_with_marker(self, summary: str, interp: Interpretation) -> str:
        payload_json = json.dumps(interp.model_dump(mode="json"), separators=(",", ":"), sort_keys=True)
        return summary.strip() + f"\n<!-- {MAPPER_MARKER}: {payload_json} -->"


__all__ = ["MappingAgent"]
