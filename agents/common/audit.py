"""Audit emission for the intent tier (FR-030, SC-006).

FR-030: every confirmation, decline, submission, and refusal is recorded as
an :class:`~common.schemas.audit.AuditEvent`. Per data-model.md §7 each
event is emitted **as both a span event and a Kubernetes ``Event`` in
``agentic-netops-intent``**.

Emission layers (all three are wired here):

* **Span event** (T103) — on the active OpenTelemetry span, so the
  request's single correlated trace (FR-035) carries the audit point.
* **Process-local sink** — a thread-safe in-memory list plus an optional
  JSONL file (``AUDIT_LOG_PATH``), which is the durable record for
  processes that hold no cluster identity (the supervisor's ServiceAccount
  has ``automountServiceAccountToken: false`` and therefore cannot write
  Kubernetes Events itself — the deployer's identity writes them when it
  submits).
* **Kubernetes ``Event``** (T104) — a core/v1 ``Event`` object in
  ``agentic-netops-intent``, best-effort: written when a cluster identity is
  available (in-cluster token, or the ``AGENTIC_NETOPS_API_ENDPOINT`` /
  ``AGENTIC_NETOPS_BEARER_TOKEN`` overrides the e2e tests mint), skipped with a
  logged warning otherwise. SC-006 reconciles the audit stream against the
  resources actually present under the correlation-id label.

Every :class:`AuditEvent` emitted through :func:`emit_audit_event` carries
principal, thread id, correlation id, resources, and reason (T105) — the
Pydantic model makes them required, and the cross-field shape rules
(``refuse``/``decline`` carry no resources; ``submit`` requires them) are
enforced here, at the emission boundary, before anything is written.

FR-031: every field that can carry free text is redacted through
:func:`common.redaction.redact` before emission.
"""

from __future__ import annotations

import json
import logging
import os
import socket
import threading
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

import httpx
from pydantic import BaseModel, ValidationError

from common.redaction import redact
from common.schemas.audit import AuditEvent

logger = logging.getLogger("agentic_netops.common.audit")

# ---------------------------------------------------------------------------
# Kubernetes Event emission (T104) — endpoint / identity resolution.
#
# In-cluster (the deployer pod): the API server is the well-known service
# and the bearer token is the pod's ServiceAccount token. Out of cluster
# (the e2e tests): ``AGENTIC_NETOPS_API_ENDPOINT`` + ``AGENTIC_NETOPS_BEARER_TOKEN``
# (+ ``AGENTIC_NETOPS_VERIFY_TLS=0`` for the Kind self-signed cert) override.
# ---------------------------------------------------------------------------
_IN_CLUSTER_API = "https://kubernetes.default.svc:443"
_TOKEN_FILE = Path("/var/run/secrets/kubernetes.io/serviceaccount/token")
_CACERT_FILE = Path("/var/run/secrets/kubernetes.io/serviceaccount/ca.crt")

INTENT_NAMESPACE = "agentic-netops-intent"  # the tier's resource namespace (Decision 12)

EVENT_REASON_BY_TYPE = {
    "confirm": "Confirm",
    "decline": "Decline",
    "submit": "Submit",
    "refuse": "Refuse",
}
_EVENT_KIND_BY_TYPE = {
    "confirm": "Normal",
    "submit": "Normal",
    "decline": "Warning",
    "refuse": "Warning",
}


class AuditEmissionError(ValueError):
    """An AuditEvent failed its shape rules and was NOT emitted."""


# ---------------------------------------------------------------------------
# Process-local sink (durable record for identity-less processes; the test
# harnesses and SC-016 read it back).
# ---------------------------------------------------------------------------
class AuditSink:
    """Thread-safe in-memory audit log with optional JSONL persistence."""

    def __init__(self, path: str | None = None):
        self._events: list[AuditEvent] = []
        self._lock = threading.Lock()
        self.path = Path(path) if path else None

    def record(self, event: AuditEvent) -> None:
        with self._lock:
            self._events.append(event)
        if self.path is not None:
            self.path.parent.mkdir(parents=True, exist_ok=True)
            with self.path.open("a", encoding="utf-8") as fh:
                fh.write(event.model_dump_json() + "\n")

    @property
    def events(self) -> list[AuditEvent]:
        with self._lock:
            return list(self._events)

    def by_correlation(self, correlation_id: str) -> list[AuditEvent]:
        return [e for e in self.events if e.correlation_id == correlation_id]

    def reset(self) -> None:
        with self._lock:
            self._events.clear()
        if self.path is not None and self.path.exists():
            self.path.unlink()


_default_sink: AuditSink | None = None
_sink_lock = threading.Lock()


def get_audit_sink() -> AuditSink:
    """The process sink; JSONL path from ``AUDIT_LOG_PATH`` when set."""
    global _default_sink
    with _sink_lock:
        if _default_sink is None:
            _default_sink = AuditSink(os.getenv("AUDIT_LOG_PATH"))
        return _default_sink


