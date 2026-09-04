"""Deployment transaction unit tests — the remediated contract of
docs/INTENT_TIER_DEPLOYMENT_TRANSACTION.md.

Test groups:

* ``TestEnvelopeParsing`` — step 1: the production envelope (fenced or
  plain) parses into intent + immutable context; a bare normalized intent
  is accepted for compatibility; a tools command is not a submission;
  a malformed submission is a named ``request-validation`` failure.
* ``TestManifestValidationAndStamping`` — step 3: the allow-list, DNS
  names, duplicates, forced tier namespace, server-field stripping, and
  the correlation/tier labels and thread/principal/time annotations; the
  deterministic apply order (namespace, kind, name).
* ``TestTransaction`` — steps 2-8 against a fake intent API: success
  returns ``{"submitted": [...], "convergence": [...]}`` only after every
  apply; a dry-run rejection names the resource and mutates nothing; an
  apply failure rolls back the correlation-labelled set and reports the
  full rolled-back set; a deletion survivor is a terminal failure; the
  audit trail records ``submit``/``refuse`` truthfully.
* ``TestConvergenceWatch`` — step 7: Ready-true, Ready-false, terminal
  failure phase, an object that vanishes mid-watch, and the timeout
  outcome with ``ready=null``.
* ``TestDeployerAgentReporting`` — step 8 at the agent boundary: the
  authoritative payload exists only on success; a failed transaction
  reports ``{"failed": {...}}`` naming phase/resource/rollback and never
  a ``submitted`` key; translation output alone is never a report.
* ``TestSupervisorEnvelopeAndFailure`` — the supervisor sends the
  deployment envelope (action/intent/context) and treats a named
  ``{"failed": {...}}`` report as a contract failure report, not an
  out-of-contract payload: FAILED at END, audit ``refuse``, survivors
  named.
"""

from __future__ import annotations

import json
from typing import Any

import pytest
from langchain_core.runnables import RunnableLambda

from common.audit import get_audit_sink, reset_audit_sink
from common.provisioning_states import NetworkProvisioningStatus
from provisioning.deployer.submit import (
    CORRELATION_LABEL,
    DeploymentContext,
    DeploymentEnvelope,
    DeploymentTransactionError,
    deterministic_apply_order,
    parse_deployment_envelope,
    run_deployment_transaction,
    validate_and_stamp_manifests,
)
from provisioning.deployer.watch import (
    OUTCOME_FAILED,
    OUTCOME_READY,
    OUTCOME_TIMEOUT,
    watch_convergence,
)
from supervisors.provisioning.graph.graph import ProvisioningGraph, canonical_json
from tests.corpus.adversarial.runner import StubClassifierLLM, StubTransport

CID = "a" * 32
CONTEXT = {"correlationId": CID, "threadId": "thread-1", "principal": "op-1"}

INTENT: dict[str, Any] = {
    "serviceId": "svc-alpha",
    "type": "VPWS",
    "tenant": "tenant-a",
    "endpoints": [
        {"node": "leaf1", "attachment": "Ethernet1"},
        {"node": "leaf2", "attachment": "Ethernet2"},
    ],
}


def _envelope_json() -> str:
    return json.dumps({"action": "submit", "intent": INTENT, "context": CONTEXT}, separators=(",", ":"))


def _manifest(name: str, kind: str = "Network", namespace: str | None = "elsewhere") -> dict[str, Any]:
    return {
        "apiVersion": "network.kubenet.dev/v1alpha1" if kind == "Network" else "agentic-netops.io/v1alpha1",
        "kind": kind,
        "metadata": {"name": name, **({"namespace": namespace} if namespace else {})},
        "spec": {"anyKey": 1},
    }


def _translator_ok(intent: dict[str, Any]) -> dict[str, Any]:
    return {"manifests": [_manifest("net-svc-alpha"), _manifest("srv-svc-alpha", "SRv6Service")]}


