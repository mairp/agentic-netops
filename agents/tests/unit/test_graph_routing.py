from __future__ import annotations

import json
import time

import pytest
from langchain_core.runnables import RunnableLambda

from common.provisioning_states import NetworkProvisioningStatus
from supervisors.provisioning.graph.graph import (
    MAX_ITERATIONS,
    ProvisioningGraph,
)
from tests.corpus.adversarial.runner import StubClassifierLLM, StubTransport


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
        state = await g.ainvoke({"messages": [{"type": "human", "content": "provision a VPWS between leaf01 ethernet1 and leaf02 ethernet2 for tenant acme vlan 100"}]})
        assert state.get("workflow_status") == NetworkProvisioningStatus.MAPPED.value
        assert state.get("awaiting_confirmation") is True
        assert state.get("pending_action") in ("clarify", "confirm_1")
        # Reflection path is taken on confirm_1 -> allocator -> reflection
        if state.get("pending_action") == "confirm_1":
            state = await g.ainvoke({"messages": [{"type": "human", "content": "confirm"}]})
            assert state.get("workflow_status") == NetworkProvisioningStatus.ALLOCATED.value
            assert state.get("awaiting_confirmation") is True
            assert state.get("pending_action") == "confirm_2"
    finally:
        await g.close()


def test_max_iterations_constant_is_three():
    """T375 — constant is set to 3."""
    assert MAX_ITERATIONS == 3


@pytest.mark.asyncio
async def test_wall_clock_deadline_bounded_exit(monkeypatch):
    """T376 — setting a past deadline yields a bounded exit (FAILED) without hang."""
    llm = StubClassifierLLM()
    tr = StubTransport()
    g = ProvisioningGraph(llm_factory=lambda streaming=None: RunnableLambda(llm.ainvoke), transport=tr)
    try:
        # Set deadline to a past time to force bounded exit on first supervisor pass
        state = {
            "messages": [{"type": "human", "content": "provision a VPLS between leaf01 ethernet1 and leaf02 ethernet2 for tenant acme vlan 200"}],
            "deadline": "2000-01-01T00:00:00+00:00",
        }
        out = await g.ainvoke(state)
        assert out.get("workflow_status") == NetworkProvisioningStatus.FAILED.value
        assert "deadline" in (out.get("refusal_reason") or "")
    finally:
        await g.close()
