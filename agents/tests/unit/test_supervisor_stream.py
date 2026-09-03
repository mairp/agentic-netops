import json

from fastapi.testclient import TestClient
from langchain_core.messages import AIMessage

from common.provisioning_states import NetworkProvisioningStatus


class _MessageOnlyGraph:
    async def astream(self, seed, config=None):
        yield {
            "general_info": {
                "messages": [AIMessage(content="A useful operator-facing answer.")],
            }
        }


def test_stream_preserves_seed_status_and_returns_the_answer(monkeypatch):
    import supervisors.provisioning.main as main_mod

    monkeypatch.setattr(main_mod, "get_graph", lambda: _MessageOnlyGraph())
    with TestClient(main_mod.app) as client:
        response = client.post(
            "/agent/prompt/stream",
            json={"prompt": "what services are supported?", "principal": "unit-test"},
        )

    chunks = [json.loads(line) for line in response.text.splitlines()]
    assert chunks[-1]["type"] == "final"
    assert chunks[-1]["status"] == NetworkProvisioningStatus.RECEIVED_REQUEST.value
    assert chunks[-1]["status"] != NetworkProvisioningStatus.STATUS_UNKNOWN.value
    assert chunks[-1]["message"] == "A useful operator-facing answer."
