"""US2 e2e — audit/resource reconciliation (T131-T133).

SC-006's independent test against a REAL cluster: the intent tier runs the
full two-confirmation flow through the production supervisor graph with a
deployer transport that SUBMITS real ``Network`` objects (labeled with the
correlation id) through the tier's own writer identity, and the audit
emission (``common/audit.py``) writes real Kubernetes ``Event`` objects
with the same identity. The assertions then reconcile:

* T131 (setup) — module fixture: cluster reachable, namespace present, a
  short-lived SA token minted for ``intent-deployer`` (the tier's only
  cluster-writer identity), the audit k8s identity env vars set.
* T132 (count equality) — the number of ``Network`` objects present under
  the correlation-id label equals the number of resources in the ``submit``
  audit event, name for name; and the ``Confirm``/``Submit`` Kubernetes
  Events actually exist in the namespace (T104 end-to-end).
* T133 (missing-confirmation failure) — a thread stopped short of the
  second confirmation submits NOTHING: zero resources under its
  correlation id, no ``submit`` audit event, the deployer worker never
  called.

Runs only when selected (``pytest -m e2e``): it needs kubectl + the kind
cluster with ``deploy/agents/namespace-rbac.yaml`` applied.
"""

from __future__ import annotations

import json
import re
import secrets
import subprocess
from typing import Any

import httpx
import pytest
from langchain_core.messages import HumanMessage
from langchain_core.runnables import RunnableLambda

from common.audit import get_audit_sink, reset_audit_sink
from common.provisioning_states import NetworkProvisioningStatus
from supervisors.provisioning.graph.graph import ProvisioningGraph, default_deadline
from tests.corpus.adversarial.runner import StubClassifierLLM, StubTransport

pytestmark = pytest.mark.e2e

NS = "agentic-netops-intent"
NS_AGENTS = "agentic-netops-agents"
CORR_LABEL = "agentic-netops.io/correlation-id"
REQUEST = (
    "provision a point-to-point 1Gbps VPWS service between leaf01 ethernet1 "
    "and leaf02 ethernet2 for tenant acme, vlan 100"
)


# ---------------------------------------------------------------------------
# Cluster access (the e2e identity: intent-deployer, the tier's writer SA).
# ---------------------------------------------------------------------------
def kubectl(*args: str) -> str:
    proc = subprocess.run(
        ["kubectl", *args], capture_output=True, text=True, timeout=60
    )
    if proc.returncode != 0:
        raise RuntimeError(f"kubectl {' '.join(args)} failed: {proc.stderr.strip()}")
    return proc.stdout.strip()


class Cluster:
    """Minimal REST client for the kind API with the minted SA token."""

    def __init__(self, base: str, token: str) -> None:
        self.base = base.rstrip("/")
        self.token = token

    def _headers(self) -> dict[str, str]:
        return {"Authorization": f"Bearer {self.token}"}

    def get(self, path: str, params: dict | None = None) -> httpx.Response:
        return httpx.get(f"{self.base}{path}", headers=self._headers(), params=params, verify=False, timeout=30.0)

    def post(self, path: str, manifest: dict[str, Any]) -> httpx.Response:
        return httpx.post(f"{self.base}{path}", json=manifest, headers=self._headers(), verify=False, timeout=30.0)

    def delete(self, path: str) -> httpx.Response:
        return httpx.delete(f"{self.base}{path}", headers=self._headers(), verify=False, timeout=30.0)

    def networks_by_correlation(self, cid: str) -> list[dict[str, Any]]:
        resp = self.get(
            f"/apis/network.kubenet.dev/v1alpha1/namespaces/{NS}/networks",
            params={"labelSelector": f"{CORR_LABEL}={cid}"},
        )
        assert resp.status_code == 200, f"list networks: {resp.status_code} {resp.text[:200]}"
        return resp.json()["items"]

    @staticmethod
    def k8s_events_by_correlation(cid: str) -> list[dict[str, Any]]:
        """List the audit's Kubernetes Events by label.

        The writer identity is CREATE-only on events (the RBAC contract —
        the tier cannot read back its own events), so this read goes
        through the cluster-admin caller (kubectl), exactly as SC-006's
        operator would do.
        """
        out = kubectl(
            "-n", NS, "get", "events", "-l", f"{CORR_LABEL}={cid}", "-o", "json"
        )
        return json.loads(out)["items"]


