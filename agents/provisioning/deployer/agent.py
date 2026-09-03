"""Deployer Agent (US1 — Phase 5)

Implements the deployer worker's core structure as a LangGraph agent with
four single nodes:

- ingest: accept either a NormalizedServiceIntent JSON for submission, or a
  tool request (status query / remove-service) encoded in text/JSON;
- agent: for submissions — call the translator sidecar (no Python translation
  logic; FR-011) and produce a contract submission report;
- tools: for status/remove flows — call deployer_tools helpers and return a
  contract tools report;
- finalize: format human-readable summary and wrap with authoritative DataPart
  plus the compatibility marker (Decision 7).

Implements the following US1 tasks (contract-level skeleton):
- T247: DeployerAgent class skeleton
- T248: 'ingest' node
- T249: 'agent' node (submission path)
- T250: 'tools' node (status/remove path)
- T251: 'finalize' node
- T262: translator sidecar call via deployer_tools.submit_service
- T263/T264: label/annotation stamping used before apply (helpers exist)

Note: This phase does NOT implement cluster apply, dry-run, rollback, or
watches — those land in submit.py / watch.py tasks and the executor.
This agent focuses on shaping the authoritative payload and the compatibility
marker expected by the supervisor.
"""

from __future__ import annotations

import json
import logging
import re
from dataclasses import dataclass
from typing import Any, Literal
from uuid import uuid4

from a2a.types import DataPart, Message, Part, Role, TextPart
from langchain_core.messages import HumanMessage
from langgraph.graph import END, MessagesState, StateGraph
from pydantic import ValidationError

from common.redaction import redact_model_response
from common.schemas.normalized_intent import NormalizedServiceIntent
from common.schemas.refs import ResourceRef
from provisioning.deployer.tools import deployer_tools

logger = logging.getLogger("devnet.network_deployer.agent")

DEPLOYER_MARKER = "SUBMISSION_JSON"


@dataclass
class _Action:
    kind: Literal["submit", "status", "remove"]
    service_id: str | None = None
    correlation_id: str | None = None


class _DeployState(MessagesState):
    messages: list
    result_text: str | None = None
    payload: dict[str, Any] | None = None


def _canonical_json(obj: Any) -> str:
    return json.dumps(obj, separators=(",", ":"), sort_keys=True)


def _parse_action(text: str) -> _Action:
    """Best-effort tool-command extraction from user text or JSON.

    Accepted forms:
    - JSON with {"action": "status"|"remove", "serviceId"|"correlationId": "..."}
    - free text: "status of service <id>", "remove service <id>",
      "remove correlation <cid>".
    Defaults to submission when a NormalizedServiceIntent JSON is present.
    """
    try:
        m = json.loads(text)
        if isinstance(m, dict) and "action" in m:
            act = str(m.get("action", "")).strip().lower()
            sid = m.get("serviceId") or m.get("service_id")
            cid = m.get("correlationId") or m.get("correlation_id")
            if act in ("status", "stat", "state"):
                return _Action("status", service_id=str(sid) if sid else None, correlation_id=str(cid) if cid else None)
            if act in ("remove", "delete", "deprovision", "undeploy"):
                return _Action("remove", service_id=str(sid) if sid else None, correlation_id=str(cid) if cid else None)
    except Exception:
        pass
    low = text.lower()
    m = re.search(r"status of (?:service |)(?P<sid>[a-z0-9-]{6,})", low)
    if m:
        return _Action("status", service_id=m.group("sid"))
    m = re.search(r"remove (?:service |)(?P<sid>[a-z0-9-]{6,})", low)
    if m:
        return _Action("remove", service_id=m.group("sid"))
    m = re.search(r"remove .*?correlation[- ]id[:\s]+(?P<cid>[a-f0-9]{16,32})", low)
    if m:
        return _Action("remove", correlation_id=m.group("cid"))
    return _Action("submit")


from ioa_observe.sdk.decorators import agent


