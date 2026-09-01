"""Provisioning supervisor — Phase 2 skeleton (T078-T081).

The five-route HTTP surface of contracts/supervisor-http.md, verbatim in
shape: ``POST /agent/prompt/stream`` (NDJSON), ``GET /health``,
``GET /v1/health`` (per-worker readiness, names the down worker — FR-026),
``GET /transport/config``, ``GET /suggested-prompts``. Port 9090 (the
subject's, kept).

Phase 2 boundary: there is deliberately NO import of Phase 3 modules — the
LangGraph graph, the shared factory, and the A2A call helpers do not exist
yet. The stream emits the contract's status chunk followed by a bounded,
named failure (never a hang, FR-004 in spirit); ``/v1/health`` probes each
worker's own ``/v1/health`` over plain HTTP (Phase 3 replaces the probe
with the A2A-over-SLIM client the contract names).
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
from pydantic import BaseModel

from config.config import (
    ALLOCATOR_ENDPOINT,
    DEFAULT_MESSAGE_TRANSPORT,
    DEPLOYER_ENDPOINT,
    MAPPER_ENDPOINT,
    TRANSPORT_SERVER_ENDPOINT,
)
from config.logging_config import setup_logging

# -------------------- Logging --------------------
setup_logging()
logger = logging.getLogger("devnet.provision.supervisor.main")

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


# -------------------- HTTP Endpoints --------------------
@app.post("/agent/prompt/stream")
async def handle_stream_prompt(request: PromptRequest):
    """NDJSON stream (application/x-ndjson). Phase 2 skeleton: emits the
    contract's ``status`` chunk, then a bounded ``error`` chunk naming the
    responsible stage (supervisor) — the graph wiring lands in Phase 3.
    ``status`` values are drawn only from NetworkProvisioningStatus."""
    correlation_id = uuid.uuid4().hex  # 32-hex, the W3C trace id of the root span
    thread_id = request.thread_id

    async def stream_generator():
        yield json.dumps(
            {
                "type": "status",
                "correlation_id": correlation_id,
                "status": "RECEIVED_REQUEST",
                "stage": "supervisor",
                "thread_id": thread_id,
            }
        ) + "\n"
        logger.info(
            "skeleton stream for thread=%s principal=%s: graph wiring is Phase 3",
            thread_id,
            request.principal,
        )
        yield json.dumps(
            {
                "type": "error",
                "stage": "supervisor",
                "status": "FAILED",
                "reason": "skeleton (Phase 2): LangGraph wiring lands in Phase 3; request not processed",
                "correlation_id": correlation_id,
            }
        ) + "\n"

    return StreamingResponse(stream_generator(), media_type="application/x-ndjson")


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
