"""Provisioning supervisor — the five-route HTTP surface.

The five-route surface of contracts/supervisor-http.md, verbatim in shape:
``POST /agent/prompt/stream`` (NDJSON), ``GET /health``,
``GET /v1/health`` (per-worker readiness, names the down worker — FR-026),
``GET /transport/config``, ``GET /suggested-prompts``. Port 9090 (the
subject's, kept).

Phase 3: ``POST /agent/prompt/stream`` runs the LangGraph supervisor graph
(``graph/graph.py``) — the three-way classifier (T089), the direct-device
refusals (T090/T091/T092), the nonce-fenced worker calls with schema
validation (T094-T102), and the deployer's submission preconditions
(T124/T125) — and streams the contract's NDJSON chunks (``status``,
``stage``, ``confirmation_request``, ``progress``, ``final``, ``error``;
every chunk carries ``correlation_id`` and a status drawn only from
``NetworkProvisioningStatus``). ``/v1/health`` probes each worker's own
``/v1/health`` over plain HTTP (the A2A-over-SLIM session probe is a
later-phase refinement; the readiness contract — 200 iff every worker
answers, 503 naming the down worker — is met either way).
"""

from __future__ import annotations

import json
import logging
import uuid
from pathlib import Path

import httpx
import uvicorn
from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse, StreamingResponse
from langchain_core.messages import HumanMessage
from pydantic import BaseModel

from common.provisioning_states import NetworkProvisioningStatus
from common.redaction import redact
from config.config import (
    ALLOCATOR_ENDPOINT,
    DEFAULT_MESSAGE_TRANSPORT,
    DEPLOYER_ENDPOINT,
    MAPPER_ENDPOINT,
    TRANSPORT_SERVER_ENDPOINT,
)
from config.logging_config import setup_logging
from supervisors.provisioning.graph.graph import (
    CLARIFICATION_HINT,
    ProvisioningGraph,
    default_deadline,
)

# -------------------- Logging --------------------
setup_logging()
logger = logging.getLogger("agentic_netops.provision.supervisor.main")

# -------------------- Telemetry --------------------
from config.telemetry import init_telemetry

init_telemetry(app_name="intent-supervisor")

# -------------------- FastAPI --------------------
app = FastAPI()
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# Worker Service DNS names (config/config.py) — the supervisor holds no
# hardcoded worker list beyond these config values (FR-023).
WORKER_ENDPOINTS = {
    "mapper": MAPPER_ENDPOINT,
    "allocator": ALLOCATOR_ENDPOINT,
    "deployer": DEPLOYER_ENDPOINT,
}


# -------------------- Models --------------------
class PromptRequest(BaseModel):
    prompt: str
    # No shared default: a constant here would collapse every
    # thread_id-less client onto one checkpointer thread, and once that
    # thread hits its iteration bound it is permanently refused. `None`
    # means "caller did not supply one" and yields a fresh uuid below.
    thread_id: str | None = None
    principal: str | None = None


# -------------------- Graph (Phase 3) --------------------
_graph: ProvisioningGraph | None = None


def get_graph() -> ProvisioningGraph:
    """The process-wide supervisor graph (lazy; the SQLite checkpointer is
    bound to SUPERVISOR_CHECKPOINT_DB — the supervisor-checkpoint PVC in
    cluster, :memory: for out-of-cluster runs)."""
    global _graph
    if _graph is None:
        _graph = ProvisioningGraph()
    return _graph


# The statuses the deployer node can end a transaction on. All three carry a
# convergence report, so all three render as a deployer stage chunk: the
# operator learns the outcome (or the honest absence of one) in-band.
_DEPLOYER_OUTCOME_STATUSES = frozenset(
    {
        NetworkProvisioningStatus.PROVISIONING.value,
        NetworkProvisioningStatus.COMPLETED.value,
        NetworkProvisioningStatus.FAILED.value,
    }
)


