from __future__ import annotations

import json
import re
from typing import Any

import pytest

from supervisors.provisioning.graph.graph import ProvisioningGraph

_JSON_BLOCK = re.compile(r"\{.*\}", re.S)


def _tool_request(fenced: str) -> dict:
    """The canonical tool request the supervisor wrapped in its nonce fence."""

    m = _JSON_BLOCK.search(fenced or "")
    if not m:
        return {}
    try:
        obj = json.loads(m.group(0))
    except json.JSONDecodeError:
        return {}
    return obj if isinstance(obj, dict) else {}


class StubTransport:
    def __init__(self):
        self.deployer_called = False

    async def call_mapper(self, text: str) -> Any:  # not used in these tests
        return {"parts": [{"text": text}]}

    async def call_allocator(self, text: str) -> Any:  # not used in these tests
        return {"parts": [{"text": text}]}

    async def call_deployer(self, text: str) -> Any:
        self.deployer_called = True
        # The supervisor fences the tool request (T095), so the worker text is
        # never bare JSON. Parsing it as-is always failed and silently fell back
        # to action "status", which made the remove-service test assert a
        # removal report against a status report.
        obj = _tool_request(text)
        action = (obj.get("action") if isinstance(obj, dict) else None) or "status"
        if action == "status":
            payload = {
                "status": {
                    "serviceId": obj.get("serviceId", ""),
                    "correlationId": obj.get("correlationId", ""),
                    "phase": "Unknown",
                }
            }
        else:
            selector = f"agentic-netops.io/correlation-id={obj.get('correlationId', '')}"
            payload = {"removed": {"selector": selector, "deleted": 0}}
        # Return a DataPart-first dict, plus a marker-compatible text
        return {
            "parts": [
                {"data": payload},
                {
                    "text": "ok\n<!-- SUBMISSION_JSON: {} -->".format(
                        json.dumps(payload, separators=(",", ":"), sort_keys=True)
                    )
                },
            ]
        }


def _config(thread: str) -> dict:
    """A thread id is mandatory whenever a checkpointer is attached, and
    ``ProvisioningGraph`` always attaches one (see tests/e2e/test_decline.py)."""

    return {"configurable": {"thread_id": thread}}


@pytest.mark.asyncio
async def test_status_query_tools_path_yields_result():
    """Existing-service status query routes to deployer tools and yields a tools result."""
    tr = StubTransport()
    g = ProvisioningGraph(transport=tr)
    seed = {"messages": [{"type": "human", "content": "status of service svc-123456"}]}
    try:
        state = await g.ainvoke(seed, config=_config("lifecycle-status"))
    finally:
        await g.close()
    # The deployer tools path encodes result on tool_result
    tool_result = state.get("tool_result")
    assert tool_result, "expected tool_result in final state"
    obj = json.loads(tool_result)
    assert "status" in obj and obj["status"].get("phase") == "Unknown"


@pytest.mark.asyncio
async def test_remove_service_decline_stops_without_calling_deployer():
    """Declined remove-service should not call the deployer tools path."""
    tr = StubTransport()
    g = ProvisioningGraph(transport=tr)
    # Seed state to ask for confirm_remove, then send a decline
    seed = {
        "messages": [{"type": "human", "content": "decline"}],
        "awaiting_confirmation": True,
        "pending_action": "confirm_remove",
        "tool_action": "remove",
        "tool_request": json.dumps(
            {"action": "remove", "correlationId": "deadbeefdeadbeef"},
            separators=(",", ":"),
            sort_keys=True,
        ),
    }
    try:
        state = await g.ainvoke(seed, config=_config("lifecycle-remove-decline"))
    finally:
        await g.close()
    assert state.get("workflow_status") == "FAILED"
    assert "remove-service declined" in (state.get("refusal_reason") or "")
    assert tr.deployer_called is False


@pytest.mark.asyncio
async def test_remove_service_confirm_routes_to_deployer_tools():
    """Confirmed remove-service should route to deployer tools and yield a removed report."""
    tr = StubTransport()
    g = ProvisioningGraph(transport=tr)
    seed = {
        "messages": [{"type": "human", "content": "confirm"}],
        "awaiting_confirmation": True,
        "pending_action": "confirm_remove",
        "tool_action": "remove",
        "tool_request": json.dumps(
            {"action": "remove", "correlationId": "cafebabecafebabe"},
            separators=(",", ":"),
            sort_keys=True,
        ),
    }
    try:
        state = await g.ainvoke(seed, config=_config("lifecycle-remove-confirm"))
    finally:
        await g.close()
    # Final state carries tool_result from deployer tools
    tool_result = state.get("tool_result")
    assert tool_result, "expected tool_result in final state"
    obj = json.loads(tool_result)
    assert "removed" in obj and obj["removed"].get("deleted") == 0