@pytest.fixture(scope="module")
def cluster() -> Cluster:
    """T131 — reconciliation setup: cluster, namespace, writer identity."""
    kubectl("get", "ns", NS)  # the intent namespace must exist
    base = json.loads(kubectl("config", "view", "-o", "json"))["clusters"][0]["cluster"]["server"]
    token = kubectl("-n", NS_AGENTS, "create", "token", "intent-deployer", "--duration=1h")
    assert re.fullmatch(r"[A-Za-z0-9._=-]+", token), "token mint failed"
    cl = Cluster(base, token)
    # Preflight: the writer identity can list the resource it will create.
    assert cl.get(f"/apis/network.kubenet.dev/v1alpha1/namespaces/{NS}/networks").status_code == 200
    return cl


def _set_audit_identity(monkeypatch: pytest.MonkeyPatch, cluster: Cluster) -> None:
    """Point audit.py's k8s Event emission at this cluster/identity."""
    monkeypatch.setenv("AGENTIC_NETOPS_API_ENDPOINT", cluster.base)
    monkeypatch.setenv("AGENTIC_NETOPS_BEARER_TOKEN", cluster.token)
    monkeypatch.setenv("AGENTIC_NETOPS_VERIFY_TLS", "0")


# ---------------------------------------------------------------------------
# A deployer transport that SUBMITS real Network objects (the contract
# path the production deployer worker will own; the stub here keeps the
# submission to a single labeled Network per service).
# ---------------------------------------------------------------------------
class SubmittingDeployerTransport(StubTransport):
    def __init__(self, cluster: Cluster, correlation_id: str) -> None:
        super().__init__()
        self.cluster = cluster
        self.correlation_id = correlation_id
        self.created: list[str] = []

    async def call_deployer(self, text: str):
        self.calls.append(("deployer", text))
        m = re.search(r">>>\n(.*?)\n<<<END_DATA", text, re.DOTALL)
        body = m.group(1) if m else text
        jm = re.search(r"\{.*\}", body, re.DOTALL)
        payload = json.loads(jm.group(0))
        # Production traffic is the deployment envelope (deployment
        # transaction contract); a bare intent is the compatibility form.
        intent = payload.get("intent", payload) if isinstance(payload, dict) else payload
        ref = {
            "apiVersion": "network.kubenet.dev/v1alpha1",
            "kind": "Network",
            "namespace": NS,
            "name": intent["serviceId"],
        }
        manifest = {
            "apiVersion": "network.kubenet.dev/v1alpha1",
            "kind": "Network",
            "metadata": {
                "name": ref["name"],
                "namespace": NS,
                "labels": {CORR_LABEL: self.correlation_id, "agentic-netops.io/tier": "intent"},
            },
            "spec": {"source": "intent-tier", "serviceId": ref["name"]},
        }
        resp = self.cluster.post(f"/apis/network.kubenet.dev/v1alpha1/namespaces/{NS}/networks", manifest)
        assert resp.status_code // 100 == 2, f"Network create failed: {resp.status_code} {resp.text[:300]}"
        self.created.append(ref["name"])
        return {
            "parts": [
                {"data": {"submitted": [ref]}},
                {"text": "Submission report."},
            ]
        }


async def _run_flow(graph: ProvisioningGraph, cid: str, first_text: str, turns: list[str]) -> dict:
    config = {"configurable": {"thread_id": f"e2e-{cid[:12]}"}}
    seed = {
        "messages": [HumanMessage(content=first_text)],
        "correlation_id": cid,
        "principal": "e2e-operator",
        "workflow_status": NetworkProvisioningStatus.RECEIVED_REQUEST.value,
        "deadline": default_deadline(),
    }
    state = await graph.ainvoke(seed, config=config)
    for turn in turns:
        state = await graph.ainvoke({"messages": [HumanMessage(content=turn)]}, config=config)
    return state


async def _build_graph(transport) -> tuple[ProvisioningGraph, str]:
    cid = secrets.token_hex(16)
    llm = StubClassifierLLM()
    graph = ProvisioningGraph(
        llm_factory=lambda streaming=None: RunnableLambda(llm.ainvoke),
        transport=transport,
    )
    return graph, cid


