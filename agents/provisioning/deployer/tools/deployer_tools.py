"""Deployer tools (US1 — Phase 5).

Implements:
- T252: query_fabric_inventory (stub: returns static inventory shape)
- T253: get_service_status (stub: returns deterministic status shape)
- T254: remove_service confirmation precondition (confirmed flag)
- T255: remove_service delete-by-correlation-id behavior (stubbed return)
- T262: submit_service translator sidecar call to 127.0.0.1:8090

These stubs are deterministic and side-effect free in this phase; Phase 5
requires shaping and compatibility, not live cluster calls.
"""

from __future__ import annotations

import json
import logging
from typing import Any

import httpx

logger = logging.getLogger("devnet.network_deployer.tools")

TRANSLATOR_ENDPOINT = "http://127.0.0.1:8090"


def query_fabric_inventory() -> dict[str, Any]:
    """T252 — return a deterministic inventory shape for tests.

    In Phase 5, this is a stub: the subject's inventory query is implemented
    in later phases against ClickHouse or the intent namespace.
    """
    return {"fabric": "lab", "nodes": [], "links": []}


def get_service_status(*, service_id: str | None = None, correlation_id: str | None = None) -> dict[str, Any]:
    """T253 — return a deterministic status shape.

    Phase 5 stub: we do not query the cluster. The shape mirrors a minimal
    fabric controller summary.
    """
    return {"serviceId": service_id or "", "correlationId": correlation_id or "", "phase": "Unknown"}


def remove_service(*, correlation_id: str | None, service_id: str | None = None, confirmed: bool = False) -> dict[str, Any]:
    """T254/T255 — remove by correlation id.

    - Precondition (T254): require confirmed=True (the supervisor asks for
      explicit confirmation and only then calls this helper with confirmed).
    - Behavior (T255): delete-by-correlation-id. Phase 5 stub: return the
      number of deletions attempted and echo the selector.
    """
    if not confirmed:
        raise ValueError("remove_service requires explicit confirmation")
    selector = f"ainetops.io/correlation-id={correlation_id or ''}"
    # Phase 5 stub: pretend we deleted 0 objects deterministically.
    return {"selector": selector, "deleted": 0}


def submit_service(intent_json: dict[str, Any] | list[dict[str, Any]]) -> dict[str, Any]:
    """T262 — call the translator sidecar POST /v1/translate.

    Accepts one NormalizedServiceIntent object or an array of them. Returns
    the translator's response or raises on a non-2xx status.
    """
    url = f"{TRANSLATOR_ENDPOINT}/v1/translate"
    with httpx.Client(timeout=10.0) as client:
        resp = client.post(url, headers={"Content-Type": "application/json"}, content=json.dumps(intent_json))
        if resp.status_code // 100 != 2:
            # Pass through 422 causes; otherwise raise with status
            try:
                body = resp.json()
            except Exception:
                body = {"error": resp.text[:200]}
            if resp.status_code == 422:
                return body
            raise RuntimeError(f"translator error {resp.status_code}: {body}")
        return resp.json()