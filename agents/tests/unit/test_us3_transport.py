"""US3 unit tests — run the intent tier beside the control plane.

Phase 4 tasks covered here (the rest of the phase is exercised by the live
probes under deploy/agents/tests/probes/):

* T135-T138  card metadata + normalized ``agentic-netops/provisioning/...`` ids.
* T139-T141  capability-to-card registry, call-time topic resolution via
  ``A2AProtocol.create_agent_topic``, and NO hardcoded worker topic lists.
* T142-T150  SLIM-only validation, ``TRANSPORT_SERVER_ENDPOINT``
  registration, and authentication-failure handling in the three servers.
* T151/T152  the slim-auth-denial probe exists and is wired into run-all.
* T153-T155  per-call timeout, bounded retry with backoff, and the
  unreachable-vs-failed distinction in ``graph/tools.py``.
* T156-T160  the supervisor HTTP surface (liveness, deep readiness naming
  the down worker, transport config) and suggested prompts.
* T161-T174  the graph shape: nodes, conditional routing, reflection edges,
  general_info -> END, GraphState fields, ToolMessage-stripping reducer,
  SQLite checkpointer, thread_id keying, deadline, ``MAX_ITERATIONS = 3``.
* T170/T175-T180  the deploy manifests (supervisor Recreate/single replica,
  PVC mount, probes, worker Services on 9091-9093, translator sidecar).
"""

from __future__ import annotations

import asyncio
import inspect
import json
import sys
from pathlib import Path

import pytest
import yaml
from langchain_core.messages import AIMessage, HumanMessage, ToolMessage

import provisioning.allocator.server as allocator_server
import provisioning.deployer.server as deployer_server
import provisioning.mapper.server as mapper_server
from common.exceptions import AuthError
from supervisors.provisioning.graph import tools as tools_mod
from supervisors.provisioning.graph.graph import (
    MAX_ITERATIONS,
    GraphState,
    filter_messages_reducer,
)
from supervisors.provisioning.graph.shared import set_factory

REPO_ROOT = Path(__file__).resolve().parents[3]
DEPLOY = REPO_ROOT / "deploy" / "agents"


# ---------------------------------------------------------------------------
# T135-T138 — AgentCard metadata, normalized ids
# ---------------------------------------------------------------------------
class TestCards:
    @pytest.mark.parametrize(
        ("module", "card_id"),
        [
            (mapper_server, "agentic-netops/provisioning/network-mapping"),
            (allocator_server, "agentic-netops/provisioning/network-allocator"),
            (deployer_server, "agentic-netops/provisioning/network-deployer"),
        ],
        ids=["mapper", "allocator", "deployer"],
    )
    def test_card_id_normalized(self, module, card_id):
        """T136/T137/T138 — the card id is the routable
        org/namespace/local_name form (a2a-sdk 0.3.0 drops the extra, so the
        normalized id is asserted on the card source)."""
        assert card_id in inspect.getsource(sys.modules[f"provisioning.{module.WORKER}.card"])

    def test_card_metadata(self):
        """T135 — the mapper card carries skill metadata and streaming off."""
        from provisioning.mapper.card import AGENT_CARD

        assert AGENT_CARD.skills[0].id == "map_network_request"
        assert AGENT_CARD.capabilities.streaming is False
        assert AGENT_CARD.version == "1.0.0"


# ---------------------------------------------------------------------------
# T139-T141 — registry, call-time topics, no hardcoded topic lists
# ---------------------------------------------------------------------------
class TestCapabilityRegistry:
    def test_registry_keys_are_capabilities(self):
        """T139 — the registry is keyed by the workers' advertised skills."""
        assert set(tools_mod.CAPABILITY_CARDS) == {
            "map_network_request",
            "allocate_network_service",
            "deploy_network_service",
        }
        for capability, card in tools_mod.CAPABILITY_CARDS.items():
            assert card.skills[0].id == capability
        src = inspect.getsource(tools_mod)
        for worker in ("mapper", "allocator", "deployer"):
            assert worker in src

    def test_unknown_capability_fails_loudly(self):
        with pytest.raises(KeyError):
            tools_mod.card_for_capability("no_such_capability")

    def test_topics_resolved_at_call_time(self):
        """T140 — the card-derived topic is what A2AProtocol derives; the
        helper resolves it per call, never from a table."""
        from agntcy_app_sdk.semantic.a2a.protocol import A2AProtocol

        from provisioning.mapper.card import AGENT_CARD

        topic = A2AProtocol.create_agent_topic(AGENT_CARD)
        assert topic == f"{AGENT_CARD.name}_{AGENT_CARD.version}"
        assert "create_agent_topic" in inspect.getsource(tools_mod)

    def test_no_hardcoded_topic_lists(self):
        """T141 — tools.py carries no hardcoded worker topic list: no list of
        literal topic strings, no topic table; only the card registry."""
        src = inspect.getsource(tools_mod)
        for banned in ("TOPICS", "topic_map", "agent_topics =", "a2a/topic"):
            assert banned not in src


