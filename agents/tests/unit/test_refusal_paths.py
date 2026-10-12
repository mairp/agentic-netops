"""US2 unit tests — the refusal paths (T126-T129).

Four test groups, one per task:

* T126 ``TestClassifier`` — the three-way classifier: the enum vocabulary,
  the defensive reply parsing, and the ``_supervisor_node`` wiring
  (T085/T089): provisionable -> mapper, informational -> general_info,
  unsupported -> refusal, unparseable -> never a worker.
* T127 ``TestDirectActionRefusal`` — the deterministic direct-device layer
  (T090) refuses BEFORE any model call (a "bomb" LLM proves the model is
  never reached), every refusal is explained with a declarative
  equivalent (T091), and the refusal is terminal (T092).
* T128 ``TestMalformedPayloadRejection`` — out-of-contract mapper/
  allocator payloads (unknown fields, missing endpoints, malformed
  markers, stage type mismatch) are rejected BEFORE any further routing
  (T096-T102): FAILED at END, no worker beyond the failing stage, the
  operator told the payload was rejected before routing.
* T129 ``TestNoClusterClientOnRefusal`` — a refusal touches nothing:
  zero worker calls, zero socket connections (no device session, no
  cluster API), and the deployer's structural submission preconditions
  (T124/T125) refuse without ever calling the deployer worker; the graph
  module itself imports no Kubernetes client.

All tests run the REAL graph (``graph/graph.py``); only the LLM and the
worker transport are harness stand-ins.
"""

from __future__ import annotations

import inspect
import sys

import pytest
from langchain_core.messages import AIMessage, HumanMessage
from langchain_core.runnables import RunnableLambda

from common.audit import reset_audit_sink
from common.provisioning_states import NetworkProvisioningStatus
from common.schemas.normalized_intent import NormalizedServiceIntent
from supervisors.provisioning.graph import graph as graph_mod
from supervisors.provisioning.graph.graph import (
    ProvisioningGraph,
    canonical_json,
    default_deadline,
    detect_direct_device,
    parse_classification,
)
from supervisors.provisioning.graph.shared import RequestClassification
from supervisors.provisioning.prompts.system import REFUSAL_EXPLANATION
from tests.corpus.adversarial.runner import (
    DeviceSessionRecorder,
    StubClassifierLLM,
    StubTransport,
    build_normalized_intent,
    parse_service_request,
)

CLEAN_REQUEST = (
    "extend vlan 100 as a mac-vrf across leaf01 ethernet1 and leaf02 ethernet2 for tenant acme"
)


# ---------------------------------------------------------------------------
# Shared harness.
# ---------------------------------------------------------------------------
class FixedWordLLM:
    """Returns one fixed classifier word; counts calls."""

    def __init__(self, word: str) -> None:
        self.word = word
        self.calls = 0

    async def ainvoke(self, input, config=None):
        self.calls += 1
        return AIMessage(content=self.word)


class BombLLM:
    """Raises if the model is ever called — proves a refusal happened
    before any model call (T090 'first line of code')."""

    calls = 0

    async def ainvoke(self, input, config=None):
        BombLLM.calls += 1
        raise AssertionError("the model must not be called for a deterministic refusal")


def _seed(text: str, cid: str = "a" * 32) -> dict:
    return {
        "messages": [HumanMessage(content=text)],
        "correlation_id": cid,
        "principal": "unit-test",
        "workflow_status": NetworkProvisioningStatus.RECEIVED_REQUEST.value,
        "deadline": default_deadline(),
    }


def _config(thread: str = "unit-thread") -> dict:
    return {"configurable": {"thread_id": thread}}


async def _run(text: str, llm, transport=None, thread: str = "unit-thread") -> dict:
    reset_audit_sink()
    graph = ProvisioningGraph(
        llm_factory=lambda streaming=None: RunnableLambda(llm.ainvoke),
        transport=transport or StubTransport(),
    )
    try:
        return await graph.ainvoke(_seed(text), config=_config(thread))
    finally:
        await graph.close()


