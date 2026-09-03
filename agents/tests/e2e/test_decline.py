from __future__ import annotations

import json
import pytest

from langchain_core.runnables import RunnableLambda

from common.provisioning_states import NetworkProvisioningStatus
from supervisors.provisioning.graph.graph import ProvisioningGraph
from tests.corpus.adversarial.runner import StubClassifierLLM, StubTransport


class _CountingTransport(StubTransport):
    def __init__(self):
        super().__init__()
        self.counts = {"mapper": 0, "allocator": 0, "deployer": 0}

    async def call_mapper(self, text: str):
        self.counts["mapper"] += 1
        return await super().call_mapper(text)

    async def call_allocator(self, text: str):
        self.counts["allocator"] += 1
        return await super().call_allocator(text)

    async def call_deployer(self, text: str):
        self.counts["deployer"] += 1
        return await super().call_deployer(text)


@pytest.mark.asyncio
async def test_decline_at_first_confirmation():
    """T367 — declining at first confirmation ends the thread FAILED and calls no workers beyond mapper."""
    g = ProvisioningGraph(llm_factory=lambda streaming=None: RunnableLambda(StubClassifierLLM().ainvoke))
    # Seed a mapped state that is awaiting the first confirmation
    state = {
        "messages": [{"type": "human", "content": "decline"}],
        "workflow_status": NetworkProvisioningStatus.MAPPED.value,
        "awaiting_confirmation": True,
        "pending_action": "confirm_1",
        "mapped_parameters": json.dumps({"serviceType": "VPWS"}),
    }
    out = await g.ainvoke(state)
    assert out.get("workflow_status") == NetworkProvisioningStatus.FAILED.value
    assert "confirmation_1" in (out.get("refusal_reason") or "")


@pytest.mark.asyncio
async def test_decline_at_second_confirmation_releases_claims():
    """T368/T370 — declining at second confirmation ends FAILED and releases any claimed ids."""
    g = ProvisioningGraph(llm_factory=lambda streaming=None: RunnableLambda(StubClassifierLLM().ainvoke))
    claims = [
        {"kind": "Claim", "name": "rd-65000:1", "value": "65000:1"},
        {"kind": "Claim", "name": "l2vni-10001", "value": 10001},
    ]
    state = {
        "messages": [{"type": "human", "content": "decline"}],
        "workflow_status": NetworkProvisioningStatus.ALLOCATED.value,
        "awaiting_confirmation": True,
        "pending_action": "confirm_2",
        "allocated_resources": json.dumps({"serviceId": "svc-abc12345", "type": "VPWS", "tenant": "acme", "rdRt": {"rd": "65000:1", "importRT": ["65000:1"], "exportRT": ["65000:1"]}}),
        "claimed_ids": claims,
    }
    out = await g.ainvoke(state)
    assert out.get("workflow_status") == NetworkProvisioningStatus.FAILED.value
    # T370: zero-claims-after-decline — any present claims are marked released (no active claims remain)
    released = out.get("claimed_ids") or []
    assert len(released) == len(claims)
    assert all("released_at" in c for c in released)


@pytest.mark.asyncio
async def test_zero_resources_after_decline():
    """T369 — no deployer calls or submissions occur after any decline."""
    tr = _CountingTransport()
    g = ProvisioningGraph(llm_factory=lambda streaming=None: RunnableLambda(StubClassifierLLM().ainvoke), transport=tr)
    # First-confirmation decline
    state1 = {
        "messages": [{"type": "human", "content": "decline"}],
        "workflow_status": NetworkProvisioningStatus.MAPPED.value,
        "awaiting_confirmation": True,
        "pending_action": "confirm_1",
        "mapped_parameters": json.dumps({"serviceType": "VPWS"}),
    }
    out1 = await g.ainvoke(state1)
    assert out1.get("workflow_status") == NetworkProvisioningStatus.FAILED.value
    # Second-confirmation decline
    state2 = {
        "messages": [{"type": "human", "content": "decline"}],
        "workflow_status": NetworkProvisioningStatus.ALLOCATED.value,
        "awaiting_confirmation": True,
        "pending_action": "confirm_2",
        "allocated_resources": json.dumps({"serviceId": "svc-abc12345", "type": "VPWS", "tenant": "acme", "rdRt": {"rd": "65000:1", "importRT": ["65000:1"], "exportRT": ["65000:1"]}}),
    }
    out2 = await g.ainvoke(state2)
    assert out2.get("workflow_status") == NetworkProvisioningStatus.FAILED.value
    # No deployer calls must have occurred
    assert tr.counts["deployer"] == 0
