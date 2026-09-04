"""Resolving a submitted transaction's live outcome from the cluster.

``deployer.get_service_status`` is the answer to "what is the status of the
deployment?" — it selects the submitted objects by the correlation-id label
every one of them carries and reports each object's ``Ready`` condition as
the controller wrote it. An unreadable cluster is ``Unknown`` with the error
named; it is never a success.
"""

from __future__ import annotations

import json
from typing import Any

import pytest

from provisioning.deployer.tools import deployer_tools

CID = "b" * 32


def _network(
    name: str,
    ready: bool | None,
    reason: str = "",
    message: str = "",
    degraded: bool | None = False,
) -> dict[str, Any]:
    conditions = []
    if ready is not None:
        conditions.append(
            {
                "type": "Ready",
                "status": "True" if ready else "False",
                "reason": reason,
                "message": message,
                "lastTransitionTime": "2026-09-04T07:48:18Z",
            }
        )
    if degraded is not None:
        conditions.append(
            {
                "type": "Degraded",
                "status": "True" if degraded else "False",
                "reason": "ApplyFailuresObserved" if degraded else "NoFailuresObserved",
                "message": "one or more nodes failed" if degraded else "no apply failures observed",
                "lastTransitionTime": "2026-09-04T07:48:18Z",
            }
        )
    return {
        "apiVersion": "network.kubenet.dev/v1alpha1",
        "kind": "Network",
        "metadata": {"name": name, "namespace": "agentic-netops-intent"},
        "status": {"conditions": conditions},
    }


class _FakeClient:
    def __init__(self, objects: list[dict[str, Any]] | Exception) -> None:
        self._objects = objects
        self.closed = False

    def list_by_correlation(self, correlation_id: str) -> list[dict[str, Any]]:
        if isinstance(self._objects, Exception):
            raise self._objects
        return self._objects

    def close(self) -> None:
        self.closed = True


@pytest.fixture()
def patch_client(monkeypatch):
    def _patch(objects):
        client = _FakeClient(objects)
        from provisioning.deployer import submit as submit_mod

        monkeypatch.setattr(submit_mod, "build_default_client", lambda: client)
        return client

    return _patch


def test_ready_true_is_deployed_and_quotes_the_condition(patch_client):
    client = patch_client(
        [_network("net-svc-alpha", True, "ApplySucceeded", "applied and verified on all nodes")]
    )
    result = deployer_tools.get_service_status(correlation_id=CID)
    assert result["phase"] == "Deployed"
    resource = result["resources"][0]
    assert resource["name"] == "net-svc-alpha"
    assert resource["ready"] is True
    assert resource["degraded"] is False
    assert resource["message"] == "applied and verified on all nodes"
    assert resource["lastTransitionTime"] == "2026-09-04T07:48:18Z"
    assert client.closed


def test_ready_false_is_failed(patch_client):
    patch_client([_network("net-svc-alpha", False, "ApplyFailed", "leaf2 rejected the VRF binding")])
    result = deployer_tools.get_service_status(correlation_id=CID)
    assert result["phase"] == "Failed"
    assert result["resources"][0]["message"] == "leaf2 rejected the VRF binding"


def test_degraded_true_is_failed_even_if_ready_is_true(patch_client):
    patch_client([_network("net-svc-alpha", True, "ApplySucceeded", "ok", degraded=True)])
    result = deployer_tools.get_service_status(correlation_id=CID)
    assert result["phase"] == "Failed"
    assert result["resources"][0]["degraded"] is True


def test_service_id_is_recovered_from_a_translated_network(patch_client):
    obj = _network("migr-abc123", True, "ApplySucceeded", "ok")
    obj["spec"] = {"description": "Migrated service abc123 (L3VPN)"}
    patch_client([obj])

    assert deployer_tools.get_service_status(correlation_id=CID)["serviceId"] == "abc123"


