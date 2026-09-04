"""Atomic Kubernetes submission for translated service-intent manifests.

The Kubernetes API has no multi-object transaction. This module implements
the feature contract as server-side dry-run of the complete bundle followed by
deterministically ordered server-side apply. A partial apply is rolled back by
the correlation-id label shared by every object in the transaction.
"""

from __future__ import annotations

import copy
import hashlib
import json
import logging
import os
import re
from collections.abc import Callable, Iterable
from dataclasses import dataclass
from datetime import UTC, datetime
from typing import Any, Protocol
from urllib.parse import quote

import httpx
from pydantic import ValidationError

from common.audit import INTENT_NAMESPACE, build_audit_event, emit_audit_event, resolve_k8s_identity
from common.redaction import redact
from common.schemas.refs import ResourceRef
from common.telemetry import CORRELATION_LABEL

logger = logging.getLogger("agentic_netops.network_deployer.submit")

FIELD_MANAGER = "agentic-netops-intent-deployer"
TIER_LABEL = "agentic-netops.io/tier"
THREAD_ANNOTATION = "agentic-netops.io/intent-thread-id"
PRINCIPAL_ANNOTATION = "agentic-netops.io/intent-principal"
SUBMITTED_AT_ANNOTATION = "agentic-netops.io/intent-submitted-at"

# The allow-list is also the REST discovery table. An arbitrary translator
# object must never become an arbitrary Kubernetes API request.
RESOURCE_PATHS: dict[tuple[str, str], str] = {
    ("network.kubenet.dev/v1alpha1", "Network"): "networks",
    ("agentic-netops.io/v1alpha1", "SRv6Service"): "srv6services",
}

_DNS_SUBDOMAIN = re.compile(r"^[a-z0-9](?:[-a-z0-9.]*[a-z0-9])?$")
_CORRELATION_ID = re.compile(r"^[a-f0-9]{32}$")

# The supervisor fences every payload it sends a worker (T095); the deployer
# extracts the fenced block before JSON parsing (the shared fence format of
# supervisors/provisioning/prompts/system.py).
DATA_FENCE_RE = re.compile(
    r"<<<DATA worker_text[^>]*>>>\n(.*?)\n<<<END_DATA worker_text[^>]*>>>",
    re.DOTALL,
)


def _resource_identity(manifest: dict[str, Any]) -> str:
    meta = manifest.get("metadata") if isinstance(manifest.get("metadata"), dict) else {}
    return f"{manifest.get('kind') or '<unknown>'}/{meta.get('name') or '<unnamed>'}"


class DeploymentTransactionError(RuntimeError):
    """A named deployer phase failed and no success report may be emitted."""

    def __init__(
        self,
        phase: str,
        message: str,
        *,
        resource: str | None = None,
        rolled_back: list[ResourceRef] | None = None,
        survivors: list[ResourceRef] | None = None,
    ) -> None:
        self.phase = phase
        self.resource = resource
        self.rolled_back = list(rolled_back or [])
        self.survivors = list(survivors or [])
        detail = f"{phase} failed"
        if resource:
            detail += f" for {resource}"
        detail += f": {message}"
        super().__init__(detail)

    def report(self) -> dict[str, Any]:
        return {
            "phase": self.phase,
            "resource": self.resource,
            "message": str(self),
            "rolledBack": [r.model_dump(mode="json") for r in self.rolled_back],
            "survivors": [r.model_dump(mode="json") for r in self.survivors],
        }


class IntentAPI(Protocol):
    def dry_run_apply(self, manifest: dict[str, Any]) -> dict[str, Any]: ...

    def apply(self, manifest: dict[str, Any]) -> dict[str, Any]: ...

    def get(self, ref: ResourceRef) -> dict[str, Any] | None: ...

    def list_by_correlation(self, correlation_id: str) -> list[dict[str, Any]]: ...

    def delete(self, ref: ResourceRef) -> bool: ...

    def close(self) -> None: ...