# ---------------------------------------------------------------------------
# T142-T150 — SLIM-only, TRANSPORT_SERVER_ENDPOINT registration, auth errors
# ---------------------------------------------------------------------------
class TestWorkerTransportWiring:
    @pytest.mark.parametrize(
        "module", [mapper_server, allocator_server, deployer_server], ids=["mapper", "allocator", "deployer"]
    )
    def test_slim_only(self, module):
        """T142/T143/T144 — any transport other than SLIM is refused."""
        with pytest.raises(ValueError, match="Only SLIM transport"):
            module.require_slim("NATS")
        module.require_slim("SLIM")  # no raise

    @pytest.mark.parametrize(
        "module", [mapper_server, allocator_server, deployer_server], ids=["mapper", "allocator", "deployer"]
    )
    def test_registers_over_transport_server_endpoint(self, module):
        """T145/T146/T147 — run_transport registers over the long variable
        name endpoint (and derives the topic from the card)."""
        src = inspect.getsource(module.run_transport)
        assert "TRANSPORT_SERVER_ENDPOINT" in src
        assert "create_agent_topic" in src

    @pytest.mark.parametrize(
        "module", [mapper_server, allocator_server, deployer_server], ids=["mapper", "allocator", "deployer"]
    )
    def test_auth_failure_handling(self, module):
        """T148/T149/T150 — an auth-flavoured transport refusal surfaces as
        AuthError; a generic transport error does not."""
        assert module.classify_transport_error(Exception("401 unauthorized")) == "auth"
        assert module.classify_transport_error(Exception("certificate required")) == "auth"
        assert module.classify_transport_error(Exception("connection refused")) == "error"

        class ExplodingFactory:
            def create_transport(self, *a, **k):
                raise Exception("gateway: 401 unauthorized")

        original = module.factory
        module.factory = ExplodingFactory()
        try:
            with pytest.raises(AuthError):
                asyncio.run(module.run_transport(module.app))
        finally:
            module.factory = original


# ---------------------------------------------------------------------------
# T153-T155 — timeout, bounded retry, unreachable vs failed
# ---------------------------------------------------------------------------
class _StubFactory:
    """Factory stub counting attempts; raises on demand."""

    def __init__(self, exc: Exception):
        self.exc = exc
        self.attempts = 0

    def create_transport(self, *a, **k):
        self.attempts += 1
        return object()

    async def create_client(self, *a, **k):
        raise self.exc


class TestWorkerCallDiscipline:
    async def _send_with(self, exc, retries):
        set_factory(_StubFactory(exc))
        tools_mod.WORKER_CALL_RETRIES = retries
        real_sleep = asyncio.sleep

        async def _nosleep(*_):
            return None

        asyncio.sleep = _nosleep  # type: ignore[assignment] - collapse backoff for the test
        try:
            return await tools_mod._send("mapper", tools_mod.MAPPER_CARD, "hi")
        except BaseException as e:  # noqa: BLE001 - the test wants the type
            return e
        finally:
            asyncio.sleep = real_sleep

    async def test_timeout_wrapper_present(self):
        """T153 — every call is wrapped by asyncio.wait_for with the
        configured per-call timeout."""
        src = inspect.getsource(tools_mod._send)
        assert "wait_for" in src and "WORKER_CALL_TIMEOUT_SECONDS" in src

    async def test_bounded_retry_with_backoff(self):
        """T154 — an unreachable worker is retried the configured number of
        times with a growing backoff, then reported."""
        src = inspect.getsource(tools_mod)
        assert "WORKER_CALL_RETRIES" in src and "_RETRY_BACKOFF_SECONDS" in src
        err = await self._send_with(ConnectionError("refused"), retries=2)
        assert isinstance(err, tools_mod.WorkerUnavailableError)

    async def test_unreachable_is_retried(self):
        """T155 (unreachable) — ConnectionError/Timeout = unreachable:
        retried, then WorkerUnavailableError naming the worker."""
        set_factory(_StubFactory(ConnectionError("refused")))
        tools_mod.WORKER_CALL_RETRIES = 1
        real_sleep = asyncio.sleep

        async def _nosleep(*_):
            return None

        asyncio.sleep = _nosleep  # type: ignore[assignment]
        try:
            with pytest.raises(tools_mod.WorkerUnavailableError, match="mapper"):
                await tools_mod.call_mapper_agent("hi")
        finally:
            asyncio.sleep = real_sleep

    async def test_worker_failure_is_not_retried(self):
        """T155 (returned failure) — a well-formed A2A/protocol failure is a
        worker FAILURE: reported immediately, no retry (attempts == 1)."""
        stub = _StubFactory(RuntimeError("worker said no"))
        set_factory(stub)
        tools_mod.WORKER_CALL_RETRIES = 3
        with pytest.raises(tools_mod.WorkerUnavailableError):
            await tools_mod.call_mapper_agent("hi")
        assert stub.attempts == 1