def test_one_failure_among_many_is_a_failed_transaction(patch_client):
    patch_client(
        [
            _network("net-a", True, "ApplySucceeded", "ok"),
            _network("net-b", False, "ApplyFailed", "nope"),
        ]
    )
    assert deployer_tools.get_service_status(correlation_id=CID)["phase"] == "Failed"


def test_no_ready_condition_yet_is_converging(patch_client):
    patch_client([_network("net-svc-alpha", None)])
    assert deployer_tools.get_service_status(correlation_id=CID)["phase"] == "Converging"


def test_nothing_labelled_is_not_found(patch_client):
    patch_client([])
    assert deployer_tools.get_service_status(correlation_id=CID)["phase"] == "NotFound"


def test_an_unreadable_cluster_is_unknown_with_the_error_named(patch_client):
    patch_client(RuntimeError("HTTP 403: forbidden"))
    result = deployer_tools.get_service_status(correlation_id=CID)
    assert result["phase"] == "Unknown"
    assert "403" in result["error"]
    assert result["resources"] == []


def test_no_correlation_id_cannot_resolve_anything():
    result = deployer_tools.get_service_status(service_id="svc-alpha")
    assert result["phase"] == "Unknown"
    assert "correlation id" in result["error"]


class TestToolCommandParsing:
    """The supervisor fences every worker-bound payload; the tools command
    parser has to unwrap that fence or the command silently degrades into
    "unknown tool action"."""

    def test_a_fenced_status_command_is_parsed(self):
        from provisioning.deployer.agent import _parse_action
        from supervisors.provisioning.prompts.system import wrap_worker_text

        fenced = wrap_worker_text(json.dumps({"action": "status", "correlationId": CID}), "nonce123")
        action = _parse_action(fenced)
        assert action.kind == "status"
        assert action.correlation_id == CID

    def test_a_plain_status_command_still_parses(self):
        from provisioning.deployer.agent import _parse_action

        action = _parse_action(json.dumps({"action": "status", "serviceId": "svc-alpha"}))
        assert action.kind == "status"
        assert action.service_id == "svc-alpha"


class TestStatusSummary:
    def test_the_summary_leads_with_the_verdict(self):
        from provisioning.deployer.agent import DeployerAgent

        summary = DeployerAgent()._summary_status(
            {
                "phase": "Deployed",
                "resources": [
                    {
                        "kind": "Network",
                        "name": "net-svc-alpha",
                        "ready": True,
                        "degraded": False,
                        "reason": "ApplySucceeded",
                        "message": "applied and verified on all nodes",
                        "lastTransitionTime": "2026-09-04T07:48:18Z",
                    }
                ],
            }
        )
        assert summary.startswith("Deployed.")
        assert "Network/net-svc-alpha Ready=True" in summary
        assert "Degraded=False" in summary
        assert "applied and verified on all nodes" in summary
        assert "2026-09-04T07:48:18Z" in summary

    def test_a_failure_summary_names_the_condition(self):
        from provisioning.deployer.agent import DeployerAgent

        summary = DeployerAgent()._summary_status(
            {
                "phase": "Failed",
                "resources": [
                    {
                        "kind": "Network",
                        "name": "net-svc-alpha",
                        "ready": False,
                        "reason": "ApplyFailed",
                        "message": "leaf2 rejected the VRF binding",
                    }
                ],
            }
        )
        assert summary.startswith("Failed.")
        assert "leaf2 rejected the VRF binding" in summary

    def test_an_unreadable_cluster_never_reads_as_deployed(self):
        from provisioning.deployer.agent import DeployerAgent

        summary = DeployerAgent()._summary_status({"phase": "Unknown", "error": "HTTP 403", "resources": []})
        assert summary.startswith("Status unknown.")
        assert "HTTP 403" in summary