class FakeIntentAPI:
    """Fake of the deployer's intent API surface (``IntentAPI``)."""

    def __init__(
        self,
        *,
        fail_dry_run_on: str | None = None,
        fail_apply_on: str | None = None,
        sticky_delete: bool = False,
    ) -> None:
        self.objects: dict[tuple[str, str, str], dict[str, Any]] = {}
        self.reads: dict[tuple[str, str, str], int] = {}
        self.fail_dry_run_on = fail_dry_run_on
        self.fail_apply_on = fail_apply_on
        self.sticky_delete = sticky_delete

    def dry_run_apply(self, manifest: dict[str, Any]) -> dict[str, Any]:
        if manifest["metadata"]["name"] == self.fail_dry_run_on:
            raise RuntimeError("HTTP 422: spec.anyKey: Unsupported value")
        return manifest

    def apply(self, manifest: dict[str, Any]) -> dict[str, Any]:
        name = manifest["metadata"]["name"]
        if name == self.fail_apply_on:
            raise RuntimeError("HTTP 409: the apply conflict")
        key = (manifest["apiVersion"], manifest["kind"], name)
        obj = {**manifest, "metadata": {**manifest["metadata"], "uid": f"uid-{name}"}}
        self.objects[key] = obj
        return obj

    def get(self, ref: Any) -> dict[str, Any] | None:
        key = (ref.apiVersion, ref.kind, ref.name)
        self.reads[key] = self.reads.get(key, 0) + 1
        return self.objects.get(key)

    def list_by_correlation(self, correlation_id: str) -> list[dict[str, Any]]:
        return [
            obj
            for obj in self.objects.values()
            if obj["metadata"].get("labels", {}).get(CORRELATION_LABEL) == correlation_id
        ]

    def delete(self, ref: Any) -> bool:
        if self.sticky_delete:
            return False
        return self.objects.pop((ref.apiVersion, ref.kind, ref.name), None) is not None

    def close(self) -> None:
        pass


def _envelope() -> DeploymentEnvelope:
    return DeploymentEnvelope(
        intent=INTENT, context=DeploymentContext(correlation_id=CID, thread_id="thread-1", principal="op-1")
    )


# ---------------------------------------------------------------------------
# Step 1 — envelope parsing.
# ---------------------------------------------------------------------------
class TestEnvelopeParsing:
    def test_production_envelope_parses(self):
        envelope = parse_deployment_envelope(_envelope_json())
        assert envelope is not None
        assert envelope.intent == INTENT
        assert envelope.context.correlation_id == CID
        assert envelope.context.thread_id == "thread-1"
        assert envelope.context.principal == "op-1"

    def test_fenced_envelope_parses(self):
        fenced = f"<<<DATA worker_text nonce123>>>\n{_envelope_json()}\n<<<END_DATA worker_text nonce123>>>"
        envelope = parse_deployment_envelope(fenced)
        assert envelope is not None
        assert envelope.context.correlation_id == CID

    def test_bare_intent_accepted_with_compatibility_context(self):
        envelope = parse_deployment_envelope(json.dumps(INTENT))
        assert envelope is not None
        assert envelope.intent == INTENT
        # deterministic, 32-hex, and honestly named as compatibility traffic
        assert len(envelope.context.correlation_id) == 32
        assert envelope.context.principal == "compat-direct"

    def test_tools_command_is_not_a_submission(self):
        assert parse_deployment_envelope('{"action": "status", "serviceId": "svc-alpha"}') is None
        assert parse_deployment_envelope("remove service svc-alpha") is None
        assert parse_deployment_envelope("not json at all") is None

    def test_malformed_envelopes_raise_named_validation_errors(self):
        bad_intent = json.dumps(INTENT)
        for bad, phase in (
            ('{"action": "submit", "context": ' + json.dumps(CONTEXT) + "}", "intent"),
            ('{"action": "submit", "intent": ' + bad_intent + "}", "context"),
            (
                '{"action": "submit", "intent": ' + bad_intent + ', "context": {"threadId": "t", "principal": "p"}}',
                "correlationId",
            ),
            (
                '{"action": "submit", "intent": ' + json.dumps(INTENT) + ', "context": '
                + json.dumps({"correlationId": "NOPE", "threadId": "t", "principal": "p"})
                + "}",
                "32",
            ),
        ):
            with pytest.raises(DeploymentTransactionError) as excinfo:
                parse_deployment_envelope(bad)
            assert excinfo.value.phase == "request-validation"
            assert phase in str(excinfo.value)


