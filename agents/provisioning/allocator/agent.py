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
from ioa_observe.sdk.decorators import agent
from langchain_core.messages import HumanMessage
from langgraph.graph import END, MessagesState, StateGraph
from pydantic import ValidationError

from common.redaction import redact_model_response
from common.schemas.interpretation import Interpretation
from common.schemas.normalized_intent import (
    ACL,
    AddressFamilies,
    AnycastGateway,
    Endpoint,
    NormalizedServiceIntent,
    RdRt,
)
from common.telemetry import get_trace_correlation_id
from provisioning.allocator.kuid import KUIDClient

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

    @staticmethod
    def _normalized_acl(interp: Interpretation) -> ACL | None:
        """The interpretation's filter in the normalized contract's wire names.

        The two contracts differ by one field name (``default_action`` here is
        ``defaultAction`` there). Any construct may carry a filter bound to its
        own attachment ports, so this is applied to every branch below — a
        mac-vrf requested "permitting only ingress tcp port 443" must reach the
        deployer with that filter, not as a bare bridge domain.
        """

        if interp.acl is None:
            return None
        data = interp.acl.model_dump(mode="json", exclude_none=True)
        if "default_action" in data:
            data["defaultAction"] = data.pop("default_action")
        return ACL.model_validate(data)

    def _build_intent(self, interp: Interpretation, correlation_id: str) -> NormalizedServiceIntent:
        st = interp.service_type.value
        acl = self._normalized_acl(interp)
        endpoints: list[Endpoint] = []
        # Map Interpretation endpoints to normalized Endpoint (node->site_or_node)
        for ep in interp.endpoints:
            endpoints.append(Endpoint(node=ep.site_or_node, attachment=ep.attachment, vlan=ep.vlan))
        endpoints = _deterministic_endpoints(endpoints)  # T224

        # Claim identifiers from the cluster allocation authority; never generate locally.
        correlation_id = correlation_id or get_trace_correlation_id() or uuid4().hex
        # Per-construct claim profiles (contracts/kuid-claim-profiles.md §2)
        # - vlan: claim VLAN only (and none when operator named one)
        # - mac-vrf: claim VLAN (unless named) + L2VNI + RT; L3VNI only with anycastGateway
        # - ip-vrf: claim L3VNI + RT
        # - acl: no claims
        l2vni = None
        l3vni = None
        rd_rt: RdRt | None = None

        # Type-specific mapping
        if st == "vlan":
            # Resolve L2 endpoints on ONE vlan; allocate from KUID only if not named
            # Determine if operator named a VLAN on any endpoint
            named_vlan = any(e.vlan for e in endpoints)
            eps = self._l2_endpoints(endpoints, correlation_id, "vlan")
            if not named_vlan:
                # _l2_endpoints allocated one VLAN via KUIDClient
                pass
            intent = NormalizedServiceIntent(
                serviceId=interp.service_id,
                type="vlan",
                acl=acl,
                tenant=interp.tenant,
                endpoints=eps,
            )
        elif st == "mac-vrf":
            # Claim L2VNI + RT; VLAN claimed unless operator named one.
            # L3VNI is claimed only when the operator asked the mac-vrf to
            # route (anycast gateway): routing is composition, not implication
            # (contracts/kuid-claim-profiles.md §2, US3 T056).
            eps = self._l2_endpoints(endpoints, correlation_id, "mac-vrf")
            l2vni = self.kuid.allocate_l2vni(correlation_id)
            rd, import_rt, export_rt = self.kuid.allocate_rd_rt(correlation_id)
            rd_rt = RdRt(rd=rd, importRT=import_rt, exportRT=export_rt)
            gateway = None
            if interp.anycast_gateway is not None:
                l3vni = self.kuid.allocate_l3vni(correlation_id)
                gateway = AnycastGateway(
                    gatewayIPv4=interp.anycast_gateway.ipv4 or "",
                    gatewayIPv6=interp.anycast_gateway.ipv6 or "",
                )
            intent = NormalizedServiceIntent(
                serviceId=interp.service_id,
                type="mac-vrf",
                acl=acl,
                tenant=interp.tenant,
                rdRt=rd_rt,
                l2vni=l2vni,
                l3vni=l3vni,
                anycastGateway=gateway,
                endpoints=eps,
            )
        elif st == "ip-vrf":
            # Preserve operator-supplied address families when present (v4 default otherwise)
            if interp.ipv4_prefixes or interp.ipv6_prefixes:
                af = AddressFamilies(
                    ipv4Prefixes=interp.ipv4_prefixes,
                    ipv6Prefixes=interp.ipv6_prefixes,
                )
            else:
                af = AddressFamilies(ipv4Prefixes=["10.0.0.0/24"])
            # Map endpoints to VRF-carrying attachments; default VRF label derived from tenant
            eps: list[Endpoint] = []
            for e in endpoints:
                vrf = e.vrf or f"vrf-{interp.tenant}"
                eps.append(Endpoint(node=e.node, attachment=e.attachment, vrf=vrf))
            l3vni = self.kuid.allocate_l3vni(correlation_id)
            rd, import_rt, export_rt = self.kuid.allocate_rd_rt(correlation_id)
            rd_rt = RdRt(rd=rd, importRT=import_rt, exportRT=export_rt)
            intent = NormalizedServiceIntent(
                serviceId=interp.service_id,
                type="ip-vrf",
                acl=acl,
                tenant=interp.tenant,
                rdRt=rd_rt,
                l3vni=l3vni,
                addressFamilies=af,
                endpoints=eps,
            )
        elif st == "acl":
            # Standalone ACL: binds to ports; allocator does not claim identifiers.
            # The filter itself must travel with the intent — dropping it here
            # (which is what this branch did) submitted an access-list service
            # carrying no access list, and the operator's rules never reached
            # the fabric. The wire names differ by one field: the
            # interpretation's ``default_action`` is ``defaultAction`` here.
            intent = NormalizedServiceIntent(
                serviceId=interp.service_id,
                type="acl",
                tenant=interp.tenant,
                acl=acl,
                endpoints=endpoints,
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

    async def ainvoke(
        self, interpretation_json: str, *, correlation_id: str = ""
    ) -> tuple[Message, NormalizedServiceIntent]:
        seed = {"messages": [HumanMessage(content=interpretation_json)]}
        if not hasattr(self, "graph"):
            self.graph = self._build_graph()
        state = await self.graph.ainvoke(seed)
        payload = state.get("payload") or {}
        summary = state.get("result_text") or "Allocation result"
        try:
            intent = NormalizedServiceIntent.model_validate(payload)
        except ValidationError as exc:
            raise ValueError(f"allocator produced invalid normalized intent: {exc}") from exc
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
            return {
                "result_text": self._summary(NormalizedServiceIntent.model_validate_json(cached)),
                "payload": json.loads(cached),
            }

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
