from __future__ import annotations

import pytest
from langchain_core.runnables import RunnableLambda

from common.provisioning_states import NetworkProvisioningStatus
from supervisors.provisioning.graph.graph import (
    MAX_ITERATIONS,
    ProvisioningGraph,
)
from tests.corpus.adversarial.runner import StubClassifierLLM, StubTransport


class FixedWordLLM:
    def __init__(self, word: str) -> None:
        self.word = word
        self.calls = 0

    async def ainvoke(self, input, config=None):
        self.calls += 1
        from langchain_core.messages import AIMessage

        return AIMessage(content=self.word)


class ClarifyingMapperTransport(StubTransport):
    async def call_mapper(self, text: str):
        self.calls.append(("mapper", text))
        return {
            "parts": [
                {
                    "data": {
                        "service_id": "svc-clarify",
                        "service_type": "VPWS",
                        "tenant": "acme",
                        "endpoints": [
                            {"site_or_node": "missing", "attachment": "missing"},
                            {"site_or_node": "missing", "attachment": "missing"},
                        ],
                        "missing_fields": ["endpoints"],
                        "unsupported_properties": [],
                    }
                },
                {"text": "Service VPWS for tenant acme. Missing: endpoints."},
            ]
        }


def _config(thread_id: str) -> dict:
    return {"configurable": {"thread_id": thread_id}}


@pytest.mark.asyncio
async def test_conditional_edges_and_routing_flow():
    """T374 — graph conditional edges route based on next_node and stage outcomes.

    This exercises SUPERVISOR -> MAPPER -> REFLECTION -> SUPERVISOR using the real graph.
    """
    llm = StubClassifierLLM()
    tr = StubTransport()
    g = ProvisioningGraph(llm_factory=lambda streaming=None: RunnableLambda(llm.ainvoke), transport=tr)
    try:
        # First pass: should reach MAPPED and await confirm_1
        state = await g.ainvoke(
            {
                "messages": [
                    {
                        "type": "human",
                        "content": (
                            "extend vlan 100 as a mac-vrf across leaf01 ethernet1 and leaf02 ethernet2 for tenant acme"
                        ),
                    }
                ]
            },
            config=_config("routing-flow"),
        )
        assert state.get("workflow_status") == NetworkProvisioningStatus.MAPPED.value
        assert state.get("awaiting_confirmation") is True
        assert state.get("pending_action") in ("clarify", "confirm_1")
        # Reflection path is taken on confirm_1 -> allocator -> reflection
        if state.get("pending_action") == "confirm_1":
            state = await g.ainvoke(
                {"messages": [{"type": "human", "content": "confirm"}]},
                config=_config("routing-flow"),
            )
            assert state.get("workflow_status") == NetworkProvisioningStatus.ALLOCATED.value
            assert state.get("awaiting_confirmation") is True
            assert state.get("pending_action") == "confirm_2"
    finally:
        await g.close()


def test_max_iterations_constant_is_three():
    """T375 — constant is set to 3."""
    assert MAX_ITERATIONS == 3


@pytest.mark.asyncio
async def test_missing_attachment_points_stop_for_clarification():
    llm = FixedWordLLM("provisionable")
    tr = ClarifyingMapperTransport()
    g = ProvisioningGraph(llm_factory=lambda streaming=None: RunnableLambda(llm.ainvoke), transport=tr)
    try:
        state = await g.ainvoke(
            {
                "messages": [
                    {
                        "type": "human",
                        "content": "extend vlan 100 as a mac-vrf across leaf01 and leaf02 for tenant acme",
                    }
                ]
            },
            config=_config("clarify-flow"),
        )
        assert state.get("workflow_status") == NetworkProvisioningStatus.MAPPED.value
        assert state.get("awaiting_confirmation") is True
        assert state.get("pending_action") == "clarify"
        assert state.get("missing_fields") == ["endpoints"]
        assert state.get("next_node") == "__end__"
        assert llm.calls == 1
        assert [call[0] for call in tr.calls] == ["mapper"]
        assert "Before I can map this service I need" in state["messages"][-1].content
        # FR-010 companion: the clarification is actionable — it names the
        # accepted vocabulary and a worked example so the restatement is
        # mappable (live finding: "provision a mac vrf across all leafs"
        # looped clarifications with no guidance).
        assert "VPLS" in state["messages"][-1].content
        assert "VPWS" in state["messages"][-1].content
        assert "L3VPN" in state["messages"][-1].content
        assert "IRB" in state["messages"][-1].content
        assert "Example:" in state["messages"][-1].content
    finally:
        await g.close()


@pytest.mark.asyncio
async def test_wall_clock_deadline_bounded_exit(monkeypatch):
    """T376 — setting a past deadline yields a bounded exit (FAILED) without hang."""
    llm = StubClassifierLLM()
    tr = StubTransport()
    g = ProvisioningGraph(llm_factory=lambda streaming=None: RunnableLambda(llm.ainvoke), transport=tr)
    try:
        # Set deadline to a past time to force bounded exit on first supervisor pass
        state = {
            "messages": [
                {
                    "type": "human",
                    "content": (
                        "extend vlan 200 as a mac-vrf across leaf01 ethernet1 and leaf02 ethernet2 for tenant acme"
                    ),
                }
            ],
            "deadline": "2000-01-01T00:00:00+00:00",
        }
        out = await g.ainvoke(state, config=_config("deadline-flow"))
        assert out.get("workflow_status") == NetworkProvisioningStatus.FAILED.value
        assert "deadline" in (out.get("refusal_reason") or "")
    finally:
        await g.close()