async def _run_turn2(prev_state: dict, text: str, llm, transport) -> dict:
    """Second turn on the same thread (the confirmation flow)."""
    graph = ProvisioningGraph(
        llm_factory=lambda streaming=None: RunnableLambda(llm.ainvoke),
        transport=transport,
    )
    try:
        config = _config("unit-thread-2")
        # The thread from _run used thread "unit-thread"; re-seed the
        # continuation on a fresh thread by carrying the mapped state.
        seed = {
            **prev_state,
            "messages": [HumanMessage(content=text)],
        }
        return await graph.ainvoke(seed, config=config)
    finally:
        await graph.close()


def _last_ai(state: dict) -> str:
    for msg in reversed(state.get("messages", [])):
        if isinstance(msg, AIMessage):
            return msg.content
    return ""


def _refuses(state_sink_events) -> list:
    return [e for e in state_sink_events if e.event_type == "refuse"]


# ---------------------------------------------------------------------------
# T126 — classifier tests.
# ---------------------------------------------------------------------------
class TestClassifier:
    def test_classifier_enum_is_the_three_way_vocabulary(self):
        assert set(RequestClassification) == {
            RequestClassification.PROVISIONABLE,
            RequestClassification.INFORMATIONAL,
            RequestClassification.UNSUPPORTED,
        }
        assert {c.value for c in RequestClassification} == {"provisionable", "informational", "unsupported"}

    @pytest.mark.parametrize("word,cls", [
        ("provisionable", RequestClassification.PROVISIONABLE),
        ("informational", RequestClassification.INFORMATIONAL),
        ("unsupported", RequestClassification.UNSUPPORTED),
    ])
    def test_parse_classification_exact_word(self, word, cls):
        assert parse_classification(word) is cls

    def test_parse_classification_standalone_token(self):
        assert parse_classification("The class is provisionable.") is RequestClassification.PROVISIONABLE
        assert parse_classification("UNSUPPORTED.") is RequestClassification.UNSUPPORTED

    @pytest.mark.parametrize("garbage", ["", "banana", "I refuse to answer", "provision"])
    def test_parse_classification_garbage_never_a_class(self, garbage):
        assert parse_classification(garbage) is None

    async def test_wiring_provisionable_routes_to_mapper(self):
        llm = FixedWordLLM("provisionable")
        transport = StubTransport()
        state = await _run(CLEAN_REQUEST, llm, transport)
        assert llm.calls == 1
        assert state.get("classification") == "provisionable"
        assert state.get("workflow_status") == NetworkProvisioningStatus.MAPPED.value
        assert [c[0] for c in transport.calls] == ["mapper"]
        assert state.get("awaiting_confirmation") is True

    async def test_wiring_informational_routes_to_general_info(self):
        llm = FixedWordLLM("informational")
        transport = StubTransport()
        state = await _run("what service types can you provision?", llm, transport)
        assert state.get("classification") == "informational"
        assert transport.calls == []
        assert "I provision declarative network services" in _last_ai(state)

    async def test_wiring_unsupported_refuses(self):
        llm = FixedWordLLM("unsupported")
        transport = StubTransport()
        reset_audit_sink()
        state = await _run(CLEAN_REQUEST, llm, transport)
        assert state.get("workflow_status") == NetworkProvisioningStatus.FAILED.value
        assert state.get("next_node") == "__end__"
        assert "supported constructs" in (state.get("refusal_reason") or "")
        for c in ("vlan", "mac-vrf", "ip-vrf", "acl"):
            assert c in (state.get("refusal_reason") or "")
        assert transport.calls == []
        from common.audit import get_audit_sink

        assert _refuses(get_audit_sink().events)

    async def test_unparseable_reply_never_routes_to_a_worker(self):
        llm = FixedWordLLM("banana")
        transport = StubTransport()
        state = await _run(CLEAN_REQUEST, llm, transport)
        assert transport.calls == []
        assert state.get("workflow_status") != NetworkProvisioningStatus.FAILED.value
        all_ai = "\n".join(m.content for m in state.get("messages", []) if isinstance(m, AIMessage))
        assert "could not classify" in all_ai.lower()
        assert state.get("classification") is None

    async def test_two_constructs_in_one_request_refused(self):
        llm = FixedWordLLM("provisionable")
        transport = StubTransport()
        text = (
            "provision a vlan and an ip-vrf between leaf01 ethernet1 and leaf02 ethernet2 for tenant acme"
        )
        state = await _run(text, llm, transport)
        assert state.get("workflow_status") == NetworkProvisioningStatus.FAILED.value
        assert "one construct per request" in (state.get("refusal_reason") or "")
        for c in ("vlan", "mac-vrf", "ip-vrf", "acl"):
            assert c in (state.get("refusal_reason") or "")
        assert transport.calls == []

    async def test_unavailable_provider_uses_narrow_informational_fallback(self):
        class UnavailableLLM:
            async def ainvoke(self, input, config=None):
                raise RuntimeError("provider offline")

        transport = StubTransport()
        state = await _run("what service types can you provision?", UnavailableLLM(), transport)
        assert state.get("workflow_status") == NetworkProvisioningStatus.COMPLETED.value
        assert state.get("classification") == RequestClassification.INFORMATIONAL.value
        assert "I provision declarative network services" in _last_ai(state)
        assert transport.calls == []

    async def test_unavailable_provider_fails_closed_for_ambiguous_request(self):
        class UnavailableLLM:
            async def ainvoke(self, input, config=None):
                raise RuntimeError("provider offline")

        transport = StubTransport()
        state = await _run("please handle this request", UnavailableLLM(), transport)
        assert state.get("workflow_status") == NetworkProvisioningStatus.FAILED.value
        assert "model provider" in (state.get("refusal_reason") or "").lower()
        assert transport.calls == []


