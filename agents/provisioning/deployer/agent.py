"""Deployer Agent — the intent-tier deployment transaction (US1).

The submission path implements the deployment contract
(docs/INTENT_TIER_DEPLOYMENT_TRANSACTION.md) end to end:

- ingest: accept the supervisor's deployment envelope (or a bare normalized
  intent for compatibility), or a tool request (status / remove-service);
- agent: run the full transaction — validate against
  ``NormalizedServiceIntent``, translate once through the pod-local Go
  translator (FR-011), validate/stamp/dry-run/apply/rollback through
  ``submit.run_deployment_transaction``, then watch convergence;
- tools: status/remove flows through ``deployer_tools``;
- finalize: wrap the authoritative DataPart plus the SUBMISSION_JSON
  compatibility marker (Decision 7).

Reporting is truthful by construction (contract step 8): the authoritative
``{"submitted": [ResourceRef...]}`` payload exists only after every apply
has succeeded. Translation output alone is never a submission report, and a
failed phase produces a ``{"failed": {...}}`` report naming the phase,
resource, rolled-back set, and any survivors.
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

from common.redaction import redact_model_response
from provisioning.deployer.submit import (
    DeploymentContext,
    DeploymentEnvelope,
    DeploymentTransactionError,
    parse_deployment_envelope,
    run_deployment_transaction,
)
from provisioning.deployer.tools import deployer_tools

logger = logging.getLogger("agentic_netops.network_deployer.agent")

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
    Defaults to submission when a deployment envelope is present.
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


from ioa_observe.sdk.decorators import agent  # noqa: E402 - decorator must sit directly above the class


@agent(name="Network Deployer Agent", method_name="ainvoke")
class DeployerAgent:
    """Runs the deployment transaction or the tools flows.

    Returns an authoritative DataPart and a SUBMISSION_JSON compatibility
    marker carrying either {"submitted": [ResourceRef...]} (plus per-resource
    convergence outcomes) for submissions or {"failed": {...}} naming the
    failed transaction phase, or a tools result {"status": {...}} /
    {"removed": {...}} for status/remove flows.
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
        # Step 1 — parse the deployment envelope (or bare intent). The
        # supervisor fences worker-bound payloads (T095); the parser unwraps
        # the fence itself. A non-submission falls through to the tools path.
        try:
            envelope = parse_deployment_envelope(content)
        except DeploymentTransactionError as exc:
            # A malformed submission is a named request-validation failure,
            # never a silent reroute into tools.
            logger.error("deployment envelope rejected: %s", exc)
            return {
                "next_node": "agent",
                "payload": {
                    "intent": None,
                    "context": None,
                    "preparsed_error": exc.report(),
                },
            }
        if envelope is not None:
            return {
                "next_node": "agent",
                "payload": {
                    "intent": envelope.intent,
                    "context": {
                        "correlationId": envelope.context.correlation_id,
                        "threadId": envelope.context.thread_id,
                        "principal": envelope.context.principal,
                    },
                },
            }
        # Tool command path
        act = _parse_action(content)
        return {
            "next_node": "tools",
            "payload": {"action": act.kind, "serviceId": act.service_id, "correlationId": act.correlation_id},
        }

    async def _agent_node(self, state: _DeployState) -> dict:
        data = state.get("payload") or {}
        preparsed_error = data.get("preparsed_error")
        if preparsed_error:
            return {
                "result_text": redact_model_response(
                    f"Deployment failed request validation: {preparsed_error.get('message', '')}"
                ),
                "payload": {"failed": preparsed_error},
            }
        raw_context = data.get("context") or {}
        if not raw_context:
            return {"result_text": "no deployment envelope", "payload": {"failed": {
                "phase": "request-validation", "resource": None,
                "message": "request-validation failed: no deployment envelope",
                "rolledBack": [], "survivors": [],
            }}}
        envelope = DeploymentEnvelope(
            intent=data.get("intent") or {},
            context=DeploymentContext(
                correlation_id=str(raw_context.get("correlationId") or ""),
                thread_id=str(raw_context.get("threadId") or ""),
                principal=str(raw_context.get("principal") or ""),
            ),
        )
        # Steps 1-7 — validate, translate once, stamp, dry-run, apply,
        # roll back on failure, watch convergence. Step 8: the payload below
        # is the authoritative submission report and exists only because
        # every apply succeeded.
        try:
            payload = run_deployment_transaction(envelope)
        except DeploymentTransactionError as exc:
            logger.error("deployment transaction failed: %s", exc)
            summary = f"Deployment failed during {exc.phase}"
            if exc.resource:
                summary += f" ({exc.resource})"
            summary += f": {exc}"
            if exc.rolled_back:
                names = ", ".join(f"{r.kind}/{r.name}" for r in exc.rolled_back)
                summary += f". Rolled back: {names}."
            if exc.survivors:
                names = ", ".join(f"{r.kind}/{r.name}" for r in exc.survivors)
                summary += f" Survivors that could not be deleted: {names}."
            return {
                "result_text": redact_model_response(summary),
                "payload": {"failed": exc.report()},
            }
        except Exception as exc:  # noqa: BLE001 - an unexpected failure is still not a submission
            logger.exception("deployment transaction crashed: %s", exc)
            summary = f"Deployment failed during transaction: {redact_model_response(str(exc))}"
            return {
                "result_text": summary,
                "payload": {"failed": {
                    "phase": "transaction",
                    "resource": None,
                    "message": str(exc),
                    "rolledBack": [],
                    "survivors": [],
                }},
            }
        return {"result_text": self._summary_submit(envelope, payload), "payload": payload}

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

    def _summary_submit(self, envelope: DeploymentEnvelope, payload: dict[str, Any]) -> str:
        submitted = payload.get("submitted") or []
        names = ", ".join(f"{r.get('kind')}/{r.get('name')}" for r in submitted)
        convergence = payload.get("convergence") or []
        ready = sum(1 for c in convergence if c.get("outcome") == "ready")
        failed = [c for c in convergence if c.get("outcome") == "failed"]
        timed_out = [c for c in convergence if c.get("outcome") == "timeout"]
        text = (
            f"Submitted {len(submitted)} resource(s) for service "
            f"{envelope.intent.get('serviceId')} (correlation {envelope.context.correlation_id[:8]}): {names}."
        )
        if convergence:
            text += f" Convergence: {ready} ready"
            if timed_out:
                text += f", {len(timed_out)} timed out"
            if failed:
                text += f", {len(failed)} failed"
            text += "."
        return redact_model_response(text)

    def _summary_status(self, status: dict[str, Any]) -> str:
        phase = status.get("phase") or status.get("state") or status.get("status") or "unknown"
        return redact_model_response(f"Service status: {phase}.")

    def _summary_remove(self, removed: dict[str, Any]) -> str:
        count = int(removed.get("deleted", 0))
        return redact_model_response(f"Remove-service completed: deleted {count} object(s).")


__all__ = ["DeployerAgent"]