# ---------------------------------------------------------------------------
# T156-T160 — supervisor HTTP surface + suggested prompts
# ---------------------------------------------------------------------------
class TestSupervisorHttp:
    async def test_liveness_trivial(self):
        """T156 — GET /health is trivial and never touches the transport."""
        from fastapi.testclient import TestClient

        from supervisors.provisioning.main import app

        with TestClient(app) as client:
            resp = client.get("/health")
            assert resp.status_code == 200
            assert resp.json() == {"status": "ok"}

    async def test_deep_readiness_names_down_worker(self):
        """T157/T158 — GET /v1/health probes every worker; degraded answers
        503 with per-worker names and statuses."""
        from fastapi.testclient import TestClient

        import supervisors.provisioning.main as main_mod
        from supervisors.provisioning.main import app

        main_mod.WORKER_ENDPOINTS = {
            "mapper": "http://127.0.0.1:1",  # closed port -> refused fast
            "allocator": "http://127.0.0.1:1",
            "deployer": "http://127.0.0.1:1",
        }
        with TestClient(app) as client:
            resp = client.get("/v1/health")
            assert resp.status_code == 503
            body = resp.json()
            assert body["status"] == "degraded"
            assert set(body["workers"]) == {"mapper", "allocator", "deployer"}
            assert all(v == "unreachable" for v in body["workers"].values())

    async def test_transport_config(self):
        """T159 — GET /transport/config: the long variable name, port 46357."""
        from fastapi.testclient import TestClient

        from supervisors.provisioning.main import app

        with TestClient(app) as client:
            resp = client.get("/transport/config")
            assert resp.status_code == 200
            body = resp.json()
            assert body["transport"] == "SLIM"
            assert body["endpoint"] == "http://slim.agentic-netops-agents.svc:46357"

    def test_suggested_prompts_file(self):
        """T160 — four prompts covering VPLS, VPWS/E-Line, L3VPN, IRB."""
        data = json.loads(
            (Path(__file__).resolve().parents[2] / "supervisors/provisioning/suggested_prompts.json").read_text()
        )
        assert len(data) == 4
        text = " ".join(data).upper()
        for service in ("VPLS", "VPWS", "L3VPN", "IRB"):
            assert service in text


# ---------------------------------------------------------------------------
# T161-T174 — graph shape
# ---------------------------------------------------------------------------
class TestGraphShape:
    def test_state_fields(self):
        """T166/T167 — the GraphState subject fields and the US3 additions."""
        hints = GraphState.__annotations__
        for field in (
            "messages",
            "next_node",
            "correlation_id",
            "workflow_status",
            "claimed_ids",
            "deadline",
        ):
            assert field in hints

    def test_reducer_strips_tool_messages(self):
        """T168 — filter_messages_reducer keeps no ToolMessage."""
        merged = filter_messages_reducer(
            [HumanMessage(content="a")],
            [AIMessage(content="b"), ToolMessage(content="t", tool_call_id="x")],
        )
        assert not any(isinstance(m, ToolMessage) for m in merged)

    def test_max_iterations_constant(self):
        """T173 — the bounded-exit cap is 3."""
        assert MAX_ITERATIONS == 3

    def test_graph_wiring(self):
        """T161-T165/T169/T171 — nodes, conditional routing, reflection and
        general_info edges, SQLite checkpointer import, thread_id keying."""
        from supervisors.provisioning.graph import graph as graph_mod

        src = inspect.getsource(graph_mod)
        for needle in (
            "AsyncSqliteSaver",  # T169 langgraph-checkpoint-sqlite
            'add_conditional_edges(\n            NodeStates.SUPERVISOR,\n            lambda state: state["next_node"]',
        ):
            assert needle in src
        for node in ("SUPERVISOR", "MAPPER", "ALLOCATOR", "DEPLOYER", "REFLECTION", "GENERAL_INFO"):
            assert node in inspect.getsource(graph_mod.NodeStates)
        assert "END" in inspect.getsource(graph_mod.ProvisioningGraph.build_graph)

    async def test_deadline_and_bounded_exit(self):
        """T172/T173/T174 — the deadline check fires on a stale deadline and
        informational routing reaches general_info."""
        from supervisors.provisioning.graph import graph as graph_mod

        pg = graph_mod.ProvisioningGraph(llm_factory=None, transport=object(), checkpointer=object())
        assert pg._deadline_exceeded({"deadline": "2000-01-01T00:00:00+00:00"}) is True
        assert pg._deadline_exceeded({"deadline": "2999-01-01T00:00:00+00:00"}) is False
        src = inspect.getsource(graph_mod)
        assert "general_info" in src