# ---------------------------------------------------------------------------
# T127 — direct-action refusal tests.
# ---------------------------------------------------------------------------
class TestDirectActionRefusal:
    @pytest.mark.parametrize("text,family", [
        ("ssh into leaf01", "direct device access (SSH/CLI/console)"),
        ("scp the backup to the switch", "direct device access (SSH/CLI/console)"),
        ("telnet to leaf02", "direct device access (SSH/CLI/console)"),
        ("open a console port session on leaf01", "direct device access (SSH/CLI/console)"),
        ("log in to leaf01", "direct device access (SSH/CLI/console)"),
        ("reboot the switch leaf02", "direct action on a device"),
        ("just fix leaf01", "direct action on a device"),
        ("push the config to the leaves", "direct configuration write to a device"),
        ("dial gNMI on leaf01", "device control protocol (RESTCONF/NETCONF/gNMI)"),
        ("use netconf on the node", "device control protocol (RESTCONF/NETCONF/gNMI)"),
    ])
    def test_detect_direct_device_families(self, text, family):
        hit = detect_direct_device(text)
        assert hit is not None, text
        assert hit.family == family
        assert hit.reason and hit.suggestion  # T091: reason + declarative equivalent

    async def test_refusal_happens_before_any_model_call(self):
        BombLLM.calls = 0
        llm = BombLLM()
        transport = StubTransport()
        state = await _run("ssh into leaf01 and run 'show ip interfaces'", llm, transport)
        assert BombLLM.calls == 0  # the bomb never fired
        assert state.get("workflow_status") == NetworkProvisioningStatus.FAILED.value
        assert state.get("next_node") == "__end__"
        assert "direct device access" in (state.get("refusal_reason") or "")
        assert REFUSAL_EXPLANATION in _last_ai(state)  # T091: explained
        assert transport.calls == []
        from common.audit import get_audit_sink

        events = _refuses(get_audit_sink().events)
        assert events and all(e.reason for e in events)  # T103/T105

    async def test_refusal_is_terminal_across_turns(self):
        llm = StubClassifierLLM()
        transport = StubTransport()
        reset_audit_sink()
        graph = ProvisioningGraph(
            llm_factory=lambda streaming=None: RunnableLambda(llm.ainvoke),
            transport=transport,
        )
        try:
            config = _config("terminal-thread")
            state = await graph.ainvoke(_seed("ssh into leaf01"), config=config)
            assert state.get("workflow_status") == NetworkProvisioningStatus.FAILED.value
            state = await graph.ainvoke({"messages": [HumanMessage(content="now do it anyway")]}, config=config)
            assert state.get("workflow_status") == NetworkProvisioningStatus.FAILED.value
            assert transport.calls == []
        finally:
            await graph.close()

    async def test_unsupported_feature_refusal_names_the_property(self):
        llm = FixedWordLLM("provisionable")  # the model's word must not matter
        transport = StubTransport()
        state = await _run(
            "extend vlan 100 as a mac-vrf across leaf01 ethernet1 and leaf02 ethernet2 for tenant acme "
            "with a traffic engineering policy",
            llm,
            transport,
        )
        assert state.get("workflow_status") == NetworkProvisioningStatus.FAILED.value
        assert "tePolicy" in (state.get("refusal_reason") or "")
        # The suggestion offers the nearest construct by its construct name (FR-023)
        msg = _last_ai(state)
        assert any(x in msg for x in ["mac-vrf", "ip-vrf"])
        assert transport.calls == []