# -------------------- HTTP Endpoints --------------------
from ioa_observe.sdk.tracing.tracing import session_start


@app.post("/agent/prompt/stream")
async def handle_stream_prompt(request: PromptRequest):
    """NDJSON stream (application/x-ndjson). Runs the supervisor graph and
    streams the contract's chunks (contracts/supervisor-http.md): every
    chunk carries ``correlation_id`` and a ``status`` drawn only from
    NetworkProvisioningStatus; a failure names the responsible stage
    (FR-034). Never hangs: the graph is bounded (FR-004)."""
    correlation_id = uuid.uuid4().hex  # 32-hex, the W3C trace id of the root span
    thread_id = request.thread_id or str(uuid.uuid4())
    principal = request.principal or "operator"

    def chunk(obj: dict) -> str:
        obj.setdefault("correlation_id", correlation_id)
        return json.dumps(obj) + "\n"

    async def stream_generator():
        # Start a telemetry session to bind a session.id to the trace and capture context
        with session_start():
            pass  # context-only; span lifecycle is managed by decorators

        yield chunk(
            {
                "type": "status",
                "status": NetworkProvisioningStatus.RECEIVED_REQUEST.value,
                "stage": "supervisor",
                "thread_id": thread_id,
            }
        )
        logger.info(
            "stream for thread=%s principal=%s correlation=%s", thread_id, principal, correlation_id
        )
        try:
            graph = get_graph()
            config = {"configurable": {"thread_id": thread_id}}
            seed = {
                "messages": [HumanMessage(content=request.prompt)],
                "correlation_id": correlation_id,
                "principal": principal,
                "workflow_status": NetworkProvisioningStatus.RECEIVED_REQUEST.value,
                "deadline": default_deadline(),
            }
            # ``stream_mode=updates`` yields node deltas, not the complete
            # graph state. Seed this accumulator with the request state so a
            # node that only adds a message (for example general_info) cannot
            # erase the known workflow status and produce STATUS_UNKNOWN.
            last = dict(seed)
            final_message = ""
            async for update in graph.astream(seed, config=config):
                for node_name, node_state in update.items():
                    last = {**last, **node_state}
                    for message in node_state.get("messages") or []:
                        content = getattr(message, "content", "")
                        if isinstance(content, str) and content.strip():
                            final_message = content.strip()
                    status = node_state.get("workflow_status") or last.get("workflow_status")
                    if node_name == "mapper" and status == NetworkProvisioningStatus.MAPPED.value:
                        yield chunk(
                            {
                                "type": "stage",
                                "stage": "mapper",
                                "status": status,
                                "payload": json.loads(node_state.get("mapped_parameters") or "{}"),
                            }
                        )
                        if node_state.get("pending_action") == "clarify":
                            missing = node_state.get("missing_fields") or []
                            fields = ", ".join(str(field) for field in missing) or "required service fields"
                            yield chunk(
                                {
                                    "type": "clarification_request",
                                    "stage": "mapper",
                                    "status": status,
                                    "missing_fields": list(missing),
                                    "prompt": (
                                        f"Before I can map this service I need: {fields}. Please restate the full "
                                        "request including those values."
                                        f"{CLARIFICATION_HINT}"
                                    ),
                                }
                            )
                        else:
                            # A complete interpretation asks for the first
                            # confirmation; a clarification asks for fields.
                            yield chunk(
                                {
                                    "type": "confirmation_request",
                                    "stage": "mapper",
                                    "prompt": (
                                        "Confirm this interpretation? Reply 'confirm' to proceed to allocation, "
                                        "or 'decline' to cancel."
                                    ),
                                    "refusable": True,
                                }
                            )
                    elif node_name == "allocator" and status == NetworkProvisioningStatus.ALLOCATED.value:
                        yield chunk(
                            {
                                "type": "stage",
                                "stage": "allocator",
                                "status": status,
                                "payload": json.loads(node_state.get("allocated_resources") or "{}"),
                            }
                        )
                        yield chunk(
                            {
                                "type": "confirmation_request",
                                "stage": "allocator",
                                "prompt": (
                                    "Deploy this service? Reply 'confirm' to submit it to the cluster, "
                                    "or 'decline' to cancel."
                                ),
                                "refusable": True,
                            }
                        )
                    # T258/T259 — tools path: a status-query or remove-service
                    # answer is its own stage, not a submission report.
                    elif node_name == "deployer" and node_state.get("tool_result"):
                        try:
                            tool_payload = json.loads(node_state.get("tool_result") or "{}")
                        except Exception:
                            tool_payload = {}
                        yield chunk(
                            {
                                "type": "stage",
                                "stage": "deployer-tools",
                                "tool": node_state.get("tool_action") or "",
                                "result": tool_payload,
                                "status": status,
                            }
                        )
                    elif node_name == "deployer" and status in _DEPLOYER_OUTCOME_STATUSES:
                        # The deployer node reports the transaction's outcome,
                        # not just its submission: the stage chunk carries the
                        # submitted refs and the per-resource convergence
                        # observations, and one progress chunk per resource
                        # names the controller's own verdict.
                        try:
                            convergence = json.loads(node_state.get("convergence") or "[]")
                        except Exception:  # noqa: BLE001
                            convergence = []
                        try:
                            submitted = json.loads(node_state.get("submitted_resources") or "[]")
                        except Exception:  # noqa: BLE001
                            submitted = []
                        stage_chunk: dict = {"type": "stage", "stage": "deployer", "status": status}
                        if submitted or convergence:
                            stage_chunk["payload"] = {"submitted": submitted, "convergence": convergence}
                        yield chunk(stage_chunk)
                        for observation in convergence:
                            if not isinstance(observation, dict):
                                continue
                            outcome = str(observation.get("outcome") or "")
                            resource = str(observation.get("resource") or "resource")
                            detail = str(observation.get("detail") or "").strip()
                            verdict = {
                                "ready": "converged",
                                "failed": "failed to converge",
                                "timeout": "still converging at the watch bound",
                            }.get(outcome, outcome or "observed")
                            message = f"{resource} {verdict}"
                            if detail:
                                message += f": {detail}"
                            yield chunk(
                                {
                                    "type": "progress",
                                    "stage": "deployer",
                                    "status": status,
                                    "message": redact(message),
                                    "details": observation,
                                }
                            )
                    elif node_name == "supervisor" and node_state.get("pending_action") == "confirm_remove":
                        yield chunk(
                            {
                                "type": "confirmation_request",
                                "stage": "deployer",
                                "prompt": "Remove this service? Reply 'confirm' to proceed or 'decline' to cancel.",
                                "refusable": True,
                            }
                        )
                    elif status == NetworkProvisioningStatus.FAILED.value:
                        # A refusal/rejection: the final chunk carries the
                        # operator-readable reason (FR-034).
                        break
            status = last.get("workflow_status", NetworkProvisioningStatus.STATUS_UNKNOWN.value)
            if status == NetworkProvisioningStatus.FAILED.value:
                reason = last.get("refusal_reason") or "request failed"
                responsible_stage = _responsible_stage_from_reason(reason)
                yield chunk(
                    {
                        "type": "error",
                        "stage": responsible_stage,
                        "status": status,
                        "reason": redact(reason),
                        "suggestion": redact(last.get("suggestion") or ""),
                    }
                )
            elif status == NetworkProvisioningStatus.PROVISIONING.value:
                payload = {"type": "final", "status": status}
                if final_message:
                    payload["message"] = redact(final_message)
                yield chunk(payload)
            else:
                # MAPPED/ALLOCATED awaiting a confirmation, or a completed
                # informational answer: the thread is resumable.
                payload = {"type": "final", "status": status}
                if final_message:
                    payload["message"] = redact(final_message)
                yield chunk(payload)
        except Exception as exc:  # noqa: BLE001 - the stream must end with a named failure
            logger.exception("stream failed for thread=%s", thread_id)
            yield chunk(
                {
                    "type": "error",
                    "stage": "supervisor",
                    "status": NetworkProvisioningStatus.FAILED.value,
                    "reason": redact(f"internal error: {exc}"),
                }
            )

    return StreamingResponse(stream_generator(), media_type="application/x-ndjson")


