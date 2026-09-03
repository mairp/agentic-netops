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
    ProvisioningGraph,
    default_deadline,
)

# -------------------- Logging --------------------
setup_logging()
logger = logging.getLogger("devnet.provision.supervisor.main")

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
    thread_id: str | None = "default_session"
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
            last = {}
            async for update in graph.astream(seed, config=config):
                for node_name, node_state in update.items():
                    last = {**last, **node_state}
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
                        if node_state.get("pending_action") != "clarify":
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
                    elif node_name == "deployer" and status == NetworkProvisioningStatus.PROVISIONING.value:
                        yield chunk({"type": "stage", "stage": "deployer", "status": status})
                        # T273 — emit progress chunks from convergence watch (stubbed)
                        try:
                            from provisioning.deployer.watch import watch_ready
                            def on_progress(evt: dict):
                                try:
                                    evt = dict(evt or {})
                                except Exception:
                                    return
                                evt.setdefault("type", "progress")
                                evt.setdefault("stage", "deployer")
                                evt.setdefault("status", status)
                                yield_chunk = chunk(evt)
                                # local function inside generator: use closure to yield
                                nonlocal_yield.append(yield_chunk)
                            nonlocal_yield = []
                            ok = watch_ready(on_progress=on_progress)
                            # Drain any progress events captured
                            for entry in nonlocal_yield:
                                yield entry
                        except Exception:
                            pass
                    # T258/T259 — tools path: status-query and remove-service chunks
                    elif node_name == "supervisor" and node_state.get("pending_action") == "confirm_remove":
                        yield chunk(
                            {
                                "type": "confirmation_request",
                                "stage": "deployer",
                                "prompt": "Remove this service? Reply 'confirm' to proceed or 'decline' to cancel.",
                                "refusable": True,
                            }
                        )
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
                yield chunk({"type": "final", "status": status})
            else:
                # MAPPED/ALLOCATED awaiting a confirmation, or a completed
                # informational answer: the thread is resumable.
                yield chunk({"type": "final", "status": status})
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