# ---------------------------------------------------------------------------
# T010 — the interim SRv6 refusal (feature 004, plan 1-07).
# ---------------------------------------------------------------------------
class TestSRv6InterimRefusal:
    """T010 — an SRv6 phrasing reaches refusal R1 and is not diverted.

    A request naming SRv6 must be refused terminally with R1
    (contracts/operator-phrasings.md §3): "SRv6 services are not available
    yet. This request names SRv6, so it is not provisioned as a VXLAN
    service." — rendered by the mapper node from the mapper's
    ``srv6Transport`` result (T008/T009). The CLASSIFIER must not divert the
    request into a different refusal (direct-device, unsupported-feature) or
    a clarification, because the refusal the operator sees must be R1.
    Passes (for the stated reason that the classifier routes SRv6 to the
    provisioning path and the mapper node renders R1 — T011 pins the
    prompt-side rule this relies on for a production LLM).
    """

    @pytest.mark.asyncio
    async def test_srv6_request_reaches_refusal_r1(self):
        llm = StubClassifierLLM()
        transport = StubTransport()
        state = await _run(
            "give tenant acme an ip-vrf over SRv6 carrying 10.50.0.0/24 "
            "between leaf01 wan1 and leaf02 wan1",
            llm,
            transport,
        )
        assert state.get("workflow_status") == NetworkProvisioningStatus.FAILED.value
        reason = state.get("refusal_reason") or ""
        # R1 itself — not a different refusal, not a clarification (FR-003)
        assert reason.startswith("SRv6 services are not available yet")
        assert "not provisioned as a VXLAN service" in reason
        assert "unsupported properties" not in reason
        msg = _last_ai(state)
        assert "I can't do that." in msg
        assert REFUSAL_EXPLANATION in msg
        assert "Try instead:" in msg
        # terminal at the failing stage: the mapper is consulted (R1 renders
        # from its srv6Transport result), but NO worker beyond it — nothing
        # is allocated or deployed (FR-030, SC-008)
        assert [stage for stage, _ in transport.calls] == ["mapper"]
        from common.audit import get_audit_sink

        assert _refuses(get_audit_sink().events)
        # nothing was accepted for confirmation on an SRv6 request (SC-008)
        assert not state.get("mapped_parameters")
        assert state.get("pending_action") in (None, "")

    @pytest.mark.asyncio
    async def test_bare_srv6_request_not_diverted_to_informational(self):
        """A bare "SRv6 service" names no construct — the classifier's
        escape hatch to INFORMATIONAL must not fire for it (T011)."""
        llm = StubClassifierLLM()
        transport = StubTransport()
        state = await _run("provision an SRv6 service for tenant acme", llm, transport)
        assert state.get("workflow_status") == NetworkProvisioningStatus.FAILED.value
        assert "SRv6 services are not available yet" in (state.get("refusal_reason") or "")
        assert state.get("pending_action") in (None, "")
        assert [stage for stage, _ in transport.calls] == ["mapper"]

    def test_classifier_prompt_routes_srv6_to_provisioning(self):
        """T011 — the production classifier prompt carries the SRv6 rule
        (route a request naming SRv6 to the provisioning path so the
        mapper's R1 refusal is what the operator sees)."""
        from supervisors.provisioning.prompts.system import CLASSIFIER_PROMPT

        low = CLASSIFIER_PROMPT.lower()
        assert "srv6" in low
        assert "provisionable" in low