def reset_audit_sink(path: str | None = None) -> AuditSink:
    """Replace the process sink (tests); returns the fresh sink."""
    global _default_sink
    with _sink_lock:
        _default_sink = AuditSink(path)
        return _default_sink


# ---------------------------------------------------------------------------
# T103 — span-event emission.
# ---------------------------------------------------------------------------
def _emit_span_event(event: AuditEvent, attributes: dict[str, Any]) -> None:
    """Record the audit point on the active OpenTelemetry span (T103).

    One trace per request (FR-035): the root span's trace id is the
    correlation id, so the span event lands in the request's trace. A
    missing/inactive span is not an error — the sink record below is the
    durable audit point and the span is best-effort observability.
    """
    try:
        from opentelemetry import trace

        span = trace.get_current_span()
        if span is None or not span.is_recording():
            return
        span.add_event("intent.audit", attributes=attributes)
    except Exception:  # noqa: BLE001 - audit must never break the request path
        logger.debug("span-event emission unavailable; sink record stands", exc_info=True)


# ---------------------------------------------------------------------------
# T104 — Kubernetes Event emission.
# ---------------------------------------------------------------------------
class _K8sEventIdentity:
    """Resolved API endpoint + bearer token (or None when identity-less)."""

    def __init__(self, endpoint: str, token: str, verify_tls: bool):
        self.endpoint = endpoint
        self.token = token
        self.verify_tls = verify_tls


def resolve_k8s_identity() -> _K8sEventIdentity | None:
    """Resolve the cluster API identity, if one is available.

    Order: explicit env overrides (e2e tests mint a short-lived SA token),
    then the in-cluster ServiceAccount files. Returns None when neither
    exists — the caller then skips the Kubernetes Event (the span event
    and sink record remain the durable audit point).
    """
    endpoint = os.getenv("AGENTIC_NETOPS_API_ENDPOINT")
    token = os.getenv("AGENTIC_NETOPS_BEARER_TOKEN")
    if endpoint and token:
        verify = os.getenv("AGENTIC_NETOPS_VERIFY_TLS", "1").lower() in ("1", "true", "yes")
        return _K8sEventIdentity(endpoint, token, verify)
    if _TOKEN_FILE.exists():
        try:
            token = _TOKEN_FILE.read_text(encoding="utf-8").strip()
        except OSError:
            return None
        if token:
            verify = os.getenv("AGENTIC_NETOPS_VERIFY_TLS", "1").lower() in ("1", "true", "yes")
            return _K8sEventIdentity(_IN_CLUSTER_API, token, verify)
    return None


def _event_manifest(event: AuditEvent, seq: int) -> dict[str, Any]:
    """Build the core/v1 Event object for this audit record (T104).

    The Event carries the same correlation-id label the submitted resources
    carry (contracts/kubernetes-objects.md), which is what makes SC-006's
    reconciliation a pair of label-selector queries.
    """
    # firstTimestamp/lastTimestamp are metav1.Time (plain RFC3339 "Z" is
    # fine); eventTime is a microtime.MicroTime, which the API server
    # decodes with the strict layout 2006-01-02T15:04:05.000000Z07:00 —
    # the six fractional digits are MANDATORY (a "Z"-only eventTime is
    # rejected with 400 BadRequest).
    now = datetime.now(UTC)
    now_ts = now.strftime("%Y-%m-%dT%H:%M:%SZ")
    now_micro = now.strftime("%Y-%m-%dT%H:%M:%S.%fZ")
    host = os.getenv("POD_NAME", socket.gethostname())
    resources = ", ".join(f"{r.kind}/{r.name}" for r in event.resources) or "none"
    message = redact(
        f"intent-tier audit: type={event.event_type} principal={event.principal} "
        f"thread={event.thread_id} resources=[{resources}]"
        + (f" reason={event.reason}" if event.reason else "")
    )
    return {
        "apiVersion": "v1",
        "kind": "Event",
        "metadata": {
            # RFC 1123: 32-hex correlation + type + zero-padded sequence
            "name": f"{event.correlation_id}-{event.event_type}-{seq:04d}",
            "namespace": INTENT_NAMESPACE,
            "labels": {
                "agentic-netops.io/correlation-id": event.correlation_id,
                "agentic-netops.io/tier": "intent",
            },
        },
        "involvedObject": {
            "apiVersion": "v1",
            "kind": "ServiceRequest",
            "namespace": INTENT_NAMESPACE,
            "name": event.thread_id,
        },
        "reason": EVENT_REASON_BY_TYPE[event.event_type],
        "message": message,
        "type": _EVENT_KIND_BY_TYPE[event.event_type],
        # Required by the API server whenever reportingComponent is set:
        # action (CamelCase verb) and reportingInstance (non-empty id).
        "action": EVENT_REASON_BY_TYPE[event.event_type],
        "reportingInstance": host,
        "firstTimestamp": now_ts,
        "lastTimestamp": now_ts,
        "eventTime": now_micro,
        "count": 1,
        "source": {"component": "intent-tier", "host": host},
        "reportingComponent": "intent-tier",
    }


