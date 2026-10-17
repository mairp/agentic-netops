"""US4 — the SRv6 phrasing corpus (T621; contracts/operator-phrasings.md).

Loads EVERY ``srv6_*.yaml`` corpus file — the positive files under
``phrasings/`` and the two under ``phrasings/unsupported/`` — and checks each
case at two levels:

1. MAPPER level: the real :class:`MappingAgent` maps each case text and the
   result matches the file-stated expectation — construct, transport
   ``srv6``, signalling, preferred spine, the carried vlan/prefixes, the
   missing-field tokens (C1–C7) and the terminal unsupported tokens (R3/R5).
   For files whose variants are tier-refused on this lab (unsupported/
   srv6_transport, the non-vpn steering cases) the MAPPER assertion is still
   the mapping: the R2 refusal is tier-level only. There are no per-variant
   evpn corpus files: T471/T472 are dropped as a block (tasks.md 39-42 —
   lab/profiles/sonic-vm/srv6-supported.yaml marks ip-vrf/evpn and mac-vrf/
   evpn not-achievable), and their phrasings live as R2 cases in unsupported/
   srv6_transport.yaml (T622).
2. TIER level: the real :class:`ProvisioningGraph` (StubClassifierLLM
   returning "provisionable", StubTransport, and ``read_srv6_capability``
   monkeypatched to a proven-capable lab profile) confirms supported variants,
   refuses unsupported variants with R2, ends every clarification token in a
   clarification, and refuses the terminal tokens — each with no worker call
   beyond the mapper.

THE global assertion (SC-008), across EVERY case of EVERY srv6 file: no
resulting interpretation or mapped parameter ever carries a ``vlan``,
``mac-vrf``, ``ip-vrf`` or ``acl`` construct without ``transport == "srv6"``.
Negative controls pin the boundary: a bare "segment routing" (no v6/ipv6)
names no SRv6 and maps through the legacy VXLAN paths untouched.
"""
from __future__ import annotations

import asyncio
import json
from pathlib import Path
from uuid import uuid4

import pytest
import yaml
from langchain_core.messages import HumanMessage
from langchain_core.runnables import RunnableLambda

from common.audit import get_audit_sink, reset_audit_sink
from common.provisioning_states import NetworkProvisioningStatus
from provisioning.mapper.agent import MappingAgent, _detect_srv6
from supervisors.provisioning.graph import graph as graph_mod
from supervisors.provisioning.graph.graph import ProvisioningGraph, default_deadline
from tests.corpus.adversarial.runner import StubClassifierLLM, StubTransport
from tests.corpus.phrasings.runner import UNSUPPORTED_DIR

PHRASINGS_DIR = UNSUPPORTED_DIR.parent
# SC-008: the constructs an SRv6 request must never carry without transport
# "srv6" — on any profile, at any level of the tier.
SUPPORTED_CONSTRUCTS = ("vlan", "mac-vrf", "ip-vrf", "acl")
R2_FRAGMENT = "not supported on this image"
R3_FRAGMENT = "names both SRv6 and VXLAN"
R5_FRAGMENT = "SRv6 applies to ip-vrf and mac-vrf"


# ---------------------------------------------------------------------------
# Corpus loader (mirrors corpus/phrasings/runner.py's conventions; the
# generic unsupported runner keeps skipping srv6_* files — this test owns
# them).
# ---------------------------------------------------------------------------
def _srv6_files() -> list[Path]:
    return sorted(PHRASINGS_DIR.glob("srv6_*.yaml")) + sorted(
        UNSUPPORTED_DIR.glob("srv6_*.yaml")
    )


def load_srv6_cases() -> list[dict]:
    cases: list[dict] = []
    for path in _srv6_files():
        data = yaml.safe_load(path.read_text(encoding="utf-8"))
        for raw in data.get("cases", []):
            cases.append(
                {
                    "file": path.name,
                    "id": raw["id"],
                    "text": raw["text"],
                    # File-level defaults, per-case overrides.
                    "construct": raw.get("construct") or data.get("construct"),
                    "signalling": raw.get("signalling") or data.get("signalling"),
                    "tier": raw.get("tier") or data.get("tier") or "confirmed",
                    "expect": raw.get("expect", "map"),
                    "missing": raw.get("missing", []),
                    "unsupported": raw.get("unsupported", []),
                    "preferred_spine": raw.get("preferred_spine"),
                    "vlan": raw.get("vlan"),
                    "prefixes": raw.get("prefixes", []),
                }
            )
    assert cases, "srv6 corpus drift: no cases loaded"
    return cases


