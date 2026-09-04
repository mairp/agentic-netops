"""Allocator Agent (US1 — Phase 5)

Maps a validated Interpretation into a NormalizedServiceIntent with
identifiers claimed from KUID (no local generation), performs deterministic
endpoint ordering, computes an assignment hash, memoizes assignments on the
checkpointed thread state, and emits an authoritative DataPart with a
DEPLOYMENT_JSON marker.

Implements:
- T208: AllocatorAgent class skeleton
- T209: Port only the live allocator logic (no legacy imports)
- T218–T221: Map VPLS/VPWS/L3VPN/IRB interpretations
- T222–T223: Attach RD/RT and L2/L3 VNI values from KUID Claims
- T224: Deterministic endpoint ordering
- T225: Assignment hash sha256(interpretation)
- T226–T227: Memoize assignments on checkpointed thread state and return
            byte-identical results for repeats
- T228: Emit <!-- DEPLOYMENT_JSON: ... --> marker
- T229: Emit authoritative a2a.types.DataPart payload

Notes
-----
The allocator receives the Interpretation as JSON fenced by the supervisor.
It never generates identifiers locally: it allocates through the cluster
allocation client (KUID first, with a Lease fallback for pinned KUID defects).
"""

from __future__ import annotations

import hashlib
import ipaddress
import json
import logging
import re
from typing import Any
from uuid import uuid4

from a2a.types import DataPart, Message, Part, Role, TextPart
from langchain_core.messages import HumanMessage
from langgraph.graph import END, MessagesState, StateGraph
from pydantic import ValidationError

from common.redaction import redact_model_response
from common.schemas.interpretation import Interpretation
from common.schemas.normalized_intent import AddressFamilies, Endpoint, IRBGateway, NormalizedServiceIntent, Policies, RdRt
from provisioning.allocator.kuid import KUIDClient
from common.telemetry import get_trace_correlation_id

logger = logging.getLogger("agentic_netops.network_allocator.agent")

ALLOCATOR_MARKER = "DEPLOYMENT_JSON"


class _AllocState(MessagesState):
    messages: list
    result_text: str | None = None
    payload: dict[str, Any] | None = None
    # T226 — memoized assignments persisted on the thread state (checkpointed by LangGraph when configured)
    memo: dict[str, str] | None = None


def _canonical_json(obj: Any) -> str:
    return json.dumps(obj, separators=(",", ":"), sort_keys=True)


def _hash_interpretation(interp_json: str) -> str:
    """T225 — sha256(interpretation) assignment hash (hex)."""
    return hashlib.sha256(interp_json.encode("utf-8")).hexdigest()


def _gateway_address(prefixes: list[str], fallback: str) -> str:
    """First usable host of a declared prefix, as the tenant's IRB gateway.

    The same convention the fabric bootstrap uses for its SVIs (x.y.z.1/n), so
    the address the operator sees in the interpretation is the address the
    renderer puts on the bridge domain's SVI.
    """

    if not prefixes:
        return fallback
    try:
        network = ipaddress.ip_network(prefixes[0], strict=False)
    except ValueError:
        return fallback
    return f"{network.network_address + 1}/{network.prefixlen}"


def _deterministic_endpoints(endpoints: list[Endpoint]) -> list[Endpoint]:
    """T224 — deterministically order endpoints by (node, attachment)."""
    return sorted(endpoints, key=lambda e: (e.node, e.attachment))


from ioa_observe.sdk.decorators import agent