def emit_kubernetes_event(event: AuditEvent, seq: int = 1) -> bool:
    """POST the Kubernetes ``Event`` for this audit record (T104).

    Best-effort by contract: without a cluster identity (the supervisor)
    this is skipped — the span event and sink record are the durable audit
    point. Returns True when the API server accepted the Event.
    """
    identity = resolve_k8s_identity()
    if identity is None:
        logger.debug(
            "no cluster identity for audit %s/%s; span event + sink stand",
            event.event_type,
            event.correlation_id,
        )
        return False
    manifest = _event_manifest(event, seq)
    url = f"{identity.endpoint.rstrip('/')}/api/v1/namespaces/{INTENT_NAMESPACE}/events"
    try:
        resp = httpx.post(
            url,
            json=manifest,
            headers={"Authorization": f"Bearer {identity.token}"},
            verify=identity.verify_tls,
            timeout=10.0,
        )
        if resp.status_code // 100 == 2:
            return True
        logger.warning(
            "Kubernetes Event %s rejected (HTTP %s): %s",
            manifest["metadata"]["name"],
            resp.status_code,
            redact(resp.text[:300]),
        )
    except Exception as exc:  # noqa: BLE001 - audit must not break the request path
        logger.warning("Kubernetes Event emission failed: %s", redact(str(exc)))
    return False


# ---------------------------------------------------------------------------
# Emission entry point (T103 + T104 + T105).
# ---------------------------------------------------------------------------
def emit_audit_event(event: AuditEvent) -> AuditEvent:
    """Emit one audit record through every layer (FR-030).

    * T105 — the event must carry principal, thread id, correlation id,
      resources, and reason; the Pydantic model requires the fields and
      ``validate_event_shape()`` enforces the cross-field rules
      (refuse/decline carry no resources; submit requires them). A
      malformed event raises :class:`AuditEmissionError` and is NOT
      emitted — a corrupted audit trail is worse than a missing line.
    * T103 — span event on the active OTel span.
    * sink — in-memory + JSONL (``AUDIT_LOG_PATH``) durable record.
    * T104 — Kubernetes ``Event`` in ``agentic-netops-intent`` (best-effort).

    Free-text fields are redacted (FR-031) before any layer sees them.
    """
    try:
        violations = event.validate_event_shape()
        if violations:
            raise AuditEmissionError("; ".join(violations))
        # T105 field presence is guaranteed by the model (required fields);
        # re-validate on a copy so a hand-constructed bypass is caught.
        AuditEvent.model_validate(event.model_dump(mode="json"))
    except (AuditEmissionError, ValidationError) as exc:
        logger.error("audit emission rejected (malformed event): %s", exc)
        raise AuditEmissionError(str(exc)) from exc

    redacted_reason = redact(event.reason) if event.reason else None
    event = event.model_copy(update={"reason": redacted_reason})

    attributes = {
        "audit.event_type": event.event_type,
        "audit.correlation_id": event.correlation_id,
        "audit.thread_id": event.thread_id,
        "audit.principal": event.principal,
        "audit.resources": json.dumps(
            [r.model_dump(mode="json") for r in event.resources], separators=(",", ":")
        ),
        "audit.reason": redacted_reason or "",
        "audit.at": event.at.isoformat(),
    }
    _emit_span_event(event, attributes)

    sink = get_audit_sink()
    sink.record(event)
    logger.info(
        "audit %s correlation=%s thread=%s principal=%s resources=%d reason=%s",
        event.event_type,
        event.correlation_id,
        event.thread_id,
        event.principal,
        len(event.resources),
        (redacted_reason or "")[:200],
    )

    seq = sum(1 for e in sink.by_correlation(event.correlation_id))  # 1-based
    emit_kubernetes_event(event, seq=seq)
    return event


def build_audit_event(
    event_type: str,
    *,
    correlation_id: str,
    thread_id: str,
    principal: str,
    resources: list[BaseModel] | None = None,
    reason: str | None = None,
) -> AuditEvent:
    """Convenience constructor used by the graph nodes (T105).

    ``at`` is stamped here so every emitted event carries a wall-clock
    time; the caller supplies the four identity fields and the optional
    resources/reason.
    """
    from common.schemas.refs import ResourceRef

    refs: list[ResourceRef] = []
    for r in resources or []:
        refs.append(r if isinstance(r, ResourceRef) else ResourceRef.model_validate(r))
    return AuditEvent(
        event_type=event_type,  # type: ignore[arg-type]
        correlation_id=correlation_id,
        thread_id=thread_id,
        principal=principal,
        at=datetime.now(UTC),
        resources=refs,
        reason=reason,
    )