# ---------------------------------------------------------------------------
# Step 3 — manifest validation and stamping.
# ---------------------------------------------------------------------------
class TestManifestValidationAndStamping:
    def test_stamps_labels_annotations_and_forced_namespace(self):
        prepared = validate_and_stamp_manifests([_manifest("net-1")], _envelope().context)
        assert len(prepared) == 1
        meta = prepared[0]["metadata"]
        assert meta["namespace"] == "agentic-netops-intent"
        assert meta["labels"][CORRELATION_LABEL] == CID
        assert meta["labels"]["agentic-netops.io/tier"] == "intent"
        assert meta["annotations"]["agentic-netops.io/intent-thread-id"] == "thread-1"
        assert meta["annotations"]["agentic-netops.io/intent-principal"] == "op-1"
        assert meta["annotations"]["agentic-netops.io/intent-submitted-at"].endswith("Z")

    def test_strips_server_managed_fields(self):
        m = _manifest("net-1")
        m["metadata"]["uid"] = "server-uid"
        m["metadata"]["resourceVersion"] = "123"
        m["metadata"]["managedFields"] = [{"manager": "someone"}]
        prepared = validate_and_stamp_manifests([m], _envelope().context)
        meta = prepared[0]["metadata"]
        for field in ("uid", "resourceVersion", "managedFields"):
            assert field not in meta

    def test_rejects_out_of_allow_list_kind(self):
        with pytest.raises(DeploymentTransactionError) as excinfo:
            validate_and_stamp_manifests(
                [{"apiVersion": "v1", "kind": "Pod", "metadata": {"name": "p"}, "spec": {}}],
                _envelope().context,
            )
        assert excinfo.value.phase == "manifest-validation"
        assert "allow-list" in str(excinfo.value)

    @pytest.mark.parametrize("name", ["", "Bad Uppercase", "a" * 300, "-leading"])
    def test_rejects_invalid_names(self, name):
        with pytest.raises(DeploymentTransactionError) as excinfo:
            validate_and_stamp_manifests([_manifest(name)], _envelope().context)
        assert excinfo.value.phase == "manifest-validation"

    def test_rejects_duplicates_and_empty_bundles(self):
        with pytest.raises(DeploymentTransactionError):
            validate_and_stamp_manifests([_manifest("net-1"), _manifest("net-1")], _envelope().context)
        with pytest.raises(DeploymentTransactionError):
            validate_and_stamp_manifests([], _envelope().context)

    def test_deterministic_order_is_namespace_kind_name(self):
        bundle = [
            _manifest("b-net", "Network"),
            _manifest("a-srv", "SRv6Service"),
            _manifest("a-net", "Network"),
        ]
        ordered = deterministic_apply_order(bundle)
        names = [m["metadata"]["name"] for m in ordered]
        assert names == ["a-net", "b-net", "a-srv"]


# ---------------------------------------------------------------------------
# Steps 2-8 — the transaction against a fake intent API.
# ---------------------------------------------------------------------------
class TestTransaction:
    def test_success_returns_submitted_and_convergence(self):
        client = FakeIntentAPI()
        payload = run_deployment_transaction(
            _envelope(), client=client, translator=_translator_ok, timeout_seconds=2, poll_seconds=0.05
        )
        assert [r["name"] for r in payload["submitted"]] == ["net-svc-alpha", "srv-svc-alpha"]
        # deterministic apply order: Network before SRv6Service
        assert [r["kind"] for r in payload["submitted"]] == ["Network", "SRv6Service"]
        for ref in payload["submitted"]:
            assert ref["namespace"] == "agentic-netops-intent"
        # convergence: fake never reports Ready -> timeout outcome, ready=null
        assert payload["convergence"]
        assert all(c["outcome"] == OUTCOME_TIMEOUT for c in payload["convergence"])
        assert all(r["ready"] is None for r in payload["submitted"])

    def test_success_with_ready_condition(self):
        client = FakeIntentAPI()
        # stamp the fake's stored objects Ready in place, so the watch sees it
        original_apply = client.apply

        def apply_then_ready(manifest):
            obj = original_apply(manifest)
            obj["status"] = {"conditions": [{"type": "Ready", "status": "True"}]}
            return obj

        client.apply = apply_then_ready  # type: ignore[method-assign]
        payload = run_deployment_transaction(_envelope(), client=client, translator=_translator_ok, watch=True)
        assert all(c["outcome"] == OUTCOME_READY for c in payload["convergence"])
        assert all(r["ready"] is True for r in payload["submitted"])

    def test_dry_run_rejection_names_resource_and_mutates_nothing(self):
        client = FakeIntentAPI(fail_dry_run_on="net-svc-alpha")
        with pytest.raises(DeploymentTransactionError) as excinfo:
            run_deployment_transaction(_envelope(), client=client, translator=_translator_ok, watch=False)
        assert excinfo.value.phase == "dry-run"
        assert excinfo.value.resource == "Network/net-svc-alpha"
        assert client.objects == {}

    def test_apply_failure_rolls_back_correlation_set(self):
        client = FakeIntentAPI(fail_apply_on="srv-svc-alpha")
        with pytest.raises(DeploymentTransactionError) as excinfo:
            run_deployment_transaction(_envelope(), client=client, translator=_translator_ok, watch=False)
        assert excinfo.value.phase == "apply"
        assert excinfo.value.resource == "SRv6Service/srv-svc-alpha"
        assert [f"{r.kind}/{r.name}" for r in excinfo.value.rolled_back] == ["Network/net-svc-alpha"]
        assert excinfo.value.survivors == []
        assert client.objects == {}

    def test_rollback_survivor_is_terminal(self):
        client = FakeIntentAPI(fail_apply_on="srv-svc-alpha", sticky_delete=True)
        with pytest.raises(DeploymentTransactionError) as excinfo:
            run_deployment_transaction(_envelope(), client=client, translator=_translator_ok, watch=False)
        assert [f"{r.kind}/{r.name}" for r in excinfo.value.survivors] == ["Network/net-svc-alpha"]
        report = excinfo.value.report()
        assert report["phase"] == "apply"
        assert report["survivors"]

    def test_translator_rejection_is_named(self):
        def rejecting_translator(intent):
            return {"detail": "422: unsupported property 'multicast'"}

        with pytest.raises(DeploymentTransactionError) as excinfo:
            run_deployment_transaction(_envelope(), client=FakeIntentAPI(), translator=rejecting_translator)
        assert excinfo.value.phase == "translation"

    def test_translator_crash_is_named(self):
        def crashing_translator(intent):
            raise RuntimeError("connection refused")

        with pytest.raises(DeploymentTransactionError) as excinfo:
            run_deployment_transaction(_envelope(), client=FakeIntentAPI(), translator=crashing_translator)
        assert excinfo.value.phase == "translation"
        assert "connection refused" in str(excinfo.value)

    def test_intent_schema_violation_is_named(self):
        bad = {**INTENT, "endpoints": [{"node": "leaf1", "port": "Ethernet1"}]}
        envelope = DeploymentEnvelope(
            intent=bad, context=DeploymentContext(correlation_id=CID, thread_id="t", principal="p")
        )
        with pytest.raises(DeploymentTransactionError) as excinfo:
            run_deployment_transaction(envelope, client=FakeIntentAPI(), translator=_translator_ok)
        assert excinfo.value.phase == "request-validation"

    def test_audit_trail_records_submit_and_refuse(self):
        reset_audit_sink()
        try:
            run_deployment_transaction(_envelope(), client=FakeIntentAPI(), translator=_translator_ok, watch=False)
            events = [e.event_type for e in get_audit_sink().events]
            assert events == ["submit"]

            reset_audit_sink()
            with pytest.raises(DeploymentTransactionError):
                run_deployment_transaction(
                    _envelope(),
                    client=FakeIntentAPI(fail_apply_on="srv-svc-alpha"),
                    translator=_translator_ok,
                    watch=False,
                )
            events = [e.event_type for e in get_audit_sink().events]
            assert events == ["refuse"]
        finally:
            reset_audit_sink()