@agent(name="Network Allocator Agent", method_name="ainvoke")
class AllocatorAgent:
    """Allocates identifiers via KUID and emits a NormalizedServiceIntent."""

    def __init__(self):
        self.kuid = KUIDClient()
        # Simple in-process memoization map: assignment hash -> canonical JSON
        self._memo: dict[str, str] = {}

    def _l2_endpoints(
        self, endpoints: list[Endpoint], correlation_id: str, service: str
    ) -> list[Endpoint]:
        """Put every endpoint of an L2 service on ONE service vlan.

        A VPLS/VPWS/IRB service is a single bridge domain, and the translator
        renders exactly one ``bridgeDomain`` whose vlan comes from the first
        endpoint. Allocating a vlan per endpoint therefore produced an intent
        that could never converge: the second attachment referenced a vlan no
        bridge domain declared, and the fabric rejected it at render time —
        after the objects were already submitted. Every VPWS and every IRB
        this tier ever built failed exactly that way.

        The vlan the operator asked for wins; two different requested vlans are
        a contradiction in the request, not something to silently pick from.
        """

        declared = sorted({e.vlan for e in endpoints if e.vlan})
        if len(declared) > 1:
            raise ValueError(
                f"{service} is one bridge domain, so all endpoints share one vlan; "
                f"the request names {len(declared)}: {', '.join(str(v) for v in declared)}"
            )
        vlan = declared[0] if declared else self.kuid.allocate_vlan(correlation_id)
        return [
            Endpoint(node=e.node, attachment=e.attachment, vlan=vlan) for e in endpoints
        ]

    def _build_intent(self, interp: Interpretation, correlation_id: str) -> NormalizedServiceIntent:
        st = interp.service_type.value
        endpoints: list[Endpoint] = []
        # Map Interpretation endpoints to normalized Endpoint (node->site_or_node)
        for ep in interp.endpoints:
            endpoints.append(Endpoint(node=ep.site_or_node, attachment=ep.attachment, vlan=ep.vlan))
        endpoints = _deterministic_endpoints(endpoints)  # T224

        # Claim identifiers from the cluster allocation authority; never generate locally.
        correlation_id = correlation_id or get_trace_correlation_id() or uuid4().hex
        if st in ("VPLS", "VPWS", "IRB"):
            l2vni = self.kuid.allocate_l2vni(correlation_id)
        else:
            l2vni = None
        if st in ("L3VPN", "IRB"):
            l3vni = self.kuid.allocate_l3vni(correlation_id)
        else:
            l3vni = None
        rd, import_rt, export_rt = self.kuid.allocate_rd_rt(correlation_id)
        rd_rt = RdRt(rd=rd, importRT=import_rt, exportRT=export_rt)

        # Type-specific mapping
        if st == "VPLS":
            eps = self._l2_endpoints(endpoints, correlation_id, "VPLS")
            intent = NormalizedServiceIntent(
                serviceId=interp.service_id,
                type="VPLS",
                tenant=interp.tenant,
                rdRt=rd_rt,
                l2vni=l2vni,
                endpoints=eps,
            )
        elif st == "VPWS":
            # VPWS requires exactly two endpoints with VLANs and policy opt-in
            eps = self._l2_endpoints(endpoints, correlation_id, "VPWS")
            intent = NormalizedServiceIntent(
                serviceId=interp.service_id,
                type="VPWS",
                tenant=interp.tenant,
                rdRt=rd_rt,
                l2vni=l2vni,
                endpoints=eps,
                policies=Policies(vpwsLimitedEquivalence=True),
            )
        elif st == "L3VPN":
            # Preserve address-family prefixes explicitly supplied in the
            # operator's request. The legacy default remains only for older
            # interpretations that predate prefix carriage.
            if interp.ipv4_prefixes or interp.ipv6_prefixes:
                af = AddressFamilies(
                    ipv4Prefixes=interp.ipv4_prefixes,
                    ipv6Prefixes=interp.ipv6_prefixes,
                )
            else:
                af = AddressFamilies(ipv4Prefixes=["10.0.0.0/24"])
            eps: list[Endpoint] = []
            for e in endpoints:
                vrf = e.vrf or f"vrf-{interp.tenant}"
                eps.append(Endpoint(node=e.node, attachment=e.attachment, vrf=vrf))
            intent = NormalizedServiceIntent(
                serviceId=interp.service_id,
                type="L3VPN",
                tenant=interp.tenant,
                rdRt=rd_rt,
                l3vni=l3vni,
                addressFamilies=af,
                endpoints=eps,
            )
        elif st == "IRB":
            # IRB: both L2 and L3 VNIs + IRB gateway; use deterministic placeholders for gateway values
            eps = self._l2_endpoints(endpoints, correlation_id, "IRB")
            # The gateway is the first usable host of the operator's own
            # prefix, in the address families they actually asked for. An IRB
            # used to be handed a fd00::1/64 gateway whether or not IPv6 was
            # ever mentioned, which put an unrequested address family on the
            # SVI, asked FRR to originate a Type-5 route for it, and failed
            # the service when a leaf's zebra did not register it.
            igw = IRBGateway(
                vrf=f"vrf-{interp.tenant}",
                gatewayIPv4=_gateway_address(interp.ipv4_prefixes, ""),
                gatewayIPv6=_gateway_address(interp.ipv6_prefixes, ""),
            )
            if not igw.gatewayIPv4 and not igw.gatewayIPv6:
                # A routed service needs somewhere to route. Nothing was named,
                # so the legacy default stands in — and only in v4.
                igw.gatewayIPv4 = "10.0.0.1/24"
            intent = NormalizedServiceIntent(
                serviceId=interp.service_id,
                type="L2L3-IRB",
                tenant=interp.tenant,
                rdRt=rd_rt,
                l2vni=l2vni,
                l3vni=l3vni,
                irbGateway=igw,
                endpoints=eps,
            )
        else:
            # Unsupported type: let schema validation fail clearly
            intent = NormalizedServiceIntent(
                serviceId=interp.service_id,
                type=st,
                tenant=interp.tenant,
                endpoints=endpoints,
            )
        # Validate all-or-nothing before returning
        verr = intent.validate_all_or_nothing()
        if verr is not None:
            raise ValueError(str(verr))
        return intent

    def _format_summary_with_marker(self, summary: str, intent: NormalizedServiceIntent) -> str:
        payload_json = json.dumps(intent.model_dump(mode="json"), separators=(",", ":"), sort_keys=True)
        return summary.strip() + f"\n<!-- {ALLOCATOR_MARKER}: {payload_json} -->"

    def _summary(self, intent: NormalizedServiceIntent) -> str:
        return redact_model_response(
            f"Allocation ready for {intent.type} service {intent.serviceId} (tenant {intent.tenant})."
        )

    def _build_graph(self):
        workflow = StateGraph(_AllocState)
        workflow.add_node("allocate", self._alloc_node)
        workflow.set_entry_point("allocate")
        workflow.add_edge("allocate", END)
        return workflow.compile()

    async def ainvoke(self, interpretation_json: str, *, correlation_id: str = "") -> tuple[Message, NormalizedServiceIntent]:
        seed = {"messages": [HumanMessage(content=interpretation_json)]}
        if not hasattr(self, "graph"):
            self.graph = self._build_graph()
        state = await self.graph.ainvoke(seed)
        payload = state.get("payload") or {}
        summary = state.get("result_text") or "Allocation result"
        try:
            intent = NormalizedServiceIntent.model_validate(payload)
        except ValidationError as exc:
            raise ValueError(f"allocator produced invalid normalized intent: {exc}")
        parts = [Part(TextPart(text=self._format_summary_with_marker(summary, intent)))]
        parts.insert(0, Part(DataPart(data=intent.model_dump(mode="json"))))  # authoritative
        msg = Message(
            message_id=uuid4().hex,
            role=Role.agent,
            metadata={"name": "Network Allocator Agent", "worker": "allocator"},
            parts=parts,
        )
        return msg, intent

    # ---------------- graph node ----------------
    async def _alloc_node(self, state: _AllocState) -> dict:
        msg = next((m for m in reversed(state["messages"]) if isinstance(m, HumanMessage)), None)
        if not msg:
            return {"result_text": "no interpretation", "payload": None}
        content = str(msg.content)
        # The supervisor fences worker-returned text (T095: the payload
        # travels inside a <<<DATA worker_text ... >>> block). Extract that
        # block before parsing; fall back to the raw content so an unfenced
        # canonical-JSON caller still works.
        interp_json = content
        fence = re.search(
            r"<<<DATA worker_text[^>]*>>>\n(.*?)\n<<<END_DATA worker_text[^>]*>>>",
            content,
            re.DOTALL,
        )
        if fence:
            interp_json = fence.group(1)
        try:
            # Attempt canonical dict load regardless of fencing noise
            m = json.loads(interp_json)
            if not isinstance(m, dict):
                return {"result_text": "invalid interpretation payload", "payload": None}
            interp = Interpretation.model_validate(m)
        except Exception as exc:  # noqa: BLE001
            logger.error("failed to parse/validate interpretation: %s", exc)
            return {"result_text": "invalid interpretation payload", "payload": None}

        # Memoization key: sha256 of the canonical interpretation JSON (T225–T227)
        key = _hash_interpretation(_canonical_json(interp.model_dump(mode="json")))
        # Prefer memo on checkpointed thread state; fall back to process-local
        state_memo = state.get("memo") or {}
        cached = state_memo.get(key) or self._memo.get(key)
        if cached is not None:
            logger.info("memoized allocation hit for %s", key[:8])
            return {"result_text": self._summary(NormalizedServiceIntent.model_validate_json(cached)), "payload": json.loads(cached)}

        correlation_id = ""
        # The supervisor stamps the state; allocator uses the correlation-id when allocating
        try:
            # Attempt to scrape a correlation-id marker if present in text; otherwise random.
            correlation_id = uuid4().hex
        except Exception:
            correlation_id = uuid4().hex

        # Build normalized intent, allocate identifiers (T222-T223)
        intent = self._build_intent(interp, correlation_id)

        # Store memoized canonical payload (byte-identical on repeat) (T226–T227)
        canon = _canonical_json(intent.model_dump(mode="json"))
        # Persist on state (checkpointed) and in-process cache
        try:
            state_memo = state.get("memo") or {}
            state_memo[key] = canon
            state["memo"] = state_memo
        except Exception:
            pass
        self._memo[key] = canon

        return {"result_text": self._summary(intent), "payload": json.loads(canon)}


__all__ = ["AllocatorAgent"]