# ---------------------------------------------------------------------------
# T128 — malformed payload rejection tests.
# ---------------------------------------------------------------------------
class _FixedPayloadTransport(StubTransport):
    """Returns fixed (possibly malformed) payloads per stage."""

    def __init__(self, mapper_payload=None, allocator_payload=None, mapper_text="", allocator_text=""):
        super().__init__()
        self._mapper_payload = mapper_payload
        self._allocator_payload = allocator_payload
        self._mapper_text = mapper_text
        self._allocator_text = allocator_text

    async def call_mapper(self, text: str):
        self.calls.append(("mapper", text))
        if self._mapper_payload is not None:
            return {"parts": [{"data": self._mapper_payload}, {"text": self._mapper_text or "ok"}]}
        return {"parts": [{"text": self._mapper_text}]}

    async def call_allocator(self, text: str):
        self.calls.append(("allocator", text))
        if self._allocator_payload is not None:
            return {"parts": [{"data": self._allocator_payload}, {"text": self._allocator_text or "ok"}]}
        return {"parts": [{"text": self._allocator_text}]}


def _valid_vpws_interpretation() -> dict:
    return parse_service_request(CLEAN_REQUEST)


def _valid_vpws_intent(interpretation: dict) -> dict:
    return build_normalized_intent(interpretation)


