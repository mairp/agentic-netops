from __future__ import annotations

import json

import pytest
from langchain_core.runnables import RunnableLambda

from common.provisioning_states import NetworkProvisioningStatus
from supervisors.provisioning.graph.graph import ProvisioningGraph
from tests.corpus.adversarial.runner import StubClassifierLLM, StubTransport


def _graph() -> ProvisioningGraph:
    """A graph with the deterministic classifier and worker transport.

    These journeys used to build a bare ``ProvisioningGraph()``, which reaches
    for the configured model provider and the A2A transport over SLIM — neither
    of which exists in a test run.
    """

    return ProvisioningGraph(
        llm_factory=lambda streaming=None: RunnableLambda(StubClassifierLLM().ainvoke),
        transport=StubTransport(),
    )


def _config(thread: str) -> dict:
    """A thread id is mandatory once a checkpointer is attached, and
    ``ProvisioningGraph`` always attaches one."""

    return {"configurable": {"thread_id": thread}}


@pytest.mark.asyncio
async def test_operator_journey_l2_confirm_and_decline():
    """An L2 journey: a mapped mac-vrf awaits the first confirmation, the
    operator declines, and the thread ends FAILED with a readable reason."""

    g = _graph()
    # Seed a mapped state so the confirmation handling is exercised
    # deterministically. ``confirm_1``/``confirm_2`` are the pending actions the
    # supervisor uses; this file asked for "confirm_interpretation" and
    # "confirm_deployment", names the graph has never had, so the decline fell
    # through to the classifier instead of the confirmation branch.
    state = {
        "messages": [{"type": "human", "content": "decline"}],
        "workflow_status": NetworkProvisioningStatus.MAPPED.value,
        "awaiting_confirmation": True,
        "pending_action": "confirm_1",
        "mapped_parameters": json.dumps({"service_type": "mac-vrf"}),
    }
    try:
        out = await g.ainvoke(state, config=_config("journey-l2"))
    finally:
        await g.close()
    assert out.get("workflow_status") == NetworkProvisioningStatus.FAILED.value
    assert "declined" in (out.get("refusal_reason") or "")


@pytest.mark.asyncio
async def test_operator_journey_l3_confirm_then_fail():
    """An L3 journey: an allocated ip-vrf is confirmed a second time, and the
    deployer's submission preconditions decide the outcome. Whatever it decides,
    the thread must not submit anything on a proposal this thin, and the
    operator-facing outcome must name the stage responsible."""

    g = _graph()
    state = {
        "messages": [{"type": "human", "content": "confirm"}],
        "workflow_status": NetworkProvisioningStatus.ALLOCATED.value,
        "awaiting_confirmation": True,
        "pending_action": "confirm_2",
        "allocated_resources": json.dumps({"rdRt": {"rd": "1:1", "rt": "1:1"}}),
    }
    try:
        out = await g.ainvoke(state, config=_config("journey-l3"))
    finally:
        await g.close()
    assert out.get("workflow_status") == NetworkProvisioningStatus.FAILED.value
    reason = out.get("refusal_reason") or ""
    assert "deployer" in reason or "precondition" in reason, reason
    assert not out.get("submitted_resources"), "nothing may be submitted from this state"