# ---------------------------------------------------------------------------
# Tier harness (test_refusal_paths.py's stand-ins, plus the proven-capable
# lab profile behind the graph.read_srv6_capability seam).
# ---------------------------------------------------------------------------
def _srv6_capability():
    try:
        from supervisors.provisioning.capability import SRv6Capability
    except Exception:  # pragma: no cover — the module is expected to exist
        @staticmethod
        def _stub(*, available, supported, verifiable_attachments):
            return type(
                "SRv6Capability",
                (),
                {
                    "available": available,
                    "supported": supported,
                    "verifiable_attachments": verifiable_attachments,
                },
            )()

        return _stub(
            available=True,
            supported=("ip-vrf/vpn", "steering"),
            verifiable_attachments=("leaf01/wan1", "leaf02/wan1"),
        )
    return SRv6Capability(
        available=True,
        supported=("ip-vrf/vpn", "steering"),
        verifiable_attachments=("leaf01/wan1", "leaf02/wan1"),
    )


async def _run_graph(text: str):
    transport = StubTransport()
    llm = StubClassifierLLM()
    reset_audit_sink()
    graph = ProvisioningGraph(
        llm_factory=lambda streaming=None: RunnableLambda(llm.ainvoke),
        transport=transport,
    )
    try:
        cid = uuid4().hex
        config = {"configurable": {"thread_id": f"srv6-{cid[:12]}"}}
        seed = {
            "messages": [HumanMessage(content=text)],
            "correlation_id": cid,
            "principal": "srv6-corpus",
            "workflow_status": NetworkProvisioningStatus.RECEIVED_REQUEST.value,
            "deadline": default_deadline(),
        }
        state = await graph.ainvoke(seed, config=config)
    finally:
        await graph.close()
    return state, transport, list(get_audit_sink().events)


def _mapped(state: dict) -> dict | None:
    raw = state.get("mapped_parameters")
    if not raw:
        return None
    try:
        return json.loads(raw)
    except Exception:  # noqa: BLE001
        return None


def _worker_stages(transport: StubTransport) -> list[str]:
    return [stage for stage, _ in transport.calls]


# ---------------------------------------------------------------------------
# Level 1 — the mapper.
# ---------------------------------------------------------------------------
def test_mapper_maps_every_srv6_case_to_its_file_expectation():
    failures: list[str] = []
    agent = MappingAgent()
    for case in load_srv6_cases():
        _msg, interp = asyncio.run(agent.ainvoke(case["text"]))
        v: list[str] = []
        dump = interp.model_dump(mode="json")

        if case["unsupported"]:
            # Terminal (R3/R5): the token, nothing missing, and NO claim —
            # no transport, no signalling, no spine, no endpoint prefixes.
            if interp.unsupported_properties != case["unsupported"]:
                v.append(
                    f"unsupported {interp.unsupported_properties!r} != expected "
                    f"{case['unsupported']!r}"
                )
            if interp.missing_fields:
                v.append(f"terminal case also clarifies: {interp.missing_fields!r}")
            for key in ("transport", "signalling", "preferred_spine"):
                if dump.get(key) is not None:
                    v.append(f"terminal case claims {key}={dump[key]!r}")
        else:
            if interp.unsupported_properties:
                v.append(f"unexpected unsupported: {interp.unsupported_properties!r}")
            if dump.get("transport") != "srv6":
                v.append(f"transport {dump.get('transport')!r} != 'srv6' (SC-008)")
            if case["construct"] and interp.service_type.value != case["construct"]:
                v.append(
                    f"construct {interp.service_type.value!r} != {case['construct']!r}"
                )
            if case["signalling"] and dump.get("signalling") != case["signalling"]:
                v.append(
                    f"signalling {dump.get('signalling')!r} != {case['signalling']!r}"
                )
            if case["expect"] == "clarify":
                if interp.missing_fields != case["missing"]:
                    v.append(
                        f"missing_fields {interp.missing_fields!r} != {case['missing']!r}"
                    )
            elif interp.missing_fields:
                v.append(f"unexpected clarification: {interp.missing_fields!r}")
            if case["preferred_spine"] and dump.get("preferred_spine") != case["preferred_spine"]:
                v.append(
                    f"preferred_spine {dump.get('preferred_spine')!r} != "
                    f"{case['preferred_spine']!r}"
                )
            if case["vlan"] is not None:
                for ep in interp.endpoints:
                    if ep.vlan != case["vlan"]:
                        v.append(f"endpoint {ep.site_or_node} vlan {ep.vlan!r} != {case['vlan']!r}")
            if case["prefixes"]:
                carried = sorted(
                    p for ep in interp.endpoints for p in (ep.prefixes or [])
                ) + sorted(interp.ipv4_prefixes) + sorted(interp.ipv6_prefixes)
                for want in case["prefixes"]:
                    if want not in carried:
                        v.append(f"prefix {want!r} not carried (carried {carried!r})")

        if v:
            failures.append(f"{case['file']}/{case['id']}: " + "; ".join(v))
    assert not failures, "mapper-level SRv6 corpus failures:\n  " + "\n  ".join(failures)