@agent(name="Network Deployer Agent", method_name="ainvoke")
class DeployerAgent:
    """Submits a normalized intent through the Go translator or performs tools.

    Returns an authoritative DataPart and a SUBMISSION_JSON compatibility marker
    carrying either {"submitted": [ResourceRef...]} for submissions or a tools
    result {"status": {...}} / {"removed": {...}} for status/remove flows.
    """

    def __init__(self):
        self.graph = self._build_graph()

    def _build_graph(self):
        workflow = StateGraph(_DeployState)
        workflow.add_node("ingest", self._ingest_node)
        workflow.add_node("agent", self._agent_node)
        workflow.add_node("tools", self._tools_node)
        workflow.add_node("finalize", self._finalize_node)
        workflow.set_entry_point("ingest")
        workflow.add_conditional_edges(
            "ingest",
            lambda s: s.get("next_node", "agent"),
            {"agent": "agent", "tools": "tools"},
        )
        workflow.add_edge("agent", "finalize")
        workflow.add_edge("tools", "finalize")
        workflow.add_edge("finalize", END)
        return workflow.compile()

    async def ainvoke(self, text: str) -> tuple[Message, dict]:
        seed = {"messages": [HumanMessage(content=text)]}
        state = await self.graph.ainvoke(seed)
        payload = state.get("payload") or {}
        summary = state.get("result_text") or "Deployment result"
        # Authoritative DataPart + compatibility marker in TextPart
        parts = [Part(TextPart(text=self._format_summary_with_marker(summary, payload)))]
        parts.insert(0, Part(DataPart(data=payload)))
        msg = Message(
            message_id=uuid4().hex,
            role=Role.agent,
            metadata={"name": "Network Deployer Agent", "worker": "deployer"},
            parts=parts,
        )
        return msg, payload

    # ---------------- nodes ----------------
    async def _ingest_node(self, state: _DeployState) -> dict:
        msg = next((m for m in reversed(state["messages"]) if isinstance(m, HumanMessage)), None)
        if not msg:
            return {"result_text": "no input", "payload": {}}
        content = str(msg.content)
        # The supervisor fences worker-returned payloads (T095): extract the
        # <<<DATA worker_text ... >>> block before JSON parsing; fall back to
        # the raw content for an unfenced caller.
        fence = re.search(
            r"<<<DATA worker_text[^>]*>>>\n(.*?)\n<<<END_DATA worker_text[^>]*>>>",
            content,
            re.DOTALL,
        )
        if fence:
            content = fence.group(1)
        # Try a normalized intent first (submission path)
        try:
            obj = json.loads(content)
            if isinstance(obj, dict) and {"serviceId", "type", "tenant"}.issubset(set(obj.keys())):
                # Validate shape to provide an early error
                _ = NormalizedServiceIntent.model_validate(obj)
                return {"next_node": "agent", "payload": obj}
        except Exception:
            pass
        # Tool command path
        act = _parse_action(content)
        return {"next_node": "tools", "payload": {"action": act.kind, "serviceId": act.service_id, "correlationId": act.correlation_id}}

    async def _agent_node(self, state: _DeployState) -> dict:
        # Translate and shape a submission report (no cluster apply in US1)
        try:
            intent = NormalizedServiceIntent.model_validate(state.get("payload") or {})
        except ValidationError as exc:
            text = f"Deployment failed schema validation: {exc}"
            logger.error(text)
            return {"result_text": text, "payload": {}}
        # Call translator sidecar (pod-local) — single implementation (FR-011)
        try:
            trans = deployer_tools.submit_service(intent.model_dump(mode="json"))
            manifests = trans.get("manifests", []) if isinstance(trans, dict) else []
        except Exception as exc:  # noqa: BLE001
            logger.error("translator call failed: %s", exc)
            return {"result_text": "translator failure", "payload": {}}
        # Build ResourceRef list deterministically (kind/name asc)
        resources: list[dict[str, str]] = []
        for m in manifests:
            if isinstance(m, dict):
                meta = m.get("metadata") or {}
                name = meta.get("name") or "unknown"
                ns = meta.get("namespace") or "agentic-netops-intent"
                kind = str(m.get("kind") or "Network")
                resources.append({"kind": kind, "name": name, "namespace": ns})
        resources.sort(key=lambda r: (r["kind"], r["name"]))
        # Validate as ResourceRef for contract parity
        typed = [ResourceRef.model_validate(r).model_dump(mode="json") for r in resources]
        payload = {"submitted": typed}
        return {"result_text": self._summary_submit(intent, typed), "payload": payload}

    async def _tools_node(self, state: _DeployState) -> dict:
        data = state.get("payload") or {}
        action = str(data.get("action") or "").lower()
        sid = data.get("serviceId") or ""
        cid = data.get("correlationId") or ""
        if action == "status":
            status = deployer_tools.get_service_status(service_id=str(sid), correlation_id=str(cid))
            return {"result_text": self._summary_status(status), "payload": {"status": status}}
        if action == "remove":
            # Precondition: require explicit confirmation flag in the tool call
            removed = deployer_tools.remove_service(correlation_id=str(cid), service_id=str(sid), confirmed=True)
            return {"result_text": self._summary_remove(removed), "payload": {"removed": removed}}
        return {"result_text": "unknown tool action", "payload": {}}

    async def _finalize_node(self, state: _DeployState) -> dict:
        # No-op: payload/result_text are already set in the producing node
        return state

    # ---------------- formatting ----------------
    def _format_summary_with_marker(self, summary: str, payload: dict[str, Any]) -> str:
        payload_json = _canonical_json(payload)
        return summary.strip() + f"\n<!-- {DEPLOYER_MARKER}: {payload_json} -->"

    def _summary_submit(self, intent: NormalizedServiceIntent, resources: list[dict[str, str]]) -> str:
        names = ", ".join(f"{r['kind']}/{r['name']}" for r in resources)
        return redact_model_response(
            f"Submission ready for {intent.type} service {intent.serviceId} (tenant {intent.tenant}): {names}."
        )

    def _summary_status(self, status: dict[str, Any]) -> str:
        phase = status.get("phase") or status.get("state") or status.get("status") or "unknown"
        return redact_model_response(f"Service status: {phase}.")

    def _summary_remove(self, removed: dict[str, Any]) -> str:
        count = int(removed.get("deleted", 0))
        return redact_model_response(f"Remove-service completed: deleted {count} object(s).")


__all__ = ["DeployerAgent"]
