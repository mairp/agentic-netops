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
import re
from typing import Any

import httpx
from ioa_observe.sdk.decorators import tool

logger = logging.getLogger("agentic_netops.network_deployer.tools")

TRANSLATOR_ENDPOINT = "http://127.0.0.1:8090"




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


def _service_id_from_object(obj: dict[str, Any]) -> str:
    """Recover the service id from translator-owned Network metadata."""

    meta = obj.get("metadata") if isinstance(obj.get("metadata"), dict) else {}
    annotations = meta.get("annotations") if isinstance(meta.get("annotations"), dict) else {}
    annotated = str(annotations.get("agentic-netops.io/service-id") or "")
    if annotated:
        return annotated
    spec = obj.get("spec") if isinstance(obj.get("spec"), dict) else {}
    description = str(spec.get("description") or "")
    described = re.search(r"\bMigrated service ([a-z0-9-]{1,15})\b", description, re.I)
    if described:
        return described.group(1)
    name = str(meta.get("name") or "")
    return name.removeprefix("migr-") if name.startswith("migr-") else ""


# --- US4 type folding: same alias table as the mapper (construct-vocabulary) ---
_DEF_TYPES = {
    "vlan": "vlan",
    "macvrf": "mac-vrf",
    "l2vni": "mac-vrf",
    "ipvrf": "ip-vrf",
    "l3vni": "ip-vrf",
    "acl": "acl",
    "accesslist": "acl",
    # legacy aliases (migration sources)
    "vpls": "mac-vrf",
    "vpws": "mac-vrf",
    "eline": "mac-vrf",
    "l3vpn": "ip-vrf",
    "l2l3irb": "mac-vrf",
    "irb": "mac-vrf",
}


def _type_key(s: str) -> str:
    out = []
    for ch in str(s or "").lower():
        if ch in "-_ .+":
            continue
        out.append(ch)
    return "".join(out)


def _derive_construct_and_provenance(annotations: dict[str, Any]) -> tuple[str | None, str | None]:
    if not isinstance(annotations, dict):
        return None, None
    stored: str | None = annotations.get("agentic-netops.io/service-type")  # may be legacy or construct
    src: str | None = annotations.get("agentic-netops.io/source-service-type")
    if not stored:
        return None, src
    key = _type_key(stored)
    construct = _DEF_TYPES.get(key)
    # Provenance: prefer the explicit source-service-type when present; otherwise
    # if the stored service-type is not already a construct spelling, surface it.
    provenance: str | None = src
    if not provenance and construct and key != _type_key(construct):
        provenance = stored
    return construct, provenance


def _condition_summary(obj: dict[str, Any]) -> dict[str, Any]:
    """Reduce one intent object to its Ready and Degraded conditions, verbatim.

    The controller owns the Ready condition (controllers/sonicprovider/
    network_controller.go): ``ApplySucceeded``/``ApplyFailed`` with the real
    operation output. This never paraphrases it — a status answer that
    invents a message is worse than no answer.

    Additionally, carry an "unverified" indicator when a plan-declared check
    did not run on a node (FR-017/T049a). The controller's Ready message
    includes the failing check in the form "node <node> checks[<i>].<type>: <err>";
    this helper extracts (node, type) and records it under "unverified" so the
    operator-facing layer can name what was not observed instead of implying it
    was verified.
    """

    meta = obj.get("metadata") if isinstance(obj.get("metadata"), dict) else {}
    annotations = meta.get("annotations") if isinstance(meta.get("annotations"), dict) else {}
    status = obj.get("status") if isinstance(obj.get("status"), dict) else {}
    conditions = status.get("conditions") if isinstance(status.get("conditions"), list) else []
    found: dict[str, dict[str, Any]] = {}
    for condition in conditions:
        if not isinstance(condition, dict):
            continue
        condition_type = str(condition.get("type") or "")
        if condition_type not in ("Ready", "Degraded"):
            continue
        raw = str(condition.get("status") or "").lower()
        found[condition_type] = {
            "status": True if raw == "true" else False if raw == "false" else None,
            "reason": str(condition.get("reason") or ""),
            "message": str(condition.get("message") or ""),
            "lastTransitionTime": str(condition.get("lastTransitionTime") or ""),
        }
    ready_condition = found.get("Ready", {})
    degraded_condition = found.get("Degraded", {})

    # T049a — derive unverified property/node from the Ready message when present.
    unverified: list[dict[str, str]] = []
    msg = str(ready_condition.get("message") or "")
    # Expected shape from the controller: "node <node> checks[<i>].<type>: <err>"
    m = re.search(r"node\s+([a-z0-9-]+)\s+checks\[\d+\]\.([a-z0-9-]+):\s*(.+)", msg)
    if m:
        node, check_type, err = m.group(1), m.group(2), m.group(3)
        # Heuristic: treat executor/transport errors as "did not run" — unknown check type,
        # unreachable executor, command not found, or timeouts. A pure mismatch remains a
        # verification failure, not an unverified property.
        low_err = err.lower()
        did_not_run = any(
            key in low_err
            for key in (
                "unknown check type",
                "unreachable",
                "timeout",
                "not found",
                "exit code",
            )
        )
        if did_not_run:
            unverified.append({"node": node, "property": check_type})

    construct, provenance = _derive_construct_and_provenance(annotations)

    return {
        "kind": str(obj.get("kind") or ""),
        "name": str(meta.get("name") or ""),
        "namespace": str(meta.get("namespace") or ""),
        "serviceType": construct or "",
        "sourceServiceType": provenance or "",
        "ready": ready_condition.get("status"),
        "reason": ready_condition.get("reason", ""),
        "message": ready_condition.get("message", ""),
        "lastTransitionTime": ready_condition.get("lastTransitionTime", ""),
        "degraded": degraded_condition.get("status"),
        "degradedReason": degraded_condition.get("reason", ""),
        "degradedMessage": degraded_condition.get("message", ""),
        "degradedLastTransitionTime": degraded_condition.get("lastTransitionTime", ""),
        "unverified": unverified,
    }


def _phase_from(resources: list[dict[str, Any]]) -> str:
    if not resources:
        return PHASE_NOT_FOUND
    if any(r.get("ready") is False or r.get("degraded") is True for r in resources):
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
    if not result["serviceId"]:
        result["serviceId"] = next(
            (service_id for obj in objects if (service_id := _service_id_from_object(obj))),
            "",
        )
    result["resources"] = resources
    result["phase"] = _phase_from(resources)
    return result


@tool(name="deployer.remove_service")
def remove_service(
    *, correlation_id: str | None, service_id: str | None = None, confirmed: bool = False
) -> dict[str, Any]:
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