@dataclass(frozen=True)
class DeploymentContext:
    correlation_id: str
    thread_id: str
    principal: str

    def validate(self) -> None:
        if not _CORRELATION_ID.fullmatch(self.correlation_id):
            raise DeploymentTransactionError(
                "request-validation",
                "correlationId must be exactly 32 lowercase hexadecimal characters",
            )
        if not self.thread_id.strip():
            raise DeploymentTransactionError("request-validation", "threadId is required")
        if not self.principal.strip():
            raise DeploymentTransactionError("request-validation", "principal is required")


@dataclass(frozen=True)
class DeploymentEnvelope:
    """The validated request the supervisor sends (deployment contract)."""

    intent: dict[str, Any]
    context: DeploymentContext


def _bare_intent_context(intent: dict[str, Any]) -> DeploymentContext:
    """Compatibility context for a bare normalized intent.

    Production supervisor traffic always uses the envelope, so every
    resource carries the conversation's correlation metadata. A bare intent
    (direct A2A callers, tests) has none; stamping a conversation correlation
    it does not have would falsify the audit trail, so the context is derived
    deterministically from the intent itself and named as compatibility
    traffic.
    """

    digest = hashlib.sha256(json.dumps(intent, sort_keys=True, separators=(",", ":")).encode()).hexdigest()
    service_id = str(intent.get("serviceId") or "unknown")
    return DeploymentContext(
        correlation_id=digest[:32],
        thread_id=f"bare-intent:{service_id}",
        principal="compat-direct",
    )


def parse_deployment_envelope(text: str) -> DeploymentEnvelope | None:
    """Parse a deployment request (doc step 1).

    Accepts the production envelope ``{"action": "submit", "intent": {...},
    "context": {correlationId, threadId, principal}}`` and, for
    compatibility, a bare ``NormalizedServiceIntent`` JSON. The supervisor's
    nonce-fenced ``worker_text`` block is unwrapped first. Returns ``None``
    when the text is not a submission at all (a tools command or unparseable
    content) so the caller can fall back to the tools path; raises
    :class:`DeploymentTransactionError` when it *is* a submission but
    malformed.
    """

    content = text
    fence = DATA_FENCE_RE.search(content)
    if fence:
        content = fence.group(1)
    try:
        obj = json.loads(content)
    except Exception:  # noqa: BLE001 - not JSON -> not a submission
        return None
    if not isinstance(obj, dict):
        return None

    action = str(obj.get("action") or "").strip().lower()
    if action == "submit" or ("intent" in obj and "context" in obj):
        intent = obj.get("intent")
        if not isinstance(intent, dict):
            raise DeploymentTransactionError(
                "request-validation", "deployment envelope field 'intent' must be an object"
            )
        raw_context = obj.get("context")
        if not isinstance(raw_context, dict):
            raise DeploymentTransactionError(
                "request-validation", "deployment envelope field 'context' must be an object"
            )
        missing = [k for k in ("correlationId", "threadId", "principal") if not str(raw_context.get(k) or "").strip()]
        if missing:
            raise DeploymentTransactionError(
                "request-validation", f"deployment envelope context is missing {', '.join(missing)}"
            )
        context = DeploymentContext(
            correlation_id=str(raw_context["correlationId"]).strip(),
            thread_id=str(raw_context["threadId"]).strip(),
            principal=str(raw_context["principal"]).strip(),
        )
        context.validate()
        return DeploymentEnvelope(intent=intent, context=context)

    # Bare normalized intent (compatibility path).
    if {"serviceId", "type", "tenant"}.issubset(set(obj.keys())):
        return DeploymentEnvelope(intent=obj, context=_bare_intent_context(obj))
    return None


