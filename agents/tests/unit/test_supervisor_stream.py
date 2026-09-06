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


class _ClarifyingMapperGraph:
    """The mapper reporting an incomplete request, as it does when the
    operator's prompt omits the service-defining fields."""

    async def astream(self, seed, config=None):
        yield {
            "mapper": {
                "workflow_status": NetworkProvisioningStatus.MAPPED.value,
                "pending_action": "clarify",
                "missing_fields": ["service_type", "tenant", "endpoints"],
                # What the supervisor carries after redaction: nothing the
                # operator did not supply.
                "mapped_parameters": json.dumps(
                    {
                        "service_id": "5db30b4efa0f4a2",
                        "service_type": None,
                        "tenant": None,
                        "endpoints": None,
                        "missing_fields": ["service_type", "tenant", "endpoints"],
                        "unsupported_properties": [],
                    }
                ),
                "messages": [AIMessage(content="Before I can map this service I need: ...")],
            }
        }


def test_an_incomplete_request_streams_no_interpretation_card(monkeypatch):
    """An incomplete interpretation is not an interpretation (FR-010). The
    MAPPED card used to render the mapper's schema-validity placeholders as
    the operator's request — a construct service_type nobody asked for."""

    chunks = _stream(monkeypatch, _ClarifyingMapperGraph())
    assert not [c for c in chunks if c["type"] == "stage"], "no interpretation card for an incomplete request"

    clarifications = [c for c in chunks if c["type"] == "clarification_request"]
    assert len(clarifications) == 1
    assert clarifications[0]["missing_fields"] == ["service_type", "tenant", "endpoints"]

    # The clarification legitimately lists the service types as OPTIONS. What
    # must never appear is one presented as the operator's choice.
    for c in chunks:
        for key in ("service_type", "tenant", "endpoints"):
            assert f'"{key}": "' not in json.dumps(c), f"{key} reported as supplied: {c}"


def test_the_clarification_text_is_not_repeated(monkeypatch):
    """It was rendered twice: once from clarification_request, once from the
    final chunk's message, in two slightly different wordings."""

    chunks = _stream(monkeypatch, _ClarifyingMapperGraph())
    prompt = next(c for c in chunks if c["type"] == "clarification_request")["prompt"]
    assert "Before I can map this service I need" in prompt

    final = chunks[-1]
    assert final["type"] == "final"
    assert "message" not in final, "the final chunk must not repeat the clarification"

    lead = "Before I can map this service I need"
    assert sum(lead in json.dumps(c) for c in chunks) == 1


class _CompleteMapperGraph:
    async def astream(self, seed, config=None):
        yield {
            "mapper": {
                "workflow_status": NetworkProvisioningStatus.MAPPED.value,
                "mapped_parameters": json.dumps(
                    {"service_type": "mac-vrf", "tenant": "acme", "missing_fields": []}
                ),
                "messages": [AIMessage(content="Confirm this interpretation? Reply 'confirm' ...")],
            }
        }


def test_a_complete_request_still_gets_its_interpretation_card(monkeypatch):
    """The clarification fix must not suppress the card for a request that
    actually named its fields."""

    chunks = _stream(monkeypatch, _CompleteMapperGraph())
    stage = next(c for c in chunks if c["type"] == "stage" and c["stage"] == "mapper")
    assert stage["payload"]["service_type"] == "mac-vrf"
    assert stage["payload"]["tenant"] == "acme"
    assert any(c["type"] == "confirmation_request" for c in chunks)


def test_the_confirmation_question_is_asked_once(monkeypatch):
    chunks = _stream(monkeypatch, _CompleteMapperGraph())
    assert sum("Confirm this interpretation?" in json.dumps(c) for c in chunks) == 1
    assert "message" not in chunks[-1]