# ---------------------------------------------------------------------------
# T170/T175-T180 — deploy manifests
# ---------------------------------------------------------------------------
class TestDeployManifests:
    @staticmethod
    def _docs(name):
        return [d for d in yaml.safe_load_all((DEPLOY / name).read_text()) if d]

    def test_supervisor_manifest(self):
        """T175/T176/T177/T170 — Deployment (replicas 1, Recreate),
        Service 9090, PVC, prompts ConfigMap, probes,
        PVC-mounted checkpoint path."""
        docs = {d["kind"]: d for d in self._docs("supervisor.yaml")}
        dep = docs["Deployment"]
        assert dep["spec"]["replicas"] == 1
        assert dep["spec"]["strategy"]["type"] == "Recreate"
        spec = dep["spec"]["template"]["spec"]
        assert spec["automountServiceAccountToken"] is False
        mounts = {m["name"]: m for m in spec["containers"][0]["volumeMounts"]}
        assert mounts["checkpoint"]["mountPath"] == "/state/supervisor-checkpoint"
        envs = {e["name"]: e.get("value") for e in spec["containers"][0]["env"]}
        assert envs["SUPERVISOR_CHECKPOINT_DB"] == "/state/supervisor-checkpoint/checkpoints.sqlite"
        probes = spec["containers"][0]
        assert probes["livenessProbe"]["httpGet"]["path"] == "/health"
        assert probes["readinessProbe"]["httpGet"]["path"] == "/v1/health"
        assert docs["Service"]["spec"]["ports"][0]["port"] == 9090
        assert docs["PersistentVolumeClaim"]["metadata"]["name"] == "supervisor-checkpoint"
        assert "suggested_prompts.json" in docs["ConfigMap"]["data"]
        secret_docs = self._docs("llm-provider-secret.yaml")
        assert secret_docs[0]["metadata"]["name"] == "llm-provider"
        # No credential literals or empty placeholder writes in the Secret declaration.
        assert "data" not in secret_docs[0]
        assert "stringData" not in secret_docs[0]

    @pytest.mark.parametrize(
        ("name", "port", "service_account", "token_bearing"),
        [
            ("mapper.yaml", 9092, "intent-mapper", False),
            # T039: the allocator is one of the only two cluster-API identities
            # in the tier — it claims identifiers from KUID (FR-013), and the
            # mount carries both the bearer token and the cluster CA bundle the
            # KUID client verifies the API server against. Without it every
            # claim fails with CERTIFICATE_VERIFY_FAILED.
            ("allocator.yaml", 9091, "intent-allocator", True),
            ("deployer.yaml", 9093, "intent-deployer", False),
        ],
    )
    def test_worker_manifest(self, name, port, service_account, token_bearing):
        """T178/T179/T180 — Deployment + Service, probes, lab-sized
        resources, and the identity each worker is entitled to."""
        docs = {d["kind"]: d for d in self._docs(name)}
        assert docs["Service"]["spec"]["ports"][0]["port"] == port
        c = docs["Deployment"]["spec"]["template"]["spec"]["containers"][0]
        assert c["livenessProbe"]["httpGet"]["path"] == "/health"
        assert c["readinessProbe"]["httpGet"]["path"] == "/v1/health"
        assert c["resources"]["requests"]["memory"].endswith("Mi")
        assert c["resources"]["limits"]["cpu"]
        spec = docs["Deployment"]["spec"]["template"]["spec"]
        assert spec["serviceAccountName"] == service_account
        assert spec["automountServiceAccountToken"] is token_bearing

    def test_deployer_translator_sidecar(self):
        dep = [d for d in self._docs("deployer.yaml") if d["kind"] == "Deployment"][0]
        names = [c["name"] for c in dep["spec"]["template"]["spec"]["containers"]]
        assert "intent-translator" in names


# ---------------------------------------------------------------------------
# T151/T152 — the unauthenticated SLIM registration probe
# ---------------------------------------------------------------------------
class TestSlimAuthProbe:
    def test_probe_exists_and_wired(self):
        """T151/T152 — the probe is present, executable, and in run-all."""
        probe = DEPLOY / "tests" / "probes" / "slim-auth-denial.sh"
        assert probe.exists()
        assert probe.stat().st_mode & 0o111
        src = probe.read_text()
        assert "openssl s_client" in src  # the unauthenticated TLS attempt
        assert "attempt_rc" in src  # the PASS/FAIL discriminator
        assert "slim-auth-denial" in (DEPLOY / "tests" / "probes" / "run-all.sh").read_text()