def test_mapper_emits_only_the_token_vocabulary_for_srv6():
    """The mapper emits TOKENS, never prose: every missing/unsupported entry
    on an SRv6 result is one of the fixed §2/§3 tokens (the supervisor
    renders the operator-facing texts)."""
    tokens = {
        "srv6_construct",
        "srv6_signalling",
        "srv6_other_endpoint",
        "srv6_prefix",
        "srv6_vlan",
        "srv6_preferred_spine",
        "tenant",
        "srv6TransportConflict",
        "srv6UnsupportedConstruct",
    }
    agent = MappingAgent()
    for case in load_srv6_cases():
        _msg, interp = asyncio.run(agent.ainvoke(case["text"]))
        for tok in interp.missing_fields + interp.unsupported_properties:
            assert tok in tokens, f"{case['file']}/{case['id']}: non-token {tok!r}"


def test_negative_controls_bare_segment_routing_is_not_srv6():
    """A bare "segment routing" (no v6/ipv6) names no SRv6: it must not set
    transport srv6, must not emit an SRv6 token, and must map through the
    legacy VXLAN paths untouched."""
    texts = [
        "extend vlan 100 as a mac-vrf across leaf01 ethernet1 and leaf02 ethernet1 for tenant acme",
        "use segment routing for tenant acme's vlan 100 across leaf01 ethernet1 and leaf02 ethernet1",
        "give tenant acme an ip-vrf carrying 10.50.0.0/24 between leaf01 wan1 and leaf02 wan1",
    ]
    srv6_tokens = {
        "srv6_construct",
        "srv6_signalling",
        "srv6_other_endpoint",
        "srv6_prefix",
        "srv6_vlan",
        "srv6_preferred_spine",
        "srv6TransportConflict",
        "srv6UnsupportedConstruct",
    }
    for text in texts:
        assert not _detect_srv6(text), f"false recognition: {text!r}"
        _msg, interp = asyncio.run(MappingAgent().ainvoke(text))
        dump = interp.model_dump(mode="json")
        assert dump.get("transport") is None, f"{text!r} set transport srv6"
        hit = [t for t in interp.missing_fields + interp.unsupported_properties if t in srv6_tokens]
        assert not hit, f"{text!r} emitted SRv6 tokens {hit!r}"