class TestMalformedPayloadRejection:
    async def test_mapper_unknown_field_rejected_before_routing(self):
        payload = _valid_vpws_interpretation()
        payload["bogusField"] = 1  # extra="forbid" on Interpretation
        transport = _FixedPayloadTransport(mapper_payload=payload)
        state = await _run(CLEAN_REQUEST, StubClassifierLLM(), transport)
        assert state.get("workflow_status") == NetworkProvisioningStatus.FAILED.value
        assert state.get("next_node") == "__end__"
        assert "mapper payload out of contract" in (state.get("refusal_reason") or "")
        assert "rejected before any further routing" in _last_ai(state)
        assert [c[0] for c in transport.calls] == ["mapper"]  # allocator never called

    async def test_mapper_single_endpoint_rejected(self):
        # The interpretation schema carries min_length 1 (a vlan or an acl
        # binds to one port), so the per-construct minimum fires where the
        # construct is known: a gatewayless mac-vrf needs >=2 endpoints, and
        # the refusal names exactly that at the allocator boundary (T024).
        payload = _valid_vpws_interpretation()
        payload["endpoints"] = payload["endpoints"][:1]
        ep = payload["endpoints"][0]
        intent = {
            "serviceId": payload["service_id"],
            "type": "mac-vrf",
            "tenant": payload["tenant"],
            "rdRt": {
                "rd": f"64512:{ep['vlan']}",
                "importRT": [f"64512:{ep['vlan']}"],
                "exportRT": [f"64512:{ep['vlan']}"],
            },
            "l2vni": 10004,
            "endpoints": [
                {"node": ep["site_or_node"], "attachment": ep["attachment"], "vlan": ep["vlan"]}
            ],
        }
        NormalizedServiceIntent.model_validate(intent)  # schema-valid alone...
        assert intent["endpoints"][0]["node"]  # ...the construct rule is what fires
        transport = _FixedPayloadTransport(mapper_payload=payload, allocator_payload=intent)
        state = await _run(CLEAN_REQUEST, StubClassifierLLM(), transport)
        assert state.get("workflow_status") == NetworkProvisioningStatus.MAPPED.value  # confirm point
        state = await _run_turn2(state, "confirm", StubClassifierLLM(), transport)
        assert state.get("workflow_status") == NetworkProvisioningStatus.FAILED.value
        assert "allocator payload out of contract" in (state.get("refusal_reason") or "")
        assert "mac-vrf requires >=2 endpoints" in (state.get("refusal_reason") or "")
        assert [c[0] for c in transport.calls] == ["mapper", "allocator"]

    async def test_mapper_no_payload_rejected(self):
        transport = _FixedPayloadTransport(mapper_text="Interpretation ready but no payload.")
        state = await _run(CLEAN_REQUEST, StubClassifierLLM(), transport)
        assert state.get("workflow_status") == NetworkProvisioningStatus.FAILED.value
        assert "no structured payload found" in (state.get("refusal_reason") or "")
        assert [c[0] for c in transport.calls] == ["mapper"]

    async def test_mapper_malformed_marker_rejected(self):
        transport = _FixedPayloadTransport(
            mapper_text='Interpretation ready.\n<!-- MAPPED_JSON: {"service_id": "svc-00000000", '
        )
        state = await _run(CLEAN_REQUEST, StubClassifierLLM(), transport)
        assert state.get("workflow_status") == NetworkProvisioningStatus.FAILED.value
        assert "no structured payload found" in (state.get("refusal_reason") or "")
        assert "MAPPED_JSON" in (state.get("refusal_reason") or "")

    async def test_allocator_unknown_field_rejected(self):
        intent = _valid_vpws_intent(_valid_vpws_interpretation())
        intent["unexpected"] = True
        transport = _FixedPayloadTransport(
            mapper_payload=_valid_vpws_interpretation(),
            allocator_payload=intent,
        )
        state = await _run(CLEAN_REQUEST, StubClassifierLLM(), transport)
        assert state.get("workflow_status") == NetworkProvisioningStatus.MAPPED.value  # confirm point
        state = await _run_turn2(state, "confirm", StubClassifierLLM(), transport)
        assert state.get("workflow_status") == NetworkProvisioningStatus.FAILED.value
        assert "allocator payload out of contract" in (state.get("refusal_reason") or "")
        assert [c[0] for c in transport.calls] == ["mapper", "allocator"]

    async def test_allocator_type_mismatch_rejected(self):
        # A schema-valid ip-vrf intent for a mac-vrf interpretation: the stage
        # type-match rule (data-model.md §3) rejects it. Both halves speak the
        # construct vocabulary now — the VPWS request folds to mac-vrf, and an
        # ip-vrf payload is valid alone but names a different construct than
        # the one the operator confirmed.
        intent = _valid_vpws_intent(_valid_vpws_interpretation())
        intent = {
            "serviceId": intent["serviceId"],
            "type": "ip-vrf",
            "tenant": intent["tenant"],
            "rdRt": intent["rdRt"],
            "l3vni": 13410,
            "addressFamilies": {"ipv4Prefixes": ["10.250.0.0/16"]},
            "endpoints": [
                {"node": e["node"], "attachment": e["attachment"], "vrf": f"vrf-{intent['tenant']}"}
                for e in intent["endpoints"]
            ],
        }
        NormalizedServiceIntent.model_validate(intent).validate_all_or_nothing()  # sanity: valid alone
        transport = _FixedPayloadTransport(
            mapper_payload=_valid_vpws_interpretation(),
            allocator_payload=intent,
        )
        state = await _run(CLEAN_REQUEST, StubClassifierLLM(), transport)
        assert state.get("workflow_status") == NetworkProvisioningStatus.MAPPED.value  # confirm point
        state = await _run_turn2(state, "confirm", StubClassifierLLM(), transport)
        assert state.get("workflow_status") == NetworkProvisioningStatus.FAILED.value
        assert "type mismatch between stages" in (state.get("refusal_reason") or "")

    async def test_rejection_routes_to_end_not_reflection(self):
        transport = _FixedPayloadTransport(mapper_payload={"not": "an interpretation"})
        graph = ProvisioningGraph(
            llm_factory=lambda streaming=None: RunnableLambda(StubClassifierLLM().ainvoke),
            transport=transport,
        )
        reset_audit_sink()
        try:
            nodes = []
            async for update in graph.astream(_seed(CLEAN_REQUEST), config=_config()):
                nodes.extend(update.keys())
            assert "allocator" not in nodes
            assert "deployer" not in nodes
            assert "reflection" not in nodes
            assert "mapper" in nodes  # the failing stage ran; nothing after it
        finally:
            await graph.close()