class KubernetesIntentClient:
    """Minimal REST client constrained to :data:`RESOURCE_PATHS`."""

    def __init__(self) -> None:
        identity = resolve_k8s_identity()
        if identity is None:
            raise DeploymentTransactionError(
                "cluster-identity",
                "no Kubernetes service-account token is available",
            )
        self.endpoint = identity.endpoint.rstrip("/")
        self._headers = {"Authorization": f"Bearer {identity.token}"}
        self._client = httpx.Client(verify=identity.verify, timeout=20.0)

    @staticmethod
    def _plural(api_version: str, kind: str) -> str:
        try:
            return RESOURCE_PATHS[(api_version, kind)]
        except KeyError as exc:
            raise DeploymentTransactionError(
                "manifest-validation",
                f"resource {api_version}/{kind} is outside the deployer allow-list",
            ) from exc

    def _collection_url(self, api_version: str, kind: str) -> str:
        group, version = api_version.split("/", 1)
        plural = self._plural(api_version, kind)
        return (
            f"{self.endpoint}/apis/{quote(group, safe='')}/{quote(version, safe='')}"
            f"/namespaces/{quote(INTENT_NAMESPACE, safe='')}/{plural}"
        )

    def _object_url(self, api_version: str, kind: str, name: str) -> str:
        return f"{self._collection_url(api_version, kind)}/{quote(name, safe='')}"

    @staticmethod
    def _api_error(response: httpx.Response) -> str:
        try:
            body = response.json()
            if isinstance(body, dict):
                return str(body.get("message") or body.get("reason") or body)[:600]
        except Exception:
            pass
        return response.text.strip()[:600] or f"HTTP {response.status_code}"

    def _server_side_apply(self, manifest: dict[str, Any], *, dry_run: bool) -> dict[str, Any]:
        meta = manifest["metadata"]
        url = self._object_url(str(manifest["apiVersion"]), str(manifest["kind"]), str(meta["name"]))
        params: dict[str, str] = {"fieldManager": FIELD_MANAGER}
        if dry_run:
            params["dryRun"] = "All"
        headers = {**self._headers, "Content-Type": "application/apply-patch+yaml"}
        try:
            response = self._client.patch(
                url,
                headers=headers,
                params=params,
                content=json.dumps(manifest, separators=(",", ":")),
            )
        except (httpx.HTTPError, OSError) as exc:
            raise RuntimeError(f"Kubernetes API request failed: {exc}") from exc
        if response.status_code // 100 != 2:
            raise RuntimeError(f"HTTP {response.status_code}: {self._api_error(response)}")
        body = response.json()
        if not isinstance(body, dict):
            raise RuntimeError("Kubernetes API returned a non-object response")
        return body

    def dry_run_apply(self, manifest: dict[str, Any]) -> dict[str, Any]:
        return self._server_side_apply(manifest, dry_run=True)

    def apply(self, manifest: dict[str, Any]) -> dict[str, Any]:
        return self._server_side_apply(manifest, dry_run=False)

    def get(self, ref: ResourceRef) -> dict[str, Any] | None:
        url = self._object_url(ref.apiVersion, ref.kind, ref.name)
        response = self._client.get(url, headers=self._headers)
        if response.status_code == 404:
            return None
        if response.status_code // 100 != 2:
            raise RuntimeError(f"HTTP {response.status_code}: {self._api_error(response)}")
        body = response.json()
        return body if isinstance(body, dict) else None

    def list_by_correlation(self, correlation_id: str) -> list[dict[str, Any]]:
        found: list[dict[str, Any]] = []
        selector = f"{CORRELATION_LABEL}={correlation_id}"
        for api_version, kind in sorted(RESOURCE_PATHS):
            url = self._collection_url(api_version, kind)
            response = self._client.get(url, headers=self._headers, params={"labelSelector": selector})
            if response.status_code == 404:
                continue
            if response.status_code // 100 != 2:
                raise RuntimeError(
                    f"list {api_version}/{kind}: HTTP {response.status_code}: {self._api_error(response)}"
                )
            body = response.json()
            if isinstance(body, dict):
                found.extend(item for item in body.get("items", []) if isinstance(item, dict))
        return found

    def delete(self, ref: ResourceRef) -> bool:
        url = self._object_url(ref.apiVersion, ref.kind, ref.name)
        response = self._client.delete(
            url,
            headers={**self._headers, "Content-Type": "application/json"},
            content=json.dumps({"kind": "DeleteOptions", "apiVersion": "v1", "propagationPolicy": "Background"}),
        )
        if response.status_code == 404:
            return True
        return response.status_code // 100 == 2

    def close(self) -> None:
        self._client.close()


