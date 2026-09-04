"""Deployer tools (US1 — Phase 5).

Implements:
- T252: query_fabric_inventory (stub: returns static inventory shape)
- T253: get_service_status (live: resolves Ready conditions by correlation id)
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

logger = logging.getLogger("agentic_netops.network_deployer.tools")

TRANSLATOR_ENDPOINT = "http://127.0.0.1:8090"


from ioa_observe.sdk.decorators import tool


@tool(name="deployer.query_fabric_inventory")
def query_fabric_inventory() -> dict[str, Any]:
    """T252 — return a deterministic inventory shape for tests.

    In Phase 5, this is a stub: the subject's inventory query is implemented
    in later phases against ClickHouse or the intent namespace.
    """
    return {"fabric": "lab", "nodes": [], "links": []}


# Named phases of a resolved service status (the outcome vocabulary the
# supervisor maps onto NetworkProvisioningStatus).
PHASE_DEPLOYED = "Deployed"
PHASE_FAILED = "Failed"
PHASE_CONVERGING = "Converging"
PHASE_NOT_FOUND = "NotFound"
PHASE_UNKNOWN = "Unknown"


def _condition_summary(obj: dict[str, Any]) -> dict[str, Any]:
    """Reduce one intent object to its Ready condition, verbatim.

    The controller owns the Ready condition (controllers/sonicprovider/
    network_controller.go): ``ApplySucceeded``/``ApplyFailed`` with the real
    operation output. This never paraphrases it — a status answer that
    invents a message is worse than no answer.
    """

    meta = obj.get("metadata") if isinstance(obj.get("metadata"), dict) else {}
    status = obj.get("status") if isinstance(obj.get("status"), dict) else {}
    conditions = status.get("conditions") if isinstance(status.get("conditions"), list) else []
    ready: bool | None = None
    reason = ""
    message = ""
    at = ""
    for condition in conditions:
        if not isinstance(condition, dict) or str(condition.get("type") or "") != "Ready":
            continue
        raw = str(condition.get("status") or "").lower()
        ready = True if raw == "true" else False if raw == "false" else None
        reason = str(condition.get("reason") or "")
        message = str(condition.get("message") or "")
        at = str(condition.get("lastTransitionTime") or "")
        break
    return {
        "kind": str(obj.get("kind") or ""),
        "name": str(meta.get("name") or ""),
        "namespace": str(meta.get("namespace") or ""),
        "ready": ready,
        "reason": reason,
        "message": message,
        "lastTransitionTime": at,
    }


def _phase_from(resources: list[dict[str, Any]]) -> str:
    if not resources:
        return PHASE_NOT_FOUND
    if any(r.get("ready") is False for r in resources):
        return PHASE_FAILED
    if all(r.get("ready") is True for r in resources):
        return PHASE_DEPLOYED
    return PHASE_CONVERGING


@tool(name="deployer.get_service_status")
def get_service_status(*, service_id: str | None = None, correlation_id: str | None = None) -> dict[str, Any]:
    """Resolve the live outcome of a submitted transaction from the cluster.

    Answers the question the conversation could not answer before: the
    submitted objects are looked up by their correlation-id label and each
    one's ``Ready`` condition — the controller's own verdict — is reported
    as-is. ``phase`` is the transaction-level reduction of those conditions
    (Deployed / Failed / Converging / NotFound).

    A cluster read that cannot be performed returns ``Unknown`` **with the
    error named**; it never guesses a phase, and "Unknown" is never a
    success.
    """

    from provisioning.deployer.submit import build_default_client

    result: dict[str, Any] = {
        "serviceId": service_id or "",
        "correlationId": correlation_id or "",
        "phase": PHASE_UNKNOWN,
        "resources": [],
    }
    if not correlation_id:
        # Without the correlation label there is nothing to select on: the
        # tier labels every submitted object with it and nothing else.
        result["error"] = "no correlation id on this thread; cannot resolve the submitted resources"
        return result

    client = None
    try:
        client = build_default_client()
        objects = client.list_by_correlation(correlation_id)
    except Exception as exc:  # noqa: BLE001 - an unreadable cluster is Unknown, never Deployed
        logger.warning("service status read failed for correlation %s: %s", correlation_id[:8], exc)
        result["error"] = str(exc)[:400]
        return result
    finally:
        if client is not None:
            try:
                client.close()
            except Exception:  # noqa: BLE001
                pass

    resources = [_condition_summary(obj) for obj in objects]
    result["resources"] = resources
    result["phase"] = _phase_from(resources)
    return result


@tool(name="deployer.remove_service")
def remove_service(*, correlation_id: str | None, service_id: str | None = None, confirmed: bool = False) -> dict[str, Any]:
    """T254/T255 — remove by correlation id.

    - Precondition (T254): require confirmed=True (the supervisor asks for
      explicit confirmation and only then calls this helper with confirmed).
    - Behavior (T255): delete-by-correlation-id. Phase 5 stub: return the
      number of deletions attempted and echo the selector.
    """
    if not confirmed:
        raise ValueError("remove_service requires explicit confirmation")
    selector = f"agentic-netops.io/correlation-id={correlation_id or ''}"
    # Phase 5 stub: pretend we deleted 0 objects deterministically.
    return {"selector": selector, "deleted": 0}


@tool(name="deployer.submit_service")
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
