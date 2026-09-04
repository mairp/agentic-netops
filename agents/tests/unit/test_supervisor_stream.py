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


class _DeployerOutcomeGraph:
    """A deployer node that reports a convergence outcome, as the real one now does."""

    def __init__(self, status: str, convergence: list[dict]) -> None:
        self.status = status
        self.convergence = convergence

    async def astream(self, seed, config=None):
        yield {
            "deployer": {
                "workflow_status": self.status,
                "submitted_resources": json.dumps(
                    [
                        {
                            "apiVersion": "network.kubenet.dev/v1alpha1",
                            "kind": "Network",
                            "namespace": "agentic-netops-intent",
                            "name": "net-svc-alpha",
                        }
                    ]
                ),
                "convergence": json.dumps(self.convergence),
                "messages": [AIMessage(content="Deployed. 1 resource(s) reached Ready on the fabric.")],
            }
        }


def _stream(monkeypatch, graph) -> list[dict]:
    import supervisors.provisioning.main as main_mod

    monkeypatch.setattr(main_mod, "get_graph", lambda: graph)
    with TestClient(main_mod.app) as client:
        response = client.post(
            "/agent/prompt/stream",
            json={"prompt": "deploy it", "principal": "unit-test"},
        )
    return [json.loads(line) for line in response.text.splitlines()]


def test_a_converged_deployment_streams_the_outcome_not_just_the_submission(monkeypatch):
    """The gap this closes: the stream used to end at PROVISIONING with no
    convergence signal, so the conversation's last word was "in progress"."""

    chunks = _stream(
        monkeypatch,
        _DeployerOutcomeGraph(
            NetworkProvisioningStatus.COMPLETED.value,
            [
                {
                    "resource": "Network/net-svc-alpha",
                    "outcome": "ready",
                    "ready": True,
                    "detail": "applied and verified on all nodes",
                }
            ],
        ),
    )
    stage = next(c for c in chunks if c["type"] == "stage" and c["stage"] == "deployer")
    assert stage["status"] == NetworkProvisioningStatus.COMPLETED.value
    assert stage["payload"]["convergence"][0]["outcome"] == "ready"
    assert [r["name"] for r in stage["payload"]["submitted"]] == ["net-svc-alpha"]

    progress = [c for c in chunks if c["type"] == "progress"]
    assert len(progress) == 1
    assert "converged" in progress[0]["message"]
    assert "applied and verified on all nodes" in progress[0]["message"]

    assert chunks[-1]["type"] == "final"
    assert chunks[-1]["status"] == NetworkProvisioningStatus.COMPLETED.value


def test_a_failed_convergence_streams_the_stage_and_then_the_error(monkeypatch):
    chunks = _stream(
        monkeypatch,
        _DeployerOutcomeGraph(
            NetworkProvisioningStatus.FAILED.value,
            [
                {
                    "resource": "Network/net-svc-alpha",
                    "outcome": "failed",
                    "ready": False,
                    "detail": "ApplyFailed: leaf2 rejected the VRF binding",
                }
            ],
        ),
    )
    stage = next(c for c in chunks if c["type"] == "stage" and c["stage"] == "deployer")
    assert stage["status"] == NetworkProvisioningStatus.FAILED.value
    progress = next(c for c in chunks if c["type"] == "progress")
    assert "failed to converge" in progress["message"]
    assert "leaf2 rejected the VRF binding" in progress["message"]
    assert chunks[-1]["type"] == "error"
    assert chunks[-1]["status"] == NetworkProvisioningStatus.FAILED.value