def validate_and_stamp_manifests(
    manifests: Iterable[dict[str, Any]],
    context: DeploymentContext,
    *,
    submitted_at: datetime | None = None,
) -> list[dict[str, Any]]:
    """Validate the translator boundary and stamp immutable request metadata."""

    context.validate()
    timestamp = (submitted_at or datetime.now(UTC)).astimezone(UTC).isoformat().replace("+00:00", "Z")
    prepared: list[dict[str, Any]] = []
    seen: set[tuple[str, str, str]] = set()
    for raw in manifests:
        if not isinstance(raw, dict):
            raise DeploymentTransactionError("manifest-validation", "translator returned a non-object manifest")
        manifest = copy.deepcopy(raw)
        api_version = manifest.get("apiVersion")
        kind = manifest.get("kind")
        if (api_version, kind) not in RESOURCE_PATHS:
            raise DeploymentTransactionError(
                "manifest-validation",
                f"resource {api_version}/{kind} is outside the deployer allow-list",
                resource=_resource_identity(manifest),
            )
        metadata = manifest.get("metadata")
        if not isinstance(metadata, dict):
            raise DeploymentTransactionError(
                "manifest-validation", "metadata must be an object", resource=_resource_identity(manifest)
            )
        name = metadata.get("name")
        if not isinstance(name, str) or len(name) > 253 or not _DNS_SUBDOMAIN.fullmatch(name):
            raise DeploymentTransactionError(
                "manifest-validation",
                "metadata.name is not a valid DNS subdomain",
                resource=_resource_identity(manifest),
            )
        if not isinstance(manifest.get("spec"), dict):
            raise DeploymentTransactionError(
                "manifest-validation", "spec must be an object", resource=f"{kind}/{name}"
            )
        identity = (str(api_version), str(kind), name)
        if identity in seen:
            raise DeploymentTransactionError(
                "manifest-validation", "duplicate resource in translated bundle", resource=f"{kind}/{name}"
            )
        seen.add(identity)

        # The translator's legacy namespace is not an ownership decision. The
        # deployer always places its output inside the tier's RBAC boundary.
        metadata["namespace"] = INTENT_NAMESPACE
        for server_field in ("uid", "resourceVersion", "generation", "managedFields"):
            metadata.pop(server_field, None)
        labels = metadata.setdefault("labels", {})
        annotations = metadata.setdefault("annotations", {})
        if not isinstance(labels, dict) or not isinstance(annotations, dict):
            raise DeploymentTransactionError(
                "manifest-validation", "metadata labels/annotations must be objects", resource=f"{kind}/{name}"
            )
        labels[CORRELATION_LABEL] = context.correlation_id
        labels[TIER_LABEL] = "intent"
        annotations[THREAD_ANNOTATION] = context.thread_id
        annotations[PRINCIPAL_ANNOTATION] = context.principal
        annotations[SUBMITTED_AT_ANNOTATION] = timestamp
        prepared.append(manifest)

    if not prepared:
        raise DeploymentTransactionError("manifest-validation", "translator returned an empty manifest bundle")
    return deterministic_apply_order(prepared)


def deterministic_apply_order(manifests: Iterable[dict[str, Any]]) -> list[dict[str, Any]]:
    """Return a copy sorted by namespace, kind, and name (T267)."""

    def key(manifest: dict[str, Any]) -> tuple[str, str, str]:
        metadata = manifest.get("metadata") if isinstance(manifest.get("metadata"), dict) else {}
        return (
            str(metadata.get("namespace") or ""),
            str(manifest.get("kind") or ""),
            str(metadata.get("name") or ""),
        )

    return sorted((copy.deepcopy(m) for m in manifests), key=key)


def dry_run_all(manifests: Iterable[dict[str, Any]], client: IntentAPI) -> list[dict[str, Any]]:
    """Server-side dry-run every object, stopping before any real apply."""

    checked: list[dict[str, Any]] = []
    for manifest in manifests:
        try:
            checked.append(client.dry_run_apply(manifest))
        except Exception as exc:  # noqa: BLE001
            raise DeploymentTransactionError(
                "dry-run", str(exc), resource=_resource_identity(manifest)
            ) from exc
    return checked