# ---------------------------------------------------------------------------
# Level 2 — the tier.
# ---------------------------------------------------------------------------
def test_tier_confirms_refuses_and_clarifies_per_file(monkeypatch):
    if not hasattr(graph_mod, "read_srv6_capability"):
        pytest.skip(
            "tier-level SRv6 coverage pending the graph seam: "
            "supervisors.provisioning.graph.graph.read_srv6_capability is not "
            "landed yet (the parallel graph worker's change)"
        )
    monkeypatch.setattr(graph_mod, "read_srv6_capability", _srv6_capability)
    failures: list[str] = []
    for case in load_srv6_cases():
        state, transport, events = asyncio.run(_run_graph(case["text"]))
        v: list[str] = []
        status = state.get("workflow_status")
        pending = state.get("pending_action")
        stages = _worker_stages(transport)
        mapped = _mapped(state)

        # SC-008, EVERY case: no construct without transport srv6, anywhere.
        if mapped is not None:
            st = str(mapped.get("service_type") or "")
            if st in SUPPORTED_CONSTRUCTS and mapped.get("transport") != "srv6":
                v.append(
                    f"SC-008: mapped_parameters carries {st!r} with "
                    f"transport {mapped.get('transport')!r}"
                )

        # Every SRv6 path stops at the mapper: no allocator, no deployer,
        # nothing claimed before the operator confirms (or the refusal lands).
        if stages and stages != ["mapper"]:
            v.append(f"worker calls beyond the mapper: {stages!r}")

        tier = case["tier"]
        if tier == "confirmed":
            if status != NetworkProvisioningStatus.MAPPED.value or pending != "confirm_1":
                v.append(f"expected confirm_1, got status={status!r} pending={pending!r}")
            if state.get("refusal_reason"):
                v.append(f"unexpected refusal: {state.get('refusal_reason')!r}")
            if not state.get("awaiting_confirmation"):
                v.append("confirmation gate not raised")
            if not mapped or mapped.get("transport") != "srv6":
                v.append("no srv6 mapped_parameters at the confirmation point")
        elif tier == "r2_refused":
            if status != NetworkProvisioningStatus.FAILED.value:
                v.append(f"expected FAILED (R2), got status={status!r} pending={pending!r}")
            reason = state.get("refusal_reason") or ""
            if R2_FRAGMENT not in reason:
                v.append(f"refusal is not R2: {reason!r}")
            if mapped is not None:
                v.append("mapped_parameters accepted on an R2 refusal")
            if not any(e.event_type == "refuse" for e in events):
                v.append("no 'refuse' AuditEvent for the R2 refusal")
        elif tier == "clarify":
            if status != NetworkProvisioningStatus.MAPPED.value or pending != "clarify":
                v.append(f"expected clarify, got status={status!r} pending={pending!r}")
            if not state.get("missing_fields"):
                v.append("no missing_fields recorded on the clarification")
            if not state.get("awaiting_confirmation"):
                v.append("clarification is not awaiting the operator")
            if mapped is not None and mapped.get("missing_fields") is None:
                v.append("mapped_parameters not redacted for the clarification")
        elif tier == "terminal_refusal":
            if status != NetworkProvisioningStatus.FAILED.value:
                v.append(f"expected FAILED (terminal), got status={status!r} pending={pending!r}")
            reason = state.get("refusal_reason") or ""
            if R3_FRAGMENT not in reason and R5_FRAGMENT not in reason:
                v.append(f"refusal is neither R3 nor R5: {reason!r}")
            if mapped is not None:
                v.append("mapped_parameters accepted on a terminal refusal")
        else:
            v.append(f"unknown tier expectation {tier!r}")

        if v:
            failures.append(f"{case['file']}/{case['id']}: " + "; ".join(v))
    assert not failures, "tier-level SRv6 corpus failures:\n  " + "\n  ".join(failures)


def test_tier_negative_control_segment_routing_is_vxlan(monkeypatch):
    """The negative controls stay VXLAN end to end: no SRv6 transport, no
    SRv6 tokens, and the plain mac-vrf reaches the confirmation point."""
    if not hasattr(graph_mod, "read_srv6_capability"):
        pytest.skip(
            "tier-level SRv6 coverage pending the graph seam: "
            "supervisors.provisioning.graph.graph.read_srv6_capability is not "
            "landed yet (the parallel graph worker's change)"
        )
    monkeypatch.setattr(graph_mod, "read_srv6_capability", _srv6_capability)
    state, transport, _events = asyncio.run(
        _run_graph(
            "extend vlan 100 as a mac-vrf across leaf01 ethernet1 and leaf02 ethernet1 for tenant acme"
        )
    )
    assert state.get("pending_action") == "confirm_1"
    mapped = _mapped(state)
    assert mapped is not None
    assert mapped.get("service_type") == "mac-vrf"
    assert "transport" not in mapped, f"negative control set transport {mapped.get('transport')!r}"
