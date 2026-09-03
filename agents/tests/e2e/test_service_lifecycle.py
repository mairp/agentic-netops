from __future__ import annotations

import json
from typing import Any

import pytest

from supervisors.provisioning.graph.graph import ProvisioningGraph


class StubTransport:
    def __init__(self):
        self.deployer_called = False

    async def call_mapper(self, text: str) -> Any:  # not used in these tests
        return {"parts": [{"text": text}]}

    async def call_allocator(self, text: str) -> Any:  # not used in these tests
        return {"parts": [{"text": text}]}

    async def call_deployer(self, text: str) -> Any:
        self.deployer_called = True
        # text is the fenced JSON tool request; extract action for shape
        try:
            # The supervisor fences worker text; we only need the JSON inside
            data_json = text
            try:
                obj = json.loads(data_json)
            except Exception:
                obj = {}
        except Exception:
            obj = {}
        action = (obj.get("action") if isinstance(obj, dict) else None) or "status"
        if action == "status":
            payload = {"status": {"serviceId": obj.get("serviceId", ""), "correlationId": obj.get("correlationId", ""), "phase": "Unknown"}}
        else:
            payload = {"removed": {"selector": f"ainetops.io/correlation-id={obj.get('correlationId','')}", "deleted": 0}}
        # Return a DataPart-first dict, plus a marker-compatible text
        return {
            "parts": [
                {"data": payload},
                {"text": "ok\n<!-- SUBMISSION_JSON: %s -->" % json.dumps(payload, separators=(",", ":"), sort_keys=True)}
            ]
        }


@pytest.mark.asyncio
async def test_status_query_tools_path_yields_result():
    """Existing-service status query routes to deployer tools and yields a tools result."""
    tr = StubTransport()
    g = ProvisioningGraph(transport=tr)
    seed = {"messages": [{"type": "human", "content": "status of service svc-123456"}]}
    state = await g.ainvoke(seed)
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
        "tool_request": json.dumps({"action": "remove", "correlationId": "deadbeefdeadbeef"}, separators=(",", ":"), sort_keys=True),
    }
    state = await g.ainvoke(seed)
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
        "tool_request": json.dumps({"action": "remove", "correlationId": "cafebabecafebabe"}, separators=(",", ":"), sort_keys=True),
    }
    state = await g.ainvoke(seed)
    # Final state carries tool_result from deployer tools
    tool_result = state.get("tool_result")
    assert tool_result, "expected tool_result in final state"
    obj = json.loads(tool_result)
    assert "removed" in obj and obj["removed"].get("deleted") == 0