def _ref_from_object(obj: dict[str, Any]) -> ResourceRef:
    metadata = obj.get("metadata") if isinstance(obj.get("metadata"), dict) else {}
    return ResourceRef(
        apiVersion=str(obj.get("apiVersion") or ""),
        kind=str(obj.get("kind") or ""),
        namespace=str(metadata.get("namespace") or INTENT_NAMESPACE),
        name=str(metadata.get("name") or ""),
        uid=str(metadata["uid"]) if metadata.get("uid") else None,
        ready=None,
    )


def rollback_by_selector(client: IntentAPI, correlation_id: str) -> tuple[list[ResourceRef], list[ResourceRef]]:
    """Delete all allow-listed objects with the transaction correlation label."""

    try:
        objects = client.list_by_correlation(correlation_id)
    except Exception as exc:  # noqa: BLE001
        raise DeploymentTransactionError("rollback", f"could not enumerate rollback set: {exc}") from exc
    refs = sorted((_ref_from_object(obj) for obj in objects), key=lambda r: (r.namespace, r.kind, r.name))
    rolled_back: list[ResourceRef] = []
    survivors: list[ResourceRef] = []
    for ref in refs:
        try:
            deleted = client.delete(ref)
        except Exception:  # noqa: BLE001
            deleted = False
        (rolled_back if deleted else survivors).append(ref)
    return rolled_back, survivors


def apply_all(
    manifests: Iterable[dict[str, Any]], client: IntentAPI, correlation_id: str
) -> list[ResourceRef]:
    """Apply the whole bundle or roll back the correlation-labelled set."""

    submitted: list[ResourceRef] = []
    for manifest in deterministic_apply_order(manifests):
        try:
            submitted.append(_ref_from_object(client.apply(manifest)))
        except Exception as exc:  # noqa: BLE001
            try:
                rolled_back, survivors = rollback_by_selector(client, correlation_id)
            except DeploymentTransactionError as rollback_exc:
                raise DeploymentTransactionError(
                    "apply",
                    f"{exc}; rollback also failed: {rollback_exc}",
                    resource=_resource_identity(manifest),
                    survivors=submitted,
                ) from exc
            message = str(exc)
            if survivors:
                message += "; rollback incomplete"
            raise DeploymentTransactionError(
                "apply",
                message,
                resource=_resource_identity(manifest),
                rolled_back=rolled_back,
                survivors=survivors,
            ) from exc
    return submitted


def build_default_client() -> KubernetesIntentClient:
    """Factory seam used by the worker and replaced by unit tests."""

    return KubernetesIntentClient()


def convergence_settings() -> tuple[float, float]:
    """The convergence watch bound.

    Measured convergence on the lab varies with how much the fabric executor
    already carries: ~35 s on an idle fabric, 133 s on a loaded one (both
    observed 2026-09-04, Network applied through both leaves programmed and
    verified). The default covers that spread, because the watch is the only
    thing standing between the operator and an unanswered "did it deploy?".

    It is a bound, not a guarantee: past it the operator is told the truth
    ("still converging") and the status question resolves the outcome from the
    cluster. Do not chase an arbitrarily slow fabric by raising this — a
    blocking call is the wrong shape for that, and the supervisor's per-call
    bound for the deployer (``DEPLOYER_CALL_TIMEOUT_SECONDS``) has to stay
    above it or the call is cut off before the watch can report.
    """

    timeout = float(os.getenv("DEPLOYER_CONVERGENCE_TIMEOUT_SECONDS", "150"))
    poll = float(os.getenv("DEPLOYER_CONVERGENCE_POLL_SECONDS", "1"))
    return max(0.0, timeout), max(0.05, poll)


# ---------------------------------------------------------------------------
# The transaction (docs/INTENT_TIER_DEPLOYMENT_TRANSACTION.md, steps 1-8).
# ---------------------------------------------------------------------------


def _audit(
    event_type: str,
    context: DeploymentContext,
    resources: list[ResourceRef] | None = None,
    reason: str | None = None,
) -> None:
    """Best-effort deployer audit event (the pod identity writes Events).

    An emission failure (no cluster identity, malformed correlation) must
    never mask the transaction outcome it records.
    """

    if not _CORRELATION_ID.fullmatch(context.correlation_id):
        logger.warning("audit %s skipped: correlation id is not 32-hex", event_type)
        return
    try:
        emit_audit_event(
            build_audit_event(
                event_type,
                correlation_id=context.correlation_id,
                thread_id=context.thread_id,
                principal=context.principal,
                resources=resources,
                reason=reason,
            )
        )
    except Exception as exc:  # noqa: BLE001 - audit must not break the request path
        logger.warning("audit %s emission failed: %s", event_type, redact(str(exc)))