# ---------------------------------------------------------------------------
# Step 7 — the convergence watch.
# ---------------------------------------------------------------------------
class TestConvergenceWatch:
    def _ref(self, name: str = "net-1", kind: str = "Network") -> Any:
        from common.schemas.refs import ResourceRef

        return ResourceRef(
            apiVersion="network.kubenet.dev/v1alpha1", kind=kind, namespace="agentic-netops-intent", name=name
        )

    def _client(self, obj: dict[str, Any] | None) -> Any:
        class One:
            def __init__(self):
                self.count = 0

            def get(self, ref):
                self.count += 1
                return obj

        return One()

    def test_ready_condition_true(self):
        obj = {"status": {"conditions": [{"type": "Ready", "status": "True"}]}}
        outcomes = watch_convergence(self._client(obj), [self._ref()], timeout_seconds=1, poll_seconds=0.05)
        assert outcomes[0].outcome == OUTCOME_READY
        assert outcomes[0].ref.ready is True

    def test_ready_condition_false_is_failure_with_detail(self):
        obj = {"status": {"conditions": [{"type": "Ready", "status": "False", "reason": "FabricDown"}]}}
        outcomes = watch_convergence(self._client(obj), [self._ref()], timeout_seconds=1, poll_seconds=0.05)
        assert outcomes[0].outcome == OUTCOME_FAILED
        assert outcomes[0].ref.ready is False
        assert "FabricDown" in (outcomes[0].detail or "")

    def test_terminal_failure_phase(self):
        obj = {"status": {"phase": "Failed"}}
        outcomes = watch_convergence(self._client(obj), [self._ref()], timeout_seconds=1, poll_seconds=0.05)
        assert outcomes[0].outcome == OUTCOME_FAILED

    def test_vanished_object_is_failure_not_timeout(self):
        outcomes = watch_convergence(self._client(None), [self._ref()], timeout_seconds=1, poll_seconds=0.05)
        assert outcomes[0].outcome == OUTCOME_FAILED
        assert "disappeared" in (outcomes[0].detail or "")

    def test_timeout_is_ready_null(self):
        obj = {"status": {"conditions": [{"type": "Ready", "status": "Unknown"}]}}
        outcomes = watch_convergence(self._client(obj), [self._ref()], timeout_seconds=0.2, poll_seconds=0.05)
        assert outcomes[0].outcome == OUTCOME_TIMEOUT
        assert outcomes[0].ref.ready is None