def _responsible_stage_from_reason(reason: str) -> str:
    reason = reason or ""
    if reason.startswith("mapper payload out of contract"):
        return "mapper"
    if reason.startswith("allocator payload out of contract"):
        return "allocator"
    if reason.startswith("deployer payload out of contract"):
        return "deployer"
    if ": " in reason:
        return reason.split(" ", 1)[0].rstrip(":")
    return "supervisor"


@app.get("/health")
async def health_check():
    """Trivial liveness — must not touch the transport (contract): a worker
    outage never restarts the supervisor into amnesia."""
    return {"status": "ok"}


@app.get("/v1/health")
async def connectivity_health():
    """Deep readiness: probe every worker, name the unavailable one
    (FR-026, SC-012). 200 when every worker answers, 503 otherwise with the
    per-worker map in the body (contracts/supervisor-http.md)."""
    workers: dict[str, str] = {}
    async with httpx.AsyncClient(timeout=5) as client:
        for worker, endpoint in WORKER_ENDPOINTS.items():
            try:
                resp = await client.get(f"{endpoint}/v1/health")
                workers[worker] = "ok" if resp.status_code == 200 else f"error:{resp.status_code}"
            except Exception:  # noqa: BLE001 - probe must report, not raise
                workers[worker] = "unreachable"

    payload = {
        "status": "ok" if all(v == "ok" for v in workers.values()) else "degraded",
        "transport": DEFAULT_MESSAGE_TRANSPORT,
        "endpoint": TRANSPORT_SERVER_ENDPOINT,
        "workers": workers,
    }
    if payload["status"] != "ok":
        logger.warning("readiness degraded: %s", workers)
        return JSONResponse(content=payload, status_code=503)
    return payload