def run_deployment_transaction(
    envelope: DeploymentEnvelope,
    *,
    client: IntentAPI | None = None,
    translator: Callable[[dict[str, Any]], dict[str, Any]] | None = None,
    watch: bool = True,
    timeout_seconds: float | None = None,
    poll_seconds: float | None = None,
    submitted_at: datetime | None = None,
) -> dict[str, Any]:
    """Execute the deployment transaction and return the submission payload.

    Steps 1-7 of the deployment contract run here; step 8 (emitting the
    authoritative report) belongs to the caller. The payload carries
    ``{"submitted": [ResourceRef...], "convergence": [...]}`` and is only
    ever returned after every apply has succeeded. Any named phase failure
    raises :class:`DeploymentTransactionError`; a partial apply is rolled
    back by the correlation label before the error propagates.
    """

    envelope.context.validate()

    # Step 1 — validate the request against NormalizedServiceIntent.
    from common.schemas.normalized_intent import NormalizedServiceIntent

    try:
        normalized = NormalizedServiceIntent.model_validate(envelope.intent)
    except ValidationError as exc:
        raise DeploymentTransactionError(
            "request-validation", f"intent failed NormalizedServiceIntent validation: {exc}"
        ) from exc

    # Step 2 — translate once, pod-local; Python does not reproduce translation.
    if translator is None:
        from provisioning.deployer.tools.deployer_tools import submit_service as default_translator

        translator = default_translator
    try:
        translated = translator(normalized.model_dump(mode="json"))
    except Exception as exc:  # noqa: BLE001 - named translation phase failure
        raise DeploymentTransactionError("translation", f"translator call failed: {exc}") from exc
    manifests = translated.get("manifests") if isinstance(translated, dict) else None
    if not isinstance(manifests, list):
        detail = json.dumps(translated)[:400] if translated else "empty response"
        raise DeploymentTransactionError("translation", f"translator rejected the intent: {detail}")

    # Step 3 — validate and stamp manifests.
    prepared = validate_and_stamp_manifests(manifests, envelope.context, submitted_at=submitted_at)

    owns_client = client is None
    client = client or build_default_client()
    try:
        # Steps 4-6 — dry-run the whole bundle, apply deterministically,
        # roll back the correlation-labelled set on any apply failure.
        dry_run_all(prepared, client)
        submitted = apply_all(prepared, client, envelope.context.correlation_id)

        # The submit audit point: every apply succeeded; the report is
        # authoritative from here on.
        _audit(
            "submit",
            envelope.context,
            resources=submitted,
            reason="deployment transaction applied",
        )

        # Step 7 — watch convergence.
        convergence: list[dict[str, Any]] = []
        if watch and submitted:
            from provisioning.deployer.watch import watch_convergence

            default_timeout, default_poll = convergence_settings()
            timeout = timeout_seconds if timeout_seconds is not None else default_timeout
            poll = poll_seconds if poll_seconds is not None else default_poll
            outcomes = watch_convergence(client, submitted, timeout_seconds=timeout, poll_seconds=poll)
            submitted = [outcome.ref for outcome in outcomes]
            convergence = [outcome.report() for outcome in outcomes]

        payload: dict[str, Any] = {
            "submitted": [ref.model_dump(mode="json") for ref in submitted],
        }
        if convergence:
            payload["convergence"] = convergence
        return payload
    except DeploymentTransactionError as exc:
        # A failed transaction is never reported as submitted; the audit
        # trail records the refusal naming the failed phase (and survivors).
        reason = str(exc)
        if exc.survivors:
            reason += f"; survivors={len(exc.survivors)}"
        _audit("refuse", envelope.context, resources=None, reason=reason)
        raise
    finally:
        if owns_client:
            client.close()