# ---------------------------------------------------------------------------
# Step 8 — truthful reporting at the agent boundary.
# ---------------------------------------------------------------------------
class TestDeployerAgentReporting:
    async def _invoke(self, text: str, monkeypatch, client=None, client_factory=None, translator=_translator_ok):
        from provisioning.deployer import submit as submit_mod
        from provisioning.deployer.agent import DeployerAgent

        if client_factory is not None:
            factory = client_factory
        else:
            factory = lambda: client or FakeIntentAPI()  # noqa: E731
        monkeypatch.setattr(submit_mod, "build_default_client", factory)
        import provisioning.deployer.tools.deployer_tools as tools_mod

        monkeypatch.setattr(tools_mod, "submit_service", translator)
        # keep the watch out of the default 45 s timeout in agent tests
        monkeypatch.setenv("DEPLOYER_CONVERGENCE_TIMEOUT_SECONDS", "0.2")
        monkeypatch.setenv("DEPLOYER_CONVERGENCE_POLL_SECONDS", "0.05")
        agent = DeployerAgent()
        return await agent.ainvoke(text)

    async def test_success_payload_has_submitted(self, monkeypatch):
        message, payload = await self._invoke(_envelope_json(), monkeypatch)
        assert [r["name"] for r in payload["submitted"]] == ["net-svc-alpha", "srv-svc-alpha"]
        data_part = message.parts[0].root.data
        assert data_part["submitted"]
        marker = message.parts[1].root.text.split("<!-- ")[1]
        assert marker.startswith("SUBMISSION_JSON: ")

    async def test_failure_payload_names_phase_and_never_submitted(self, monkeypatch):
        client = FakeIntentAPI(fail_apply_on="srv-svc-alpha")
        message, payload = await self._invoke(_envelope_json(), monkeypatch, client=client)
        assert "submitted" not in payload
        assert payload["failed"]["phase"] == "apply"
        assert payload["failed"]["resource"] == "SRv6Service/srv-svc-alpha"
        assert [f"{r['kind']}/{r['name']}" for r in payload["failed"]["rolledBack"]] == ["Network/net-svc-alpha"]
        text = message.parts[1].root.text
        assert "apply" in text

    async def test_translator_output_alone_is_never_a_report(self, monkeypatch):
        # The translator succeeds but the cluster client is unavailable: the
        # agent must report a failure, not a translator-shaped submission.

        def no_identity():
            raise DeploymentTransactionError("cluster-identity", "no Kubernetes service-account token is available")

        message, payload = await self._invoke(_envelope_json(), monkeypatch, client_factory=no_identity)
        assert "submitted" not in payload
        assert payload["failed"]["phase"] == "cluster-identity"

    async def test_tools_path_still_works(self, monkeypatch):
        text = json.dumps({"action": "status", "serviceId": "svc-alpha"})
        message, payload = await self._invoke(text, monkeypatch)
        assert payload["status"]["serviceId"] == "svc-alpha"


# ---------------------------------------------------------------------------
# Supervisor: envelope out, failure report handling in.
# ---------------------------------------------------------------------------
def _deployer_state() -> dict[str, Any]:
    return {
        "correlation_id": CID,
        "principal": "unit-test",
        "workflow_status": NetworkProvisioningStatus.APPROVED.value,
        "confirmation_2": {"decided": "confirm", "at": "2026-09-01T00:00:00Z", "principal": "unit-test"},
        "allocated_resources": canonical_json(INTENT),
    }


class CapturingTransport(StubTransport):
    """Records the fenced payload sent to the deployer; returns a canned worker response."""

    def __init__(self, parts: list[dict[str, Any]]) -> None:
        super().__init__()
        self.parts = parts

    async def call_deployer(self, text: str) -> Any:
        await super().call_deployer(text)
        return {"parts": self.parts}


def _marker_text(summary: str, payload: dict[str, Any]) -> str:
    return summary + f"<!-- SUBMISSION_JSON: {json.dumps(payload, separators=(',', ':'), sort_keys=True)} -->"


def _deployer_parts(submitted: list[dict[str, Any]]) -> list[dict[str, Any]]:
    payload = {"submitted": submitted}
    return [
        {"data": payload},
        {"text": _marker_text("Submission report received.\n", payload)},
    ]


def _failed_parts() -> list[dict[str, Any]]:
    payload = {
        "failed": {
            "phase": "apply",
            "resource": "SRv6Service/srv-svc-alpha",
            "message": "apply failed for SRv6Service/srv-svc-alpha: HTTP 409",
            "rolledBack": [
                {
                    "apiVersion": "network.kubenet.dev/v1alpha1",
                    "kind": "Network",
                    "namespace": "agentic-netops-intent",
                    "name": "net-svc-alpha",
                }
            ],
            "survivors": [],
        }
    }
    return [
        {"data": payload},
        {"text": _marker_text("Deployment failed during apply.\n", payload)},
    ]