def _cleanup(cluster: Cluster, cid: str, names: list[str]) -> None:
    for name in names:
        cluster.delete(f"/apis/network.kubenet.dev/v1alpha1/namespaces/{NS}/networks/{name}")
    for item in cluster.networks_by_correlation(cid):
        cluster.delete(f"/apis/network.kubenet.dev/v1alpha1/namespaces/{NS}/networks/{item['metadata']['name']}")
    for item in Cluster.k8s_events_by_correlation(cid):
        kubectl("-n", NS, "delete", "event", item["metadata"]["name"])


# ---------------------------------------------------------------------------
# T132 — audit/resource count equality (the full flow submits).
# ---------------------------------------------------------------------------
async def test_audit_resource_count_equality(cluster: Cluster, monkeypatch: pytest.MonkeyPatch) -> None:
    _set_audit_identity(monkeypatch, cluster)
    reset_audit_sink()
    transport = SubmittingDeployerTransport(cluster, "")
    graph, cid = await _build_graph(transport)
    transport.correlation_id = cid
    created: list[str] = []
    try:
        state = await _run_flow(graph, cid, REQUEST, ["confirm", "confirm"])
        assert state.get("workflow_status") == NetworkProvisioningStatus.PROVISIONING.value

        events = get_audit_sink().by_correlation(cid)
        confirms = [e for e in events if e.event_type == "confirm"]
        submits = [e for e in events if e.event_type == "submit"]
        assert len(confirms) == 2, f"expected 2 confirm audit events, got {len(confirms)}"
        assert len(submits) == 1, f"expected exactly 1 submit audit event, got {len(submits)}"
        # T105: every event carries principal, thread id, correlation id.
        for e in events:
            assert e.principal and e.thread_id and e.correlation_id == cid

        # T132: count equality — resources in the cluster under the
        # correlation-id label vs the submit audit event's resources.
        cluster_created = cluster.networks_by_correlation(cid)
        audit_names = {r.name for s in submits for r in s.resources}
        cluster_names = {i["metadata"]["name"] for i in cluster_created}
        assert cluster_names == audit_names, (
            f"cluster={cluster_names} vs audit={audit_names} — SC-006 count equality broken"
        )
        assert len(cluster_created) == sum(len(s.resources) for s in submits)
        created.extend(cluster_names)

        # T104 end-to-end: the Confirm and Submit Kubernetes Events exist.
        k8s_events = Cluster.k8s_events_by_correlation(cid)
        reasons = {i["reason"] for i in k8s_events}
        assert {"Confirm", "Submit"} <= reasons, f"k8s Event reasons present: {reasons}"
    finally:
        await graph.close()
        _cleanup(cluster, cid, created)


# ---------------------------------------------------------------------------
# T133 — missing-confirmation failure: nothing is submitted without the
# second confirmation.
# ---------------------------------------------------------------------------
async def test_missing_confirmation_submits_nothing(cluster: Cluster, monkeypatch: pytest.MonkeyPatch) -> None:
    _set_audit_identity(monkeypatch, cluster)
    reset_audit_sink()
    transport = SubmittingDeployerTransport(cluster, "")
    graph, cid = await _build_graph(transport)
    transport.correlation_id = cid
    try:
        # Request + first confirmation only: the thread waits for confirm_2.
        state = await _run_flow(graph, cid, REQUEST, ["confirm"])
        assert state.get("workflow_status") == NetworkProvisioningStatus.ALLOCATED.value
        assert state.get("awaiting_confirmation") is True

        # T133: zero resources under this correlation id...
        assert cluster.networks_by_correlation(cid) == [], (
            "resources were submitted without the second confirmation"
        )
        assert transport.created == []
        assert [c[0] for c in transport.calls] == ["mapper", "allocator"]  # deployer never called

        # ...and no submit audit event for it.
        events = get_audit_sink().by_correlation(cid)
        assert [e.event_type for e in events] == ["confirm"], f"audit types: {[e.event_type for e in events]}"
        # The k8s side agrees: no Submit event exists for this thread.
        reasons = {i["reason"] for i in Cluster.k8s_events_by_correlation(cid)}
        assert "Submit" not in reasons
    finally:
        await graph.close()
        _cleanup(cluster, cid, [])
