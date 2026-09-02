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
- service_type (VPLS | VPWS | L3VPN | IRB),
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
from langchain_core.messages import HumanMessage
from langgraph.graph import END, MessagesState, StateGraph
from pydantic import ValidationError

from common.redaction import redact_model_response
from common.schemas.interpretation import EndpointIntent, Interpretation, ServiceType

logger = logging.getLogger("devnet.network_mapping.agent")

CATALOGUE_PATH = Path(__file__).resolve().parent / "catalogue.json"
MAPPER_MARKER = "MAPPED_JSON"


# -------------------- Helpers --------------------
_SERVICE_PATTERNS: list[tuple[ServiceType, list[re.Pattern[str]]]] = [
    (
        ServiceType.VPWS,
        [
            re.compile(r"\bvpws\b", re.I),
            re.compile(r"e-?line", re.I),
            re.compile(r"point[- ]to[- ]point|p2p", re.I),
        ],
    ),
    (
        ServiceType.VPLS,
        [
            re.compile(r"\bvpls\b", re.I),
            re.compile(r"full[- ]mesh|multipoint", re.I),
            re.compile(r"l2vpn", re.I),
        ],
    ),
    (
        ServiceType.L3VPN,
        [re.compile(r"\bl3vpn\b", re.I), re.compile(r"layer ?3|routing|vrf", re.I)],
    ),
    (ServiceType.IRB, [re.compile(r"\birb\b", re.I), re.compile(r"l2\+l3|integrated", re.I)]),
]

_UNSUPPORTED_FEATURES: list[tuple[re.Pattern[str], str]] = [
    (re.compile(r"traffic engineering|\bte[- ]policy|te[- ]path", re.I), "tePolicy"),
    (re.compile(r"pseudowire oam|\bpw oam\b|control word", re.I), "pseudowireOAM"),
    (re.compile(r"\bmulticast\b|\bpim\b|\bmsdp\b", re.I), "multicastVPN"),
    (re.compile(r"service chain\w*|chained services?", re.I), "serviceChain"),
    (re.compile(r"complex qos", re.I), "complexQoS"),
    (re.compile(r"\bcli\b|raw cli", re.I), "rawCLI"),
]

# Service types explicitly unsupported in US1 (T202): detect and flag distinctly
# from "missing". Examples: E-TREE, E-LAN, PBB-EVPN are outside the supported
# set (VPLS, VPWS, L3VPN, IRB) and must be reported as an unsupported service
# type rather than a missing service_type.
_UNSUPPORTED_SERVICE_TYPES: list[tuple[re.Pattern[str], str]] = [
    (re.compile(r"\be-?tree\b", re.I), "E-TREE"),
    (re.compile(r"\be-?lan\b", re.I), "E-LAN"),
    (re.compile(r"\bpbb[- ]?evpn\b", re.I), "PBB-EVPN"),
]

_ENDPOINT_BETWEEN = re.compile(
    r"between\s+(?P<left>[^,;\n]+?)\s+and\s+(?P<right>[^,;\n]+)", re.I
)
_ATTACHMENT_SPLIT = re.compile(r"\s+")
_TENANT_RE = re.compile(r"tenant[:\s]+(?P<tenant>[a-z0-9-]+)", re.I)
_VLAN_RE = re.compile(r"vlan[:\s#]*(?P<vlan>\d{1,4})", re.I)


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


def _parse_endpoints(text: str) -> list[EndpointIntent]:
    m = _ENDPOINT_BETWEEN.search(text)
    if not m:
        return []
    left = m.group("left").strip()
    right = m.group("right").strip()
    def _split(ep: str) -> tuple[str, str]:
        parts = _ATTACHMENT_SPLIT.split(ep)
        if len(parts) == 1:
            return parts[0], ""
        return " ".join(parts[:-1]).strip(), parts[-1].strip()
    l_node, l_att = _split(left)
    r_node, r_att = _split(right)
    eps: list[EndpointIntent] = []
    if l_node and l_att:
        vlan = None
        v = _VLAN_RE.search(left)
        if v:
            try:
                vlan = int(v.group("vlan"))
            except Exception:
                vlan = None
        eps.append(EndpointIntent(site_or_node=l_node, attachment=l_att, vlan=vlan))
    if r_node and r_att:
        vlan = None
        v = _VLAN_RE.search(right)
        if v:
            try:
                vlan = int(v.group("vlan"))
            except Exception:
                vlan = None
        eps.append(EndpointIntent(site_or_node=r_node, attachment=r_att, vlan=vlan))
    return eps


def _detect_tenant(text: str) -> str | None:
    m = _TENANT_RE.search(text)
    if m:
        return m.group("tenant").lower()
    return None


# -------------------- MappingAgent --------------------
from ioa_observe.sdk.decorators import agent


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
            raise ValueError(f"mapper produced invalid interpretation: {exc}")
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

        st = _detect_service_type(low)
        if st is None:
            # T202: check for explicitly unsupported service types (distinct from missing)
            ust = _detect_unsupported_service_type(low)
            if ust is not None:
                unsupported.append(f"serviceType:{ust}")
                # Coerce to a valid enum for schema validation only; terminal flag prevents routing
                st = ServiceType.VPWS
            else:
                missing.append("service_type")
                # Default to VPWS for schema validity but mark missing (no effect past confirmation)
                st = ServiceType.VPWS
        tenant = _detect_tenant(low)
        if not tenant:
            missing.append("tenant")
            tenant = "missing"  # RFC 1123-valid placeholder; named in missing_fields
        eps = _parse_endpoints(low)
        if len(eps) < 2:
            missing.append("endpoints")
            # Try to salvage at least two placeholders for schema validity
            while len(eps) < 2:
                eps.append(EndpointIntent(site_or_node="missing", attachment="missing"))

        payload = {
            "service_id": _gen_service_id(),
            "service_type": st.value,
            "tenant": tenant,
            "endpoints": [ep.model_dump(mode="json") for ep in eps],
            "missing_fields": [] if unsupported else missing,
            "unsupported_properties": unsupported,
        }

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