@pytest.fixture()
def graph_llm():
    return StubClassifierLLM()


class TestSupervisorEnvelopeAndFailure:
    async def test_supervisor_sends_deployment_envelope(self, graph_llm):
        captured: list[str] = []

        class EnvelopeTransport(StubTransport):
            async def call_deployer(self, text: str) -> Any:
                captured.append(text)
                return {"parts": _deployer_parts([
                    {
                        "apiVersion": "network.kubenet.dev/v1alpha1",
                        "kind": "Network",
                        "namespace": "agentic-netops-intent",
                        "name": "net-svc-alpha",
                    }
                ])}

        reset_audit_sink()
        transport = EnvelopeTransport()
        graph = ProvisioningGraph(
            llm_factory=lambda streaming=None: RunnableLambda(graph_llm.ainvoke),
            transport=transport,
        )
        try:
            out = await graph._deployer_node(_deployer_state(), {"configurable": {"thread_id": "unit-thread"}})
        finally:
            await graph.close()
        assert out["workflow_status"] == NetworkProvisioningStatus.PROVISIONING.value
        assert len(captured) == 1
        fence = captured[0]
        start = fence.index(">>>\n") + 4
        end = fence.rindex("\n<<<END_DATA")
        envelope = json.loads(fence[start:end])
        assert envelope["action"] == "submit"
        assert envelope["intent"] == INTENT
        assert envelope["context"]["correlationId"] == CID
        assert envelope["context"]["threadId"] == "unit-thread"
        assert envelope["context"]["principal"] == "unit-test"

    async def test_failed_report_ends_failed_and_names_survivors(self, graph_llm):
        reset_audit_sink()
        transport = CapturingTransport(_failed_parts())
        graph = ProvisioningGraph(
            llm_factory=lambda streaming=None: RunnableLambda(graph_llm.ainvoke),
            transport=transport,
        )
        try:
            out = await graph._deployer_node(_deployer_state(), {"configurable": {"thread_id": "unit-thread"}})
        finally:
            await graph.close()
        assert out["workflow_status"] == NetworkProvisioningStatus.FAILED.value
        assert out["next_node"] == "__end__"
        assert "apply" in out["refusal_reason"]
        text = out["messages"][0].content
        assert "Nothing is reported as submitted" in text
        assert "1 resource(s) were rolled back" in text
        assert get_audit_sink().by_correlation(CID)[0].event_type == "refuse"

    async def test_submitted_report_still_reaches_provisioning(self, graph_llm):
        reset_audit_sink()
        transport = CapturingTransport(_deployer_parts([
            {
                "apiVersion": "network.kubenet.dev/v1alpha1",
                "kind": "Network",
                "namespace": "agentic-netops-intent",
                "name": "net-svc-alpha",
            }
        ]))
        graph = ProvisioningGraph(
            llm_factory=lambda streaming=None: RunnableLambda(graph_llm.ainvoke),
            transport=transport,
        )
        try:
            out = await graph._deployer_node(_deployer_state(), {"configurable": {"thread_id": "unit-thread"}})
        finally:
            await graph.close()
        assert out["workflow_status"] == NetworkProvisioningStatus.PROVISIONING.value
        submit_events = [e for e in get_audit_sink().by_correlation(CID) if e.event_type == "submit"]
        assert len(submit_events) == 1
        assert submit_events[0].resources[0].name == "net-svc-alpha"


# ---------------------------------------------------------------------------
# The last mile: the operator learns the OUTCOME, in-band.
#
# Before this, the conversation ended at the submission report — the Network
# converged (or failed) minutes later and nothing on the thread ever said so
# (docs/FINAL_STATUS_NOTIFICATION_GAP.md). The deployer already watched
# convergence and reported it; the supervisor dropped that report on the floor.
# ---------------------------------------------------------------------------
NET_REF = {
    "apiVersion": "network.kubenet.dev/v1alpha1",
    "kind": "Network",
    "namespace": "agentic-netops-intent",
    "name": "net-svc-alpha",
}


def _deployer_parts_with_convergence(convergence: list[dict[str, Any]]) -> list[dict[str, Any]]:
    payload = {"submitted": [NET_REF], "convergence": convergence}
    return [
        {"data": payload},
        {"text": _marker_text("Submission report received.\n", payload)},
    ]