# ---------------------------------------------------------------------------
# T129 — no-cluster-client-on-refusal tests.
# ---------------------------------------------------------------------------
class TestNoClusterClientOnRefusal:
    async def test_no_socket_connections_on_direct_device_refusal(self):
        recorder = DeviceSessionRecorder()
        llm = StubClassifierLLM()
        transport = StubTransport()
        reset_audit_sink()
        graph = ProvisioningGraph(
            llm_factory=lambda streaming=None: RunnableLambda(llm.ainvoke),
            transport=transport,
        )
        try:
            with recorder:
                state = await graph.ainvoke(_seed("ssh into leaf01"), config=_config())
        finally:
            await graph.close()
        assert state.get("workflow_status") == NetworkProvisioningStatus.FAILED.value
        assert recorder.attempts == []  # no device session, no cluster API
        assert transport.calls == []

    async def test_no_socket_connections_on_unsupported_refusal(self):
        recorder = DeviceSessionRecorder()
        llm = StubClassifierLLM()
        transport = StubTransport()
        reset_audit_sink()
        graph = ProvisioningGraph(
            llm_factory=lambda streaming=None: RunnableLambda(llm.ainvoke),
            transport=transport,
        )
        try:
            with recorder:
                state = await graph.ainvoke(
                    _seed("provision a VPLS between leaf01 ethernet1 and leaf02 ethernet2 "
                          "for tenant acme with a traffic engineering policy"),
                    config=_config(),
                )
        finally:
            await graph.close()
        assert state.get("workflow_status") == NetworkProvisioningStatus.FAILED.value
        assert recorder.attempts == []
        assert transport.calls == []

    async def test_deployer_refuses_without_approved_status(self):
        # T124: workflow_status != APPROVED -> refusal, deployer worker never
        # called, no cluster client touched.
        llm = StubClassifierLLM()
        transport = StubTransport()
        reset_audit_sink()
        graph = ProvisioningGraph(
            llm_factory=lambda streaming=None: RunnableLambda(llm.ainvoke),
            transport=transport,
        )
        intent = _valid_vpws_intent(_valid_vpws_interpretation())
        state = {
            "correlation_id": "b" * 32,
            "principal": "unit-test",
            "workflow_status": NetworkProvisioningStatus.ALLOCATED.value,
            "confirmation_2": {"decided": "confirm", "at": "2026-09-01T00:00:00Z", "principal": "unit-test"},
            "allocated_resources": canonical_json(intent),
        }
        recorder = DeviceSessionRecorder()
        try:
            with recorder:
                out = await graph._deployer_node(dict(state), _config())
        finally:
            await graph.close()
        assert out["workflow_status"] == NetworkProvisioningStatus.FAILED.value
        assert "workflow_status is 'ALLOCATED', not APPROVED" in out["refusal_reason"]
        assert out["next_node"] == "__end__"
        assert [c[0] for c in transport.calls] == []  # no deployer worker call
        assert recorder.attempts == []

    async def test_deployer_refuses_without_confirmation_2(self):
        # T125: confirmation_2.decided != "confirm" -> refusal, deployer
        # worker never called.
        llm = StubClassifierLLM()
        transport = StubTransport()
        reset_audit_sink()
        graph = ProvisioningGraph(
            llm_factory=lambda streaming=None: RunnableLambda(llm.ainvoke),
            transport=transport,
        )
        intent = _valid_vpws_intent(_valid_vpws_interpretation())
        for confirmation_2 in (None, {"decided": "decline", "at": "2026-09-01T00:00:00Z", "principal": "p"}):
            state = {
                "correlation_id": "c" * 32,
                "principal": "unit-test",
                "workflow_status": NetworkProvisioningStatus.APPROVED.value,
                "confirmation_2": confirmation_2,
                "allocated_resources": canonical_json(intent),
            }
            out = await graph._deployer_node(dict(state), _config())
            assert out["workflow_status"] == NetworkProvisioningStatus.FAILED.value
            assert "confirmation_2.decided" in out["refusal_reason"]
            assert out["next_node"] == "__end__"
            assert [c[0] for c in transport.calls] == []
        await graph.close()

    def test_graph_module_imports_no_cluster_client(self):
        # The supervisor graph holds no cluster identity and must not import
        # one: the only cluster-writer in the tier is the deployer WORKER
        # (a separate process with its own ServiceAccount).
        assert "kubernetes" not in sys.modules
        source = inspect.getsource(graph_mod)
        assert "import kubernetes" not in source
        assert "kubernetes_asyncio" not in source