@app.get("/transport/config")
async def get_config():
    """The long variable name and the 46357 data-plane port — not :7080, not
    TRANSPORT_ENDPOINT (REVERSE.md Finding 1)."""
    return {"transport": DEFAULT_MESSAGE_TRANSPORT.upper(), "endpoint": TRANSPORT_SERVER_ENDPOINT}


# -------------------- Suggested Prompts --------------------
@app.get("/suggested-prompts")
async def get_prompts():
    prompts_path = Path(__file__).resolve().parent / "suggested_prompts.json"
    try:
        raw = prompts_path.read_text(encoding="utf-8")
        data = json.loads(raw)
        if not isinstance(data, list) or not all(isinstance(p, str) for p in data):
            raise HTTPException(status_code=500, detail="suggested_prompts.json must be a JSON array of strings")
        return data
    except FileNotFoundError:
        logger.exception(f"suggested_prompts.json not found at {prompts_path}")
        raise HTTPException(status_code=404, detail="suggested_prompts.json not found") from None
    except json.JSONDecodeError:
        logger.exception("Invalid JSON in suggested_prompts.json")
        raise HTTPException(status_code=500, detail="Invalid JSON in suggested_prompts.json") from None
    except HTTPException:
        raise
    except Exception as e:  # noqa: BLE001
        logger.exception(f"Failed to load suggested prompts: {str(e)}")
        raise HTTPException(status_code=500, detail=f"Failed to load prompts: {str(e)}") from e


# -------------------- Main --------------------
if __name__ == "__main__":
    uvicorn.run("main:app", host="0.0.0.0", port=9090)