class CannedTransport(StubTransport):
    """Returns canned deployer parts without parsing the request.

    The tools path (status/remove) does not carry an intent, so
    :class:`CapturingTransport`'s envelope parsing cannot be reused for it.
    """

    def __init__(self, parts: list[dict[str, Any]]) -> None:
        super().__init__()
        self.parts = parts
        self.sent: list[str] = []

    async def call_deployer(self, text: str) -> Any:
        self.sent.append(text)
        return {"parts": self.parts}


async def _run_deployer_node(graph_llm, parts: list[dict[str, Any]], state: dict[str, Any] | None = None):
    reset_audit_sink()
    graph = ProvisioningGraph(
        llm_factory=lambda streaming=None: RunnableLambda(graph_llm.ainvoke),
        transport=CannedTransport(parts),
    )
    try:
        return await graph._deployer_node(
            state if state is not None else _deployer_state(),
            {"configurable": {"thread_id": "unit-thread"}},
        )
    finally:
        await graph.close()


class TestFinalOutcomeReporting:
    async def test_all_ready_ends_completed_and_quotes_the_condition(self, graph_llm):
        out = await _run_deployer_node(
            graph_llm,
            _deployer_parts_with_convergence(
                [
                    {
                        "resource": "Network/net-svc-alpha",
                        "outcome": "ready",
                        "ready": True,
                        "detail": "applied and verified on all nodes",
                    }
                ]
            ),
        )
        assert out["workflow_status"] == NetworkProvisioningStatus.COMPLETED.value
        text = out["messages"][0].content
        assert "Deployed." in text
        # The controller's own condition message, not a paraphrase of it.
        assert "applied and verified on all nodes" in text
        assert "Network/net-svc-alpha" in text
        # The submission itself is still audited as a submission.
        submits = [e for e in get_audit_sink().by_correlation(CID) if e.event_type == "submit"]
        assert len(submits) == 1

    async def test_failed_convergence_ends_failed_with_the_condition_message(self, graph_llm):
        out = await _run_deployer_node(
            graph_llm,
            _deployer_parts_with_convergence(
                [
                    {
                        "resource": "Network/net-svc-alpha",
                        "outcome": "failed",
                        "ready": False,
                        "detail": "ApplyFailed: leaf2 rejected the VRF binding",
                    }
                ]
            ),
        )
        assert out["workflow_status"] == NetworkProvisioningStatus.FAILED.value
        assert "convergence failed" in out["refusal_reason"]
        text = out["messages"][0].content
        assert "leaf2 rejected the VRF binding" in text
        # A convergence failure is NOT a rollback: the apply succeeded.
        assert "remain on the cluster" in text
        # ...and it is not recorded as a refusal, which would claim nothing
        # was applied and break the SC-006 reconciliation.
        assert [e.event_type for e in get_audit_sink().by_correlation(CID)] == ["submit"]

    async def test_timeout_stays_provisioning_and_says_how_to_resolve_it(self, graph_llm):
        out = await _run_deployer_node(
            graph_llm,
            _deployer_parts_with_convergence(
                [
                    {
                        "resource": "Network/net-svc-alpha",
                        "outcome": "timeout",
                        "ready": None,
                        "detail": "convergence timeout after 90s",
                    }
                ]
            ),
        )
        assert out["workflow_status"] == NetworkProvisioningStatus.PROVISIONING.value
        text = out["messages"][0].content
        assert "still converging" in text
        assert "status of the deployment" in text

    async def test_no_convergence_report_never_claims_an_outcome(self, graph_llm):
        out = await _run_deployer_node(graph_llm, _deployer_parts([NET_REF]))
        assert out["workflow_status"] == NetworkProvisioningStatus.PROVISIONING.value
        assert "not yet known" in out["messages"][0].content

    async def test_submitted_refs_and_convergence_are_carried_on_the_thread(self, graph_llm):
        convergence = [
            {"resource": "Network/net-svc-alpha", "outcome": "ready", "ready": True, "detail": "ok"}
        ]
        out = await _run_deployer_node(graph_llm, _deployer_parts_with_convergence(convergence))
        assert json.loads(out["convergence"]) == convergence
        assert [r["name"] for r in json.loads(out["submitted_resources"])] == ["net-svc-alpha"]
        # The label the objects actually carry — the only selector that finds
        # them once the next request has minted a new correlation id.
        assert out["submitted_correlation_id"] == CID