class TestTheTransactionDoesNotBlockTheEventLoop:
    """A blocking convergence watch on the event loop stops the worker
    answering /health, and the kubelet SIGKILLs it mid-transaction (observed
    live 2026-09-04: exit 137 on a 133 s convergence against a 3x20 s
    liveness probe). The transaction must run off the loop."""

    async def test_health_stays_responsive_while_a_transaction_runs(self, monkeypatch):
        import asyncio
        import time

        from provisioning.deployer import submit as submit_mod
        from provisioning.deployer.agent import DeployerAgent

        def slow_transaction(envelope):
            time.sleep(1.0)  # stands in for the convergence watch
            return {"submitted": []}

        monkeypatch.setattr(
            "provisioning.deployer.agent.run_deployment_transaction", slow_transaction
        )
        monkeypatch.setattr(submit_mod, "build_default_client", lambda: None)

        envelope = json.dumps(
            {
                "action": "submit",
                "intent": {
                    "serviceId": "svc-alpha",
                    "type": "VPWS",
                    "tenant": "tenant-a",
                    "endpoints": [
                        {"node": "leaf1", "attachment": "Ethernet1"},
                        {"node": "leaf2", "attachment": "Ethernet2"},
                    ],
                },
                "context": {"correlationId": CID, "threadId": "t", "principal": "p"},
            }
        )

        heartbeats = 0

        async def heartbeat():
            nonlocal heartbeats
            while True:
                await asyncio.sleep(0.05)
                heartbeats += 1

        beat = asyncio.create_task(heartbeat())
        try:
            await DeployerAgent().ainvoke(envelope)
        finally:
            beat.cancel()

        # A blocked loop lets through ~0 heartbeats over the 1 s transaction.
        assert heartbeats > 5, f"event loop was blocked during the transaction ({heartbeats} heartbeats)"


class TestIncompleteInterpretationCarriesNoFabricatedValues:
    """``Interpretation`` requires service_type/tenant/endpoints, so the mapper
    must fill them to stay schema-valid even when they are exactly what the
    operator omitted. tenant and endpoints get an obvious "missing" string,
    but service_type is an enum with no sentinel, so it gets a real value
    (VPWS) nobody asked for — which was then displayed as the interpretation."""

    def test_missing_fields_are_blanked(self):
        from supervisors.provisioning.graph.graph import redact_unsupplied

        fabricated = {
            "service_id": "5db30b4efa0f4a2",
            "service_type": "VPWS",
            "tenant": "missing",
            "endpoints": [
                {"site_or_node": "missing", "attachment": "missing", "vlan": None},
                {"site_or_node": "missing", "attachment": "missing", "vlan": None},
            ],
            "missing_fields": ["service_type", "tenant", "endpoints"],
            "unsupported_properties": [],
        }
        out = redact_unsupplied(fabricated, fabricated["missing_fields"])
        assert out["service_type"] is None
        assert out["tenant"] is None
        assert out["endpoints"] is None
        # What the operator DID get stays: the generated id and the flags.
        assert out["service_id"] == "5db30b4efa0f4a2"
        assert out["missing_fields"] == ["service_type", "tenant", "endpoints"]

    def test_a_partially_specified_request_keeps_what_was_supplied(self):
        from supervisors.provisioning.graph.graph import redact_unsupplied

        supplied = {
            "service_id": "abc123",
            "service_type": "L3VPN",
            "tenant": "missing",
            "endpoints": [{"site_or_node": "leaf01", "attachment": "wan1", "vlan": None}],
            "missing_fields": ["tenant"],
            "unsupported_properties": [],
        }
        out = redact_unsupplied(supplied, ["tenant"])
        assert out["service_type"] == "L3VPN"
        assert out["endpoints"][0]["site_or_node"] == "leaf01"
        assert out["tenant"] is None

    def test_the_clarification_text_has_one_source(self):
        from supervisors.provisioning.graph.graph import clarification_prompt

        prompt = clarification_prompt(["service_type", "tenant"])
        assert "service_type, tenant" in prompt
        assert "no defaults are substituted" in prompt
        assert clarification_prompt(None).startswith("Before I can map this service I need: required service fields")