class TestStatusQuestionOnACompletedThread:
    """Root cause 4: "what is the status of the deployment?" used to fall into
    the capability blurb, reporting the thread's stale status."""

    def test_the_question_is_recognised(self):
        from supervisors.provisioning.graph.graph import detect_deployment_status_query

        for question in (
            "What is the status of the deployment?",
            "what's the status?",
            "Is it deployed?",
            "did it converge",
            "deployment status please",
            "has the service deployed?",
        ):
            assert detect_deployment_status_query(question), question

    def test_a_provisioning_request_is_not_a_status_question(self):
        from supervisors.provisioning.graph.graph import detect_deployment_status_query

        assert not detect_deployment_status_query(
            "Create an L3VPN between leaf1 Ethernet1 and leaf2 Ethernet2 for tenant-a"
        )

    async def test_status_question_routes_to_the_cluster_not_the_blurb(self, graph_llm):
        from langchain_core.messages import HumanMessage

        graph = ProvisioningGraph(
            llm_factory=lambda streaming=None: RunnableLambda(graph_llm.ainvoke),
            transport=StubTransport(),
        )
        state = {
            "messages": [HumanMessage(content="What is the status of the deployment?")],
            # The HTTP surface mints a fresh correlation id for every request,
            # so the thread's current id is NOT the one the submitted objects
            # are labelled with. Resolving on the current id finds nothing and
            # reports "NotFound" for a Network that is Ready (observed live,
            # 2026-09-04).
            "correlation_id": "c" * 32,
            "submitted_correlation_id": CID,
            "principal": "unit-test",
            "workflow_status": NetworkProvisioningStatus.PROVISIONING.value,
            "submitted_resources": canonical_json([NET_REF]),
        }
        try:
            out = await graph._supervisor_node(state, {"configurable": {"thread_id": "unit-thread"}})
        finally:
            await graph.close()
        assert out["next_node"] == "deployer"
        assert out["tool_action"] == "status"
        assert json.loads(out["tool_request"]) == {"action": "status", "correlationId": CID}

    async def test_without_a_submission_the_question_is_not_hijacked(self, graph_llm):
        from langchain_core.messages import HumanMessage

        graph = ProvisioningGraph(
            llm_factory=lambda streaming=None: RunnableLambda(graph_llm.ainvoke),
            transport=StubTransport(),
        )
        state = {
            "messages": [HumanMessage(content="What is the status of the deployment?")],
            "correlation_id": CID,
            "principal": "unit-test",
            "workflow_status": NetworkProvisioningStatus.RECEIVED_REQUEST.value,
        }
        try:
            out = await graph._supervisor_node(state, {"configurable": {"thread_id": "unit-thread"}})
        finally:
            await graph.close()
        assert out.get("tool_action") is None

    async def test_a_resolved_status_answer_sets_the_thread_status(self, graph_llm):
        report = {
            "status": {
                "serviceId": "",
                "correlationId": CID,
                "phase": "Deployed",
                "resources": [
                    {
                        "kind": "Network",
                        "name": "net-svc-alpha",
                        "ready": True,
                        "reason": "ApplySucceeded",
                        "message": "applied and verified on all nodes",
                        "lastTransitionTime": "2026-09-04T07:48:18Z",
                    }
                ],
            }
        }
        parts = [{"data": report}, {"text": _marker_text("Deployed. Network/net-svc-alpha Ready=True.\n", report)}]
        state = {
            **_deployer_state(),
            "tool_action": "status",
            "tool_request": canonical_json({"action": "status", "correlationId": CID}),
        }
        out = await _run_deployer_node(graph_llm, parts, state=state)
        assert out["workflow_status"] == NetworkProvisioningStatus.COMPLETED.value
        assert "Deployed." in out["messages"][0].content

    async def test_a_resolved_failure_answer_names_the_responsible_stage(self, graph_llm):
        report = {"status": {"correlationId": CID, "phase": "Failed", "resources": []}}
        parts = [{"data": report}, {"text": _marker_text("Failed.\n", report)}]
        state = {
            **_deployer_state(),
            "tool_action": "status",
            "tool_request": canonical_json({"action": "status", "correlationId": CID}),
        }
        out = await _run_deployer_node(graph_llm, parts, state=state)
        assert out["workflow_status"] == NetworkProvisioningStatus.FAILED.value
        assert out["refusal_reason"].startswith("deployer ")


class TestInformationalAnswerDoesNotRelabelTheThread:
    async def test_a_question_mid_transaction_keeps_provisioning(self, graph_llm):
        graph = ProvisioningGraph(
            llm_factory=lambda streaming=None: RunnableLambda(graph_llm.ainvoke),
            transport=StubTransport(),
        )
        state = {
            "messages": [],
            "workflow_status": NetworkProvisioningStatus.PROVISIONING.value,
            "submitted_resources": canonical_json([NET_REF]),
        }
        try:
            out = await graph._general_response_node(state, {"configurable": {"thread_id": "unit-thread"}})
        finally:
            await graph.close()
        assert out["workflow_status"] == NetworkProvisioningStatus.PROVISIONING.value
        assert "still converging" in out["messages"][0].content
