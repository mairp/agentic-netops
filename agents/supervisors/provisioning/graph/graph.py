"""The provisioning supervisor graph — LangGraph, six nodes, with the
Phase 3 (US2) safety layer.

Ported in shape from the subject's ``graph/graph.py`` (nodes
``supervisor``, ``mapper``, ``allocator``, ``deployer``, ``reflection``,
``general_info``; entry ``supervisor``; conditional routing on
``state["next_node"]``; ``MAX_ITERATIONS = 3`` plus a wall-clock
deadline, FR-004), extended exactly as plan.md §2 specifies and with the
US2 guardrails this phase implements:

* **T085/T089** — the three-way :class:`RequestClassification` classifier
  is wired into ``_supervisor_node`` (provisionable → mapper,
  informational → general_info, unsupported → refusal).
* **T090** — a deterministic direct-device keyword layer refuses any
  request to act directly on a device BEFORE any model call (FR-027:
  "must hold from the first line of code").
* **T091** — every refusal names a supported declarative equivalent.
* **T092** — refusal status transitions (table below); a refusal always
  ends the thread in ``FAILED`` and routes to ``END`` — a refusal is
  terminal and changes nothing.
* **T093–T095** — per-request nonces fence all user text and all
  worker-returned text as data (FR-028).
* **T096–T102** — worker results are extracted DataPart-first with a
  marker fallback, validated against ``Interpretation`` /
  ``NormalizedServiceIntent`` (plus ``validate_all_or_nothing`` and the
  stage type-match rule), and out-of-contract payloads are rejected
  before any further routing (FR-017, FR-012).
* **T124/T125** — the deployer node enforces its submission
  preconditions structurally: ``workflow_status == APPROVED`` AND
  ``confirmation_2.decided == "confirm"``. A routing mistake cannot
  submit: without both, the deployer refuses, touches no worker, and
  holds no cluster client.

Refusal / decline status transitions (T092 — the closed set of
data-model.md §8 is never extended):

    RECEIVED_REQUEST ── refuse (direct device / unsupported / redirect) ──► FAILED
    MAPPED           ── refuse (out-of-contract payload / unsupported properties) ► FAILED
    MAPPED           ── decline (confirmation_1) ───────────────────────► FAILED
    ALLOCATED        ── refuse (out-of-contract payload) ────────────────► FAILED
    ALLOCATED        ── decline (confirmation_2; claims released, FR-007) ► FAILED
    ALLOCATED        ── refuse (deployer preconditions T124/T125) ───────► FAILED

Confirmation transitions (carried forward, FR-006):

    RECEIVED_REQUEST ► MAPPED (mapper validated) ► ALLOCATED (allocator
    validated) ► APPROVED (confirmation_2) ► PROVISIONING (submission
    report) — each step requires the recorded decision.

Audit (FR-030, T103–T105): every confirmation, decline, submission, and
refusal emits an :class:`AuditEvent` through ``common/audit.py``.
"""

from __future__ import annotations

import asyncio
import json
import logging
import os
import re
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from typing import Annotated, Any, Literal, Protocol

import aiosqlite
from a2a.types import DataPart, TextPart
from langchain_core.messages import AIMessage, HumanMessage, ToolMessage
from langchain_core.prompts import PromptTemplate
from langchain_core.runnables import RunnableConfig
from langgraph.checkpoint.sqlite.aio import AsyncSqliteSaver
from langgraph.graph import END, MessagesState, StateGraph
from langgraph.graph.message import add_messages
from langgraph.graph.state import CompiledStateGraph
from pydantic import ValidationError

from common.audit import build_audit_event, emit_audit_event
from common.errors import provider_unavailable_message
from common.llm import get_llm, set_current_thread_id
from common.metrics import get_metrics
from common.provisioning_states import NetworkProvisioningStatus
from common.redaction import redact, redact_model_response, redact_prompt
from common.schemas.audit import AuditEvent
from common.schemas.interpretation import Interpretation
from common.schemas.normalized_intent import NormalizedServiceIntent
from common.schemas.refs import ResourceRef
from config.config import LLM_MODEL
from supervisors.provisioning.graph.shared import (
    Decision,
    RequestClassification,
    new_request_nonce,
)
from supervisors.provisioning.graph.tools import (
    WorkerUnavailableError,
    call_allocator_agent,
    call_deployer_agent,
    call_mapper_agent,
)
from supervisors.provisioning.prompts.system import (
    CLASSIFIER_PROMPT,
    REFUSAL_EXPLANATION,
    REFUSAL_SUGGESTION_LEAD,
    wrap_user_text,
    wrap_worker_text,
)

logger = logging.getLogger("agentic_netops.provisioning.supervisor.graph")
logging.basicConfig(level=logging.INFO)

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

# Maximum number of supervisor iterations to prevent infinite loops (the
# subject's bound, carried forward; FR-004).
MAX_ITERATIONS = 3

# Wall-clock bound per request (FR-004): expiry is an explicit outcome,
# never a hang.
REQUEST_DEADLINE_SECONDS = float(os.getenv("SUPERVISOR_REQUEST_DEADLINE_SECONDS", "300"))

# SQLite checkpointer path (Decision 5: SQLite on the PVC in-cluster;
# overridable for out-of-cluster runs).
CHECKPOINT_DB_PATH = os.getenv("SUPERVISOR_CHECKPOINT_DB", ":memory:")

# Marker names — the subject's carriage (data-model.md §2: "the DataPart
# is authoritative; the marker is compatibility", Decision 7).
MAPPER_MARKER = "MAPPED_JSON"
ALLOCATOR_MARKER = "DEPLOYMENT_JSON"
DEPLOYER_MARKER = "SUBMISSION_JSON"

# ---------------------------------------------------------------------------
# Node states (the subject's names, kept).
# ---------------------------------------------------------------------------
class NodeStates:
    SUPERVISOR = "supervisor"
    MAPPER = "mapper"
    ALLOCATOR = "allocator"
    DEPLOYER = "deployer"
    REFLECTION = "reflection"
    GENERAL_INFO = "general_info"


# ---------------------------------------------------------------------------
# T090 — deterministic direct-device keyword layer (FR-027, first line).
#
# Each entry is (pattern, family). The family selects the refusal reason
# and the declarative-equivalent suggestion (T091). This layer runs
# BEFORE the LLM classifier, so a refusal of direct device action does
# not depend on model behavior at all.
# ---------------------------------------------------------------------------
DEVICE_FAMILY_ACCESS = "direct device access (SSH/CLI/console)"
DEVICE_FAMILY_CONFIG = "direct configuration write to a device"
DEVICE_FAMILY_PROTOCOL = "device control protocol (RESTCONF/NETCONF/gNMI)"
DEVICE_FAMILY_ACTION = "direct action on a device"

DIRECT_DEVICE_PATTERNS: list[tuple[re.Pattern[str], str]] = [
    (re.compile(r"\bssh\b"), DEVICE_FAMILY_ACCESS),
    (re.compile(r"\bscp\b"), DEVICE_FAMILY_ACCESS),
    (re.compile(r"\btelnet\b"), DEVICE_FAMILY_ACCESS),
    (re.compile(r"\bconsole port\b"), DEVICE_FAMILY_ACCESS),
    (re.compile(r"\bserial (?:console|port)\b"), DEVICE_FAMILY_ACCESS),
    # Device names carry suffixes in this lab (leaf01, switch-2): the
    # boundary must allow the trailing name, not a bare word.
    (
        re.compile(r"\blog ?(?:in|into) (?:to )?(?:the )?(?:device|switch|node|router|leaf)[a-z0-9-]*\b"),
        DEVICE_FAMILY_ACCESS,
    ),
    (re.compile(r"\bopen ?(?:a )?(?:shell|session) (?:on|to|into|with)\b"), DEVICE_FAMILY_ACCESS),
    (re.compile(r"\bdevice session\b"), DEVICE_FAMILY_ACCESS),
    (re.compile(r"\brun(?:s|ning)? (?:a |the )?(?:command|cli|script) (?:on|at|against|on)"), DEVICE_FAMILY_ACTION),
    (re.compile(r"\bexec(?:ute)?s? (?:a |the |a single )?(?:command|cli|script)\b"), DEVICE_FAMILY_ACTION),
    (re.compile(r"\breboot(?:s|ing)? (?:the )?(?:switch|device|node|leaf|router)[a-z0-9-]*\b"), DEVICE_FAMILY_ACTION),
    (
        re.compile(r"\breload(?:s|ing)? (?:the )?(?:switch|device|node|leaf|router|config)[a-z0-9-]*\b"),
        DEVICE_FAMILY_ACTION,
    ),
    (re.compile(r"\bjust (?:fix|patch|change|update|reboot|reload)\b"), DEVICE_FAMILY_ACTION),
    (
        re.compile(r"\bdirectly (?:on|to|into) (?:the )?(?:device|switch|node|leaf|router)[a-z0-9-]*\b"),
        DEVICE_FAMILY_ACTION,
    ),
    (re.compile(r"\bpush(?:es|ing)? (?:the )?config(?:uration)?\b"), DEVICE_FAMILY_CONFIG),
    (re.compile(r"\bconfig (?:push|write)\b"), DEVICE_FAMILY_CONFIG),
    (
        re.compile(r"\bwrite(?:s|ing)? (?:the )?(?:config|configuration|vlan|interface) (?:to|onto|on)"),
        DEVICE_FAMILY_CONFIG,
    ),
    (re.compile(r"\brestconf\b"), DEVICE_FAMILY_PROTOCOL),
    (re.compile(r"\bnetconf\b"), DEVICE_FAMILY_PROTOCOL),
    (re.compile(r"\bgnmi\b"), DEVICE_FAMILY_PROTOCOL),
    (re.compile(r"\bg?rpc dial\b"), DEVICE_FAMILY_PROTOCOL),
    (re.compile(r"\bsnmpset\b"), DEVICE_FAMILY_PROTOCOL),
    (re.compile(r"\bansible\b"), DEVICE_FAMILY_PROTOCOL),
]

# ---------------------------------------------------------------------------
# T088/FR-012 — unsupported-feature detection (the deterministic half of
# the "unsupported/unsafe" class). Each entry is (pattern, property name,
# reason). The property name is the Go-side literal from
# ``common/schemas/normalized_intent.py::UnsupportedClaims`` — the same
# vocabulary the translator rejects with, so FR-012's "naming the exact
# unsupported properties" and the Go cause agree.
# ---------------------------------------------------------------------------
UNSUPPORTED_FEATURE_PATTERNS: list[tuple[re.Pattern[str], str, str]] = [
    (re.compile(r"\btraffic engineering\b"), "tePolicy", "traffic engineering (TE) policy"),
    (re.compile(r"\bte[- ]policy\b"), "tePolicy", "traffic engineering (TE) policy"),
    (re.compile(r"\bte[- ]path\b"), "tePolicy", "TE explicit path"),
    (re.compile(r"\bpseudowire oam\b"), "pseudowireOAM", "pseudowire OAM"),
    (re.compile(r"\bpw oam\b"), "pseudowireOAM", "pseudowire OAM"),
    (re.compile(r"\bcontrol word\b"), "pseudowireOAM", "pseudowire control word"),
    (re.compile(r"\bmulticast\b"), "multicastVPN", "multicast VPN"),
    (re.compile(r"\bpim\b"), "multicastVPN", "PIM multicast"),
    (re.compile(r"\bmsdp\b"), "multicastVPN", "MSDP peering"),
    (re.compile(r"\bservice chain\w*"), "serviceChain", "service chaining"),
    (re.compile(r"\bchained services?\b"), "serviceChain", "chained services"),
    (re.compile(r"\bcomplex qos\b"), "complexQoS", "complex QoS"),
]

# ---------------------------------------------------------------------------
# T091 — supported declarative-equivalent suggestions for refusals.
# ---------------------------------------------------------------------------
DEFAULT_SUGGESTION = (
    "provision it declaratively instead — e.g. 'provision a point-to-point "
    "1G L2 service (VPWS) between <siteA> <portA> and <siteB> <portB> for "
    "tenant <tenant>'. I will map it into an interpretation, allocate from "
    "the allocation authority, and submit it to the cluster only after your "
    "two explicit confirmations."
)
# FR-010 companion (live finding, 2026-09-04): a clarification that only
# names the missing fields invites an equally vague restatement ("provision
# a mac vrf across all leafs" -> same clarification loop). Name the accepted
# vocabulary and a worked example so the restatement is mappable.
CLARIFICATION_HINT = (
    " Service types: VPLS (full-mesh L2), VPWS (point-to-point L2 / E-Line), "
    "L3VPN, IRB (integrated L2+L3) — each between two named attachment "
    "points for one named tenant. Example: 'Create a VPWS between leaf01 "
    "ethernet1 and leaf02 ethernet2 for tenant acme'."
)

def clarification_prompt(missing_fields: list[str] | None) -> str:
    """The single operator-facing clarification text (FR-010).

    Built here and reused by the NDJSON surface, so the wording cannot drift
    into two near-identical paragraphs rendered back to back — which is what
    the operator saw before (one from the stream's clarification_request, one
    from this node's AIMessage).
    """

    fields = ", ".join(str(f) for f in (missing_fields or [])) or "required service fields"
    return (
        f"Before I can map this service I need: {fields}. Please restate the full "
        "request including those values (no defaults are substituted for "
        "service-defining fields)."
        f"{CLARIFICATION_HINT}"
    )


def redact_unsupplied(interpretation: dict, missing_fields: list[str] | None) -> dict:
    """Blank every field the operator did not actually supply.

    ``Interpretation`` requires service_type/tenant/endpoints, so the mapper
    has to fill them to produce a schema-valid object even when they are
    exactly what is missing. tenant and endpoints get an obvious ``"missing"``
    placeholder, but service_type is an enum with no sentinel available, so it
    gets a real, plausible value (VPWS) that the operator never asked for —
    displayed next to "no defaults are substituted for service-defining
    fields". Nothing downstream may carry that: a value nobody supplied is
    reported as absent, not as a choice.
    """

    redacted = dict(interpretation)
    for field in missing_fields or []:
        if field in redacted:
            redacted[field] = None
    return redacted


DEVICE_FAMILY_SUGGESTIONS: dict[str, str] = {
    DEVICE_FAMILY_ACCESS: (
        "describe the service you want on that device and I will provision it "
        "declaratively — e.g. 'provision a VPLS/VPWS/L3VPN service between "
        "<siteA> <portA> and <siteB> <portB> for tenant <tenant>'. The control "
        "plane reconciles the devices; no one logs in for you or on your behalf."
    ),
    DEVICE_FAMILY_CONFIG: (
        "state the desired service state instead of the configuration write — "
        "e.g. 'provision a point-to-point 1G L2 service between <siteA> <portA> "
        "and <siteB> <portB> for tenant <tenant>'. The fabric controllers apply "
        "the resulting configuration through reconciliation."
    ),
    DEVICE_FAMILY_PROTOCOL: (
        "name the service, not the protocol — e.g. 'provision an L3VPN between "
        "<siteA> and <siteB> for tenant <tenant>'. This tier expresses services "
        "as declarative intent only; device protocols are the control plane's "
        "business."
    ),
    DEVICE_FAMILY_ACTION: (
        "state the desired outcome as a service request — e.g. 'provision a "
        "VPWS between <siteA> <portA> and <siteB> <portB> for tenant <tenant>'."
    ),
}
UNSUPPORTED_PROPERTY_SUGGESTIONS: dict[str, str] = {
    "tePolicy": (
        "provision the same endpoints as a plain VPLS/VPWS/L3VPN — traffic "
        "engineering is not expressible in this fabric, but the service itself "
        "is provisionable without it."
    ),
    "pseudowireOAM": (
        "provision the pseudowire as a VPWS without OAM — the fabric delivers "
        "the L2 service; OAM signaling is not part of the contract."
    ),
    "multicastVPN": (
        "provision the unicast services your multicast use case needs (L3VPN "
        "or VPLS between the relevant endpoints) — multicast is not supported."
    ),
    "serviceChain": (
        "provision the individual services as separate declarative requests — "
        "chaining is not expressible in this fabric."
    ),
    "complexQoS": (
        "provision the service with a standard SLA class — complex QoS "
        "engineering is not part of the contract."
    ),
}

# Confirmation vocabulary (the subject's text-driven flow, carried forward).
CONFIRM_WORDS = ("yes", "confirm", "proceed", "go ahead", "ok", "sure", "allocate", "deploy")
DECLINE_WORDS = ("no", "decline", "reject", "cancel", "stop", "abort")


@dataclass(frozen=True)
class DetectionHit:
    """One deterministic safety-layer match."""

    family: str  # device family or "unsupported_property"
    reason: str  # the operator-readable reason named in the refusal
    suggestion: str  # the supported declarative equivalent (T091)


# ---------------------------------------------------------------------------
# Graph state (data-model.md §9 + the US2 additions).
#
# Carried forward verbatim from the subject: messages (with the
# ToolMessage-filtering reducer), next_node, full_response,
# iteration_count, awaiting_confirmation, mapped_parameters,
# allocated_resources, missing_fields, pending_action.
#
# Feature-002 additions per data-model.md §9: correlation_id,
# workflow_status, claimed_ids, deadline.
#
# US2 audit additions (required by FR-030/T105 and T125): principal,
# confirmation_1, confirmation_2 (data-model.md §1 Decision records,
# stored JSON-serialized for the checkpointer), plus refusal_reason and
# suggestion so the refusal outcome is inspectable in state, and
# classification (the classifier's decision, for observability).
# ---------------------------------------------------------------------------
def filter_tool_messages(messages: list) -> list:
    """Filter out ToolMessage objects (the subject's helper, kept)."""
    return [msg for msg in messages if not isinstance(msg, ToolMessage)]


def filter_messages_reducer(left: list, right: list) -> list:
    """Custom message reducer: add_messages, then strip ToolMessages
    (the subject's behaviour, kept — prevents 'tool without tool_calls'
    errors across graph runs)."""
    merged = add_messages(left, right)
    return filter_tool_messages(merged)


class GraphState(MessagesState):
    """Runtime state of the provisioning graph (data-model.md §9)."""

    messages: Annotated[list, filter_messages_reducer]
    next_node: str | None = ""
    full_response: str = ""
    iteration_count: int = 0
    awaiting_confirmation: bool = False
    mapped_parameters: str | None = None
    allocated_resources: str | None = None
    missing_fields: list[str] | None = None
    pending_action: str | None = None

    # --- feature 002 (data-model.md §9) ---
    correlation_id: str = ""
    workflow_status: str = NetworkProvisioningStatus.RECEIVED_REQUEST.value
    claimed_ids: list[dict] = []
    deadline: str = ""

    # --- US2 audit additions (FR-030/T105, T125) ---
    principal: str = "operator"
    confirmation_1: dict | None = None
    confirmation_2: dict | None = None
    refusal_reason: str | None = None
    suggestion: str | None = None
    classification: str | None = None

    # --- US1 tools/routing additions (status/remove) ---
    tool_action: str | None = None  # "status" | "remove"
    tool_request: str | None = None  # canonical JSON of the tool request
    tool_result: str | None = None   # canonical JSON of the tool result

    # --- final-outcome additions ---
    # The deployer's per-resource convergence observations (canonical JSON of
    # the report list) and the submitted refs, kept on the thread so a later
    # status question can resolve the same transaction instead of starting a
    # fresh one.
    convergence: str | None = None
    submitted_resources: str | None = None
    # The correlation id of the transaction that submitted them. This is NOT
    # state["correlation_id"]: the HTTP surface mints a fresh correlation id
    # per request, so by the time the operator asks "did it deploy?" the
    # thread's current id labels nothing on the cluster. The label the
    # submitted objects actually carry is the submitting request's id, and it
    # is the only selector that finds them again.
    submitted_correlation_id: str | None = None


# ---------------------------------------------------------------------------
# Deterministic safety-layer detectors (pure functions — used by
# _supervisor_node, the adversarial runner, and the unit tests).
# ---------------------------------------------------------------------------
def detect_direct_device(text: str) -> DetectionHit | None:
    """T090 — scan for direct-device action keywords.

    Returns a :class:`DetectionHit` (reason + declarative-equivalent
    suggestion) for the first matching family, else None.
    """
    if not text:
        return None
    low = text.lower()
    families: list[str] = []
    for pattern, family in DIRECT_DEVICE_PATTERNS:
        if pattern.search(low) and family not in families:
            families.append(family)
    if not families:
        return None
    family = families[0]
    return DetectionHit(
        family=family,
        reason=f"the request asks for {family}",
        suggestion=DEVICE_FAMILY_SUGGESTIONS.get(family, DEFAULT_SUGGESTION),
    )


# A question about the outcome of *this thread's* deployment. It is answered
# by resolving the submitted resources' live conditions, never by the fixed
# capability blurb — "the current status of this request thread is
# PROVISIONING" is not an answer to "did it deploy?".
_DEPLOYMENT_STATUS_QUERY = re.compile(
    r"(?:"
    r"status of (?:the |my |this |our )?(?:deployment|deploy|provisioning|service|network|request)"
    r"|(?:deployment|provisioning|service|network) status"
    r"|what(?:'s| is| was) the status"
    r"|(?:did|has) (?:it|the deployment|the service|the network) (?:deploy|converge|complete)"
    r"|is (?:it|the deployment|the service|the network) (?:deployed|ready|up|converged|done|live)"
    r"|(?:did|has) it (?:deployed|worked|succeeded)"
    r")",
)


def detect_deployment_status_query(text: str) -> bool:
    """True when the operator is asking for the outcome of a deployment."""

    return _DEPLOYMENT_STATUS_QUERY.search(text.lower()) is not None


def detect_provisioning_request(text: str) -> bool:
    """True for an explicit create/deploy request naming a supported service.

    A request can describe its desired follow-up (for example, "after approval,
    check deployment status").  The follow-up must not hijack the primary
    create operation merely because it contains a status-query phrase.
    """

    return bool(_FALLBACK_PROVISION_ACTION.search(text) and _FALLBACK_SERVICE_TYPE.search(text))


def detect_unsupported_feature(text: str) -> DetectionHit | None:
    """FR-012/T088 — scan for constructs with no fabric equivalent.

    Returns a :class:`DetectionHit` whose ``family`` is the property name
    (the Go-side literal) so the refusal NAMES the exact unsupported
    property (SC-003), else None.
    """
    if not text:
        return None
    low = text.lower()
    for pattern, property_name, reason in UNSUPPORTED_FEATURE_PATTERNS:
        if pattern.search(low):
            return DetectionHit(
                family=property_name,
                reason=f"unsupported property: {property_name} ({reason}) has no equivalent in the fabric",
                suggestion=UNSUPPORTED_PROPERTY_SUGGESTIONS.get(property_name, DEFAULT_SUGGESTION),
            )
    return None


# ---------------------------------------------------------------------------
# Worker-result extraction (T096–T099) and validation (T100–T102).
# ---------------------------------------------------------------------------
def _iter_worker_parts(result: Any, worker: str = "worker"):
    """Yield ``("data", dict)`` / ``("text", str)`` for every part of a
    worker response, regardless of the response wrapper (JSON-RPC
    success/error envelope, bare Message, dict, or plain string).

    The DataPart is the authoritative channel (Decision 7); the text
    part carries the human summary plus the compatibility marker.
    """
    obj = result
    # JSON-RPC envelope: result.root is the success/error union.
    if hasattr(obj, "root") and not hasattr(obj, "parts") and not isinstance(obj, (dict, str)):
        root = obj.root
        err = getattr(root, "error", None)
        if err is not None:
            code = getattr(err, "code", None)
            msg = getattr(err, "message", "unknown error")
            raise WorkerUnavailableError(worker, cause=RuntimeError(f"A2A JSON-RPC error (code={code}): {msg}"))
        if hasattr(root, "result"):
            obj = root.result
    if hasattr(obj, "parts"):
        for part in obj.parts:
            inner = part.root if hasattr(part, "root") else part
            if isinstance(inner, DataPart):
                yield ("data", inner.data)
            elif isinstance(inner, TextPart):
                yield ("text", inner.text)
    elif isinstance(obj, dict):
        if isinstance(obj.get("parts"), list):
            for part in obj["parts"]:
                if isinstance(part, dict):
                    if "data" in part and isinstance(part["data"], dict):
                        yield ("data", part["data"])
                    if "text" in part and isinstance(part["text"], str):
                        yield ("text", part["text"])
        else:
            yield ("data", obj)
    elif isinstance(obj, str):
        yield ("text", obj)


def extract_payload_and_text(result: Any, marker: str, worker: str = "worker") -> tuple[dict | None, str]:
    """T096/T097/T098/T099 — extract the structured payload + text from a
    worker response.

    * **DataPart-first** (T096 for the mapper, T098 for the allocator):
      if any part is a ``DataPart``, its ``data`` dict is the payload —
      the authoritative channel (Decision 7).
    * **Marker fallback** (T097/T099): with no DataPart, the payload is
      parsed from the ``<!-- {marker}: {json} -->`` comment in the text.
      A malformed marker JSON is a payload-level failure (returned as
      ``None`` with the raw text) and is rejected by the caller as
      out-of-contract (T102).
    """
    data_payload: dict | None = None
    texts: list[str] = []
    for kind, value in _iter_worker_parts(result, worker):
        if kind == "data" and data_payload is None:
            data_payload = value  # DataPart first — authoritative
        elif kind == "text":
            texts.append(value)
    text = "\n".join(texts)
    if data_payload is not None:
        return data_payload, text
    m = re.search(rf"<!--\s*{marker}\s*:\s*(.*?)-->", text, re.DOTALL)
    if m:
        try:
            parsed = json.loads(m.group(1).strip())
            if isinstance(parsed, dict):
                return parsed, text
        except json.JSONDecodeError:
            return None, text  # malformed marker -> out-of-contract (T102)
    return None, text


def _format_validation_error(exc: ValidationError) -> str:
    """Operator-readable cause list (FR-034: the failure names the
    responsible stage and the specific problems)."""
    causes = []
    for err in exc.errors():
        loc = ".".join(str(p) for p in err.get("loc", ())) or "payload"
        causes.append(f"{loc}: {err.get('msg', 'invalid')}")
    return "; ".join(causes[:8])


def validate_mapper_payload(payload: dict | None) -> tuple[Interpretation | None, str | None]:
    """T100/T102 — validate a mapper payload against ``Interpretation``.

    Returns ``(interpretation, None)`` on success or ``(None, error)`` —
    the error is the operator-readable cause list. A ``None`` payload
    (no DataPart, no usable marker) is out-of-contract too.
    """
    if payload is None:
        return None, "no structured payload found (neither a DataPart nor a well-formed MAPPED_JSON marker)"
    try:
        return Interpretation.model_validate(payload), None
    except ValidationError as exc:
        return None, _format_validation_error(exc)


def validate_allocator_payload(
    payload: dict | None, interpretation: Interpretation
) -> tuple[NormalizedServiceIntent | None, str | None]:
    """T101/T102 — validate an allocator payload against
    ``NormalizedServiceIntent`` (schema + ``validate_all_or_nothing`` +
    the stage type-match rule of data-model.md §3).
    """
    if payload is None:
        return None, "no structured payload found (neither a DataPart nor a well-formed DEPLOYMENT_JSON marker)"
    try:
        intent = NormalizedServiceIntent.model_validate(payload)
    except ValidationError as exc:
        return None, _format_validation_error(exc)
    verr = intent.validate_all_or_nothing()
    if verr is not None:
        return None, str(verr)
    # The interpretation's service_type is already the folded construct
    # (US1): the stage type-match rule of data-model.md §3 compares it to the
    # allocator's type verbatim, so a legacy-typed payload from a compromised
    # or broken allocator cannot slip through on an alias.
    expected_type = interpretation.service_type.value
    if intent.type != expected_type:
        return None, (
            f"type mismatch between stages: interpretation service_type="
            f"{interpretation.service_type.value}, allocator returned type={intent.type!r} "
            "(data-model.md §3 contract violation)"
        )
    return intent, None


# ---------------------------------------------------------------------------
# Worker transport — injectable seam (default: A2A over SLIM via tools.py;
# tests/corpus harnesses inject stubs).
# ---------------------------------------------------------------------------
class WorkerTransport(Protocol):
    async def call_mapper(self, text: str) -> Any: ...

    async def call_allocator(self, text: str) -> Any: ...

    async def call_deployer(self, text: str) -> Any: ...


class A2AWorkerTransport:
    """The production transport: A2A over SLIM (tools.py, hard-require)."""

    async def call_mapper(self, text: str) -> Any:
        return await call_mapper_agent(text)

    async def call_allocator(self, text: str) -> Any:
        return await call_allocator_agent(text)

    async def call_deployer(self, text: str) -> Any:
        return await call_deployer_agent(text)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
# How a resolved cluster phase (deployer.get_service_status) maps onto the
# closed status vocabulary. "Unknown" is deliberately absent: an unreadable
# cluster must not overwrite what the thread already knows.
_STATUS_PHASE_TO_WORKFLOW = {
    "Deployed": NetworkProvisioningStatus.COMPLETED,
    "Failed": NetworkProvisioningStatus.FAILED,
    "Converging": NetworkProvisioningStatus.PROVISIONING,
    "NotFound": NetworkProvisioningStatus.FAILED,
}


def _describe_convergence(observations: list[dict]) -> str:
    """Render convergence observations as operator-readable text.

    The deployer's ``detail`` is the controller's own condition message
    (``ApplySucceeded`` / ``ApplyFailed`` with the real operation output);
    it is quoted, never paraphrased.

    When an observation carries an ``unverified`` list (T049a), append a
    short note naming the unverified property and node so the operator is
    never shown a property the tier did not observe.
    """

    parts: list[str] = []
    for observation in observations:
        if not isinstance(observation, dict):
            continue
        resource = str(observation.get("resource") or "resource")
        detail = str(observation.get("detail") or "").strip()
        suffix = ""
        unver = observation.get("unverified")
        if isinstance(unver, list) and unver:
            items: list[str] = []
            for it in unver:
                if isinstance(it, dict):
                    prop = str(it.get("property") or "property")
                    node = str(it.get("node") or "node")
                    items.append(f"{prop}@{node}")
            if items:
                suffix = "; unverified: " + ", ".join(items)
        text = resource
        if detail:
            text += f" ({detail}{suffix})"
        elif suffix:
            text += f" ({suffix.lstrip('; ')})"
        parts.append(text)
    return ", ".join(parts) or "no resource named"


def canonical_json(obj: Any) -> str:
    """Canonical serialization (sorted keys, compact) — the byte-identity
    basis of FR-014 and of the corpus byte-identical assertion (T118)."""
    return json.dumps(obj, sort_keys=True, separators=(",", ":"))


def parse_classification(content: str) -> RequestClassification | None:
    """Parse the classifier's reply against the enum (T089).

    Defensive: the model is instructed to reply with exactly one word;
    anything that does not contain a class word (as a standalone token)
    is unparseable and must NOT route to a worker.
    """
    if not content:
        return None
    low = content.strip().lower().strip(".!?\"' ")
    if low in {c.value for c in RequestClassification}:
        return RequestClassification(low)
    # Tolerate one framing sentence; require the class word standalone.
    for cls in RequestClassification:
        if re.search(rf"\b{re.escape(cls.value)}\b", low):
            return cls
    return None


_FALLBACK_INFORMATIONAL = re.compile(
    r"^\s*(?:what|which|who|where|when|why|how|can|could|do|does|is|are|show|list|describe|explain|help)\b",
    re.I,
)
_FALLBACK_PROVISION_ACTION = re.compile(
    r"\b(?:provision|create|set\s*up|deploy|add|need|want)\b",
    re.I,
)
_FALLBACK_SERVICE_TYPE = re.compile(
    r"\b(?:vpws|vpls|l3vpn|irb|e-?line|point[- ]to[- ]point|full[- ]mesh)\b",
    re.I,
)


def fallback_classification(content: str) -> RequestClassification | None:
    """Classify only unambiguous requests when the model is unavailable.

    Safety and unsupported-feature detectors run before this helper. The
    fallback deliberately recognizes a narrow vocabulary and returns ``None``
    for everything else, preserving fail-closed behavior during an outage.
    """
    if _FALLBACK_INFORMATIONAL.search(content):
        return RequestClassification.INFORMATIONAL
    if _FALLBACK_PROVISION_ACTION.search(content) and _FALLBACK_SERVICE_TYPE.search(content):
        return RequestClassification.PROVISIONABLE
    return None


def _failed_or_reflection(state: dict[str, Any]) -> str:
    """T102 route: a worker-stage rejection ends the thread (FAILED → END);
    otherwise the flow continues to reflection."""
    return (
        END
        if state.get("workflow_status") == NetworkProvisioningStatus.FAILED.value
        else NodeStates.REFLECTION
    )


def default_deadline() -> str:
    return (datetime.now(UTC) + timedelta(seconds=REQUEST_DEADLINE_SECONDS)).isoformat()


async def default_checkpointer() -> AsyncSqliteSaver:
    """The SQLite checkpointer (Decision 5 — SQLite on the PVC, not
    ``MemorySaver``). ``SUPERVISOR_CHECKPOINT_DB`` is the mount path in
    cluster and a file path (or ``:memory:``) for out-of-cluster runs.

    The async saver (aiosqlite) backs the graph's ``ainvoke``/``astream``
    path; the same connection instance backs the whole process, so a
    restart resumes the thread from the checkpoint (data-model.md §9,
    Decision 5).
    """
    conn = await aiosqlite.connect(CHECKPOINT_DB_PATH)
    return AsyncSqliteSaver(conn)


# ---------------------------------------------------------------------------
# The graph
# ---------------------------------------------------------------------------
from ioa_observe.sdk.decorators import graph


@graph(name="ProvisioningSupervisorGraph", method_name="build_graph")
class ProvisioningGraph:
    """LangGraph supervisor graph (the subject's shape + the US2 layer).

    ``llm_factory`` / ``transport`` are injectable seams for the test
    harnesses (the adversarial corpus, the unit tests); production uses
    ``common.llm.get_llm`` and the A2A-over-SLIM transport.
    """

    def __init__(
        self,
        llm_factory=None,
        transport: WorkerTransport | None = None,
        checkpointer=None,
    ):
        # The checkpointer is async (aiosqlite), so the compiled graph is
        # built lazily by the async entrypoints (ainvoke/astream) on first
        # use. ``checkpointer`` (injected, e.g. by tests) short-circuits
        # the default SQLite-on-PVC saver.
        self._checkpointer = checkpointer
        self.graph: CompiledStateGraph | None = None
        self._graph_lock = None
        self._llm_factory = llm_factory or get_llm
        self.transport: WorkerTransport = transport or A2AWorkerTransport()
        self.supervisor_llm = None
        self.formatter_llm = None

    async def _compiled_graph(self) -> CompiledStateGraph:
        """Compile on first use (the checkpointer is async)."""
        if self.graph is None:
            if self._checkpointer is None:
                self._checkpointer = await default_checkpointer()
            self.graph = self.build_graph(self._checkpointer)
        return self.graph

    async def close(self) -> None:
        """Release the checkpointer connection (tests, graceful shutdown).

        A long-running supervisor process keeps the connection open for its
        lifetime (uvicorn keeps the process alive regardless); test harnesses
        must call this so the aiosqlite worker thread does not outlive the
        event loop.
        """
        saver = self._checkpointer
        self._checkpointer = None
        self.graph = None
        if saver is None:
            return
        conn = getattr(saver, "conn", None)
        if conn is None:
            return
        try:
            close = conn.close
            if asyncio.iscoroutinefunction(close):
                await close()
            else:
                close()
        except Exception:  # noqa: BLE001 - closing is best-effort
            logger.debug("checkpointer close failed", exc_info=True)

    async def ainvoke(self, seed: dict, config: dict | None = None):
        """Run the graph to completion; returns the final state."""
        g = await self._compiled_graph()
        return await g.ainvoke(seed, config=config)

    async def astream(self, seed: dict, config: dict | None = None):
        """Stream per-node state updates (stream_mode='updates')."""
        g = await self._compiled_graph()
        async for chunk in g.astream(seed, config=config, stream_mode="updates"):
            yield chunk

    # ---------------- graph construction ----------------
    def build_graph(self, checkpointer=None) -> CompiledStateGraph:
        """Constructs and compiles the LangGraph instance.

        Node/edge shape carried forward from the subject (plan.md §2):
        entry ``supervisor``; supervisor routes conditionally to
        mapper/allocator/deployer/general_info — and, new in this phase
        (T092), to ``END`` on a refusal; mapper/allocator route to
        reflection, or to ``END`` when their payload was rejected as
        out-of-contract (T102); deployer routes to reflection or END;
        reflection loops back to supervisor or ends; general_info ends.
        """
        workflow = StateGraph(GraphState)

        workflow.add_node(NodeStates.SUPERVISOR, self._supervisor_node)
        workflow.add_node(NodeStates.MAPPER, self._mapper_node)
        workflow.add_node(NodeStates.ALLOCATOR, self._allocator_node)
        workflow.add_node(NodeStates.DEPLOYER, self._deployer_node)
        workflow.add_node(NodeStates.REFLECTION, self._reflection_node)
        workflow.add_node(NodeStates.GENERAL_INFO, self._general_response_node)

        workflow.set_entry_point(NodeStates.SUPERVISOR)

        # T092: END is a legal supervisor outcome — a refusal is terminal.
        workflow.add_conditional_edges(
            NodeStates.SUPERVISOR,
            lambda state: state["next_node"],
            {
                NodeStates.MAPPER: NodeStates.MAPPER,
                NodeStates.ALLOCATOR: NodeStates.ALLOCATOR,
                NodeStates.DEPLOYER: NodeStates.DEPLOYER,
                NodeStates.GENERAL_INFO: NodeStates.GENERAL_INFO,
                END: END,
            },
        )

        # T102: a rejected mapper/allocator payload ends the thread in
        # FAILED before any further routing.
        workflow.add_conditional_edges(
            NodeStates.MAPPER,
            _failed_or_reflection,
            {NodeStates.REFLECTION: NodeStates.REFLECTION, END: END},
        )
        workflow.add_conditional_edges(
            NodeStates.ALLOCATOR,
            _failed_or_reflection,
            {NodeStates.REFLECTION: NodeStates.REFLECTION, END: END},
        )

        workflow.add_conditional_edges(
            NodeStates.DEPLOYER,
            lambda state: state.get("next_node", NodeStates.REFLECTION),
            {
                NodeStates.REFLECTION: NodeStates.REFLECTION,
                END: END,
            },
        )

        workflow.add_conditional_edges(
            NodeStates.REFLECTION,
            lambda state: state["next_node"],
            {
                NodeStates.SUPERVISOR: NodeStates.SUPERVISOR,
                END: END,
            },
        )

        workflow.add_edge(NodeStates.GENERAL_INFO, END)

        if checkpointer is None:
            raise TypeError("build_graph requires a checkpointer; use _compiled_graph()")
        return workflow.compile(checkpointer=checkpointer)

    # ---------------- audit helper (FR-030, T105) ----------------
    def _audit(
        self,
        state: GraphState,
        config: RunnableConfig,
        event_type: Literal["confirm", "decline", "submit", "refuse"],
        resources: list[ResourceRef] | None = None,
        reason: str | None = None,
    ) -> AuditEvent | None:
        """Emit one audit record (confirm/decline/submit/refuse).

        Every event carries principal, thread id, correlation id,
        resources, and reason (T105). Emission failures are logged, not
        raised — an audit hiccup must not mask the request outcome, but
        the refusal itself is never silenced.
        """
        correlation_id = state.get("correlation_id") or ""
        if not correlation_id:
            correlation_id = new_request_nonce()
            state["correlation_id"] = correlation_id
        thread_id = (config or {}).get("configurable", {}).get("thread_id", "default_session")
        try:
            event = build_audit_event(
                event_type,
                correlation_id=correlation_id,
                thread_id=thread_id,
                principal=state.get("principal") or "operator",
                resources=resources,
                reason=reason,
            )
            return emit_audit_event(event)
        except Exception as exc:  # noqa: BLE001
            logger.error("audit emission failed (%s): %s", event_type, redact(str(exc)))
            return None

    # ---------------- refusal core (T091/T092) ----------------
    def _build_refusal_message(self, reason: str, suggestion: str, correlation_id: str) -> str:
        """The operator-facing refusal text (T091): refusal + explanation
        + the supported declarative equivalent, plus the correlation id
        (FR-034)."""
        return (
            f"I can't do that. {reason}. {REFUSAL_EXPLANATION} "
            f"{REFUSAL_SUGGESTION_LEAD} {suggestion} "
            f"(correlation id: {correlation_id})"
        )

    def _refuse(self, state: GraphState, config: RunnableConfig, reason: str, suggestion: str, stage: str) -> dict:
        """T092 — the refusal transition: any non-terminal status to
        FAILED, route to END, emit the refuse audit event, and answer
        with the refusal text. Nothing is routed onward, nothing is
        submitted, no worker is called, no cluster client is touched."""
        correlation_id = state.get("correlation_id") or ""
        self._audit(state, config, "refuse", reason=f"{stage}: {reason}")
        logger.warning("refusal at %s: %s", stage, reason)
        return {
            "next_node": END,
            "workflow_status": NetworkProvisioningStatus.FAILED.value,
            "refusal_reason": reason,
            "suggestion": suggestion,
            "awaiting_confirmation": False,
            "pending_action": None,
            "messages": [AIMessage(content=self._build_refusal_message(reason, suggestion, correlation_id))],
        }

    def _reject_out_of_contract(
        self, state: GraphState, config: RunnableConfig, *, stage: str, error: str, worker_text: str = ""
    ) -> dict:
        """T102 — reject an out-of-contract worker payload BEFORE routing.

        FR-017: the failure lands at the agent boundary, is reported
        (FR-034: stage + correlation id named), and nothing is partially
        applied. The refusal audit event records the named causes.
        """
        correlation_id = state.get("correlation_id") or ""
        reason = f"{stage} payload out of contract: {error}"
        self._audit(state, config, "refuse", reason=reason)
        logger.error("out-of-contract %s payload rejected: %s", stage, error)
        content = redact_model_response(
            f"The {stage} stage returned a payload that fails schema validation, so it was "
            f"rejected before any further routing or cluster submission — nothing was applied: "
            f"{error}. (correlation id: {correlation_id})"
        )
        if worker_text:
            content += f"\n[worker summary: {redact_model_response(worker_text)[:400]}]"
        return {
            "next_node": END,
            "workflow_status": NetworkProvisioningStatus.FAILED.value,
            "refusal_reason": reason,
            "suggestion": DEFAULT_SUGGESTION,
            "awaiting_confirmation": False,
            "pending_action": None,
            "messages": [AIMessage(content=content)],
        }

    # ---------------- bounded exit (FR-004) ----------------
    def _deadline_exceeded(self, state: GraphState) -> bool:
        deadline = state.get("deadline")
        if not deadline:
            return False
        try:
            return datetime.fromisoformat(deadline) < datetime.now(UTC)
        except ValueError:
            return False

    def _bounded_exit(self, state: GraphState, config: RunnableConfig, why: str) -> dict:
        """FR-004 — a bounded exit is an explicit outcome, never a hang."""
        correlation_id = state.get("correlation_id") or ""
        reason = f"request bound reached ({why}); no further action taken"
        self._audit(state, config, "refuse", reason=reason)
        return {
            "next_node": END,
            "workflow_status": NetworkProvisioningStatus.FAILED.value,
            "refusal_reason": reason,
            "suggestion": DEFAULT_SUGGESTION,
            "awaiting_confirmation": False,
            "pending_action": None,
            "messages": [
                AIMessage(
                    content=(
                        f"This request hit its bound ({why}) and was stopped without further action. "
                        f"Please rephrase and resend. (correlation id: {correlation_id})"
                    )
                )
            ],
        }

    # ---------------- LLM access ----------------
    def _supervisor_llm(self):
        if not self.supervisor_llm:
            self.supervisor_llm = self._llm_factory(streaming=False)
        return self.supervisor_llm

    async def _classify(self, fenced_user_text: str) -> RequestClassification | None:
        """T089 — the three-way classifier call. The user text arrives
        ALREADY nonce-fenced (T094); the prompt constrains the reply to
        one of the three class words (prompts/system.py)."""
        prompt = PromptTemplate(template=CLASSIFIER_PROMPT, input_variables=["user_message"])
        chain = prompt | self._supervisor_llm()
        response = await chain.ainvoke({"user_message": fenced_user_text})
        return parse_classification(response.content)

    @staticmethod
    def _start_provisioning() -> dict[str, Any]:
        """Start a clean transaction on either a new or reused UI thread."""

        return {
            "next_node": NodeStates.MAPPER,
            "classification": RequestClassification.PROVISIONABLE.value,
            "workflow_status": NetworkProvisioningStatus.RECEIVED_REQUEST.value,
            "tool_action": None,
            "tool_request": None,
            "tool_result": None,
            "awaiting_confirmation": False,
            "pending_action": None,
            "mapped_parameters": None,
            "missing_fields": None,
            "allocated_resources": None,
            "submitted_resources": None,
            "submitted_correlation_id": None,
            "convergence": None,
            "claimed_ids": [],
            "confirmation_1": None,
            "confirmation_2": None,
            "refusal_reason": None,
            "suggestion": None,
        }

    # ---------------- nodes ----------------
    async def _supervisor_node(self, state: GraphState, config: RunnableConfig) -> dict:
        """Determines the intent of the user's message and routes to the
        appropriate node — with the US2 safety layer in front of any
        model call (T090 first line, T089 classifier, T092 refusals)."""
        # FR-004 bounded exit: deadline and iteration cap.
        if self._deadline_exceeded(state):
            return self._bounded_exit(state, config, "wall-clock deadline exceeded")
        if not state.get("awaiting_confirmation") and state.get("iteration_count", 0) >= MAX_ITERATIONS:
            return self._bounded_exit(state, config, f"iteration bound {MAX_ITERATIONS} reached")

        user_message = next((m for m in reversed(state["messages"]) if isinstance(m, HumanMessage)), None)
        if not user_message:
            return {"next_node": NodeStates.GENERAL_INFO}
        # Metrics: count received requests at supervisor stage
        try:
            get_metrics().inc_stage_request("supervisor")
        except Exception:
            pass

        user_content = user_message.content
        user_content_l = user_content.lower().strip()

        # ---------- T256/T257: status-query and remove-service routing -----
        # A status question on a thread that already submitted something is
        # answered from that transaction, by its correlation id — the label
        # every submitted object carries. Without this the question falls
        # through to the general-response node, which can only recite the
        # capability blurb and the thread's last known status.
        submitted_json = state.get("submitted_resources")
        correlation_for_status = state.get("submitted_correlation_id") or ""
        if (
            submitted_json
            and correlation_for_status
            and detect_deployment_status_query(user_content)
            and not detect_provisioning_request(user_content)
        ):
            status_request = {"action": "status", "correlationId": correlation_for_status}
            try:
                allocated = json.loads(state.get("allocated_resources") or "{}")
                service_id = allocated.get("serviceId") if isinstance(allocated, dict) else None
                if service_id:
                    status_request["serviceId"] = str(service_id)
            except (TypeError, ValueError, json.JSONDecodeError):
                pass
            req = canonical_json(status_request)
            logger.info(
                "resolving deployment status for correlation %s from the cluster",
                correlation_for_status[:8],
            )
            return {
                "next_node": NodeStates.DEPLOYER,
                "tool_action": "status",
                "tool_request": req,
                "messages": [],
            }

        # Detect a status query for an existing service id or by correlation id
        m = re.search(r"status of (?:service |)(?P<sid>[a-z0-9-]{6,15})", user_content_l)
        if m:
            sid = m.group("sid")
            req = canonical_json({"action": "status", "serviceId": sid})
            logger.info("routing status query for service %s to deployer tools", sid)
            return {
                "next_node": NodeStates.DEPLOYER,
                "tool_action": "status",
                "tool_request": req,
                "messages": [],
            }
        m = re.search(r"remove (?:service |)(?P<sid>[a-z0-9-]{6,15})", user_content_l)
        if m:
            sid = m.group("sid")
            req = canonical_json({"action": "remove", "serviceId": sid})
            logger.info("routing remove-service for service %s to deployer tools (confirmation required)", sid)
            return {
                "next_node": END,
                "tool_action": "remove",
                "tool_request": req,
                "awaiting_confirmation": True,
                "pending_action": "confirm_remove",
                "messages": [
                    AIMessage(
                        content=(
                            "Remove this service? Reply 'confirm' to delete by correlation id, or 'decline' to cancel."
                        )
                    )
                ],
            }
        m = re.search(r"remove .*?correlation[- ]id[:\s]+(?P<cid>[a-f0-9]{16,32})", user_content_l)
        if m:
            cid = m.group("cid")
            req = canonical_json({"action": "remove", "correlationId": cid})
            logger.info("routing remove-service for correlation %s to deployer tools (confirmation required)", cid[:8])
            return {
                "next_node": END,
                "tool_action": "remove",
                "tool_request": req,
                "awaiting_confirmation": True,
                "pending_action": "confirm_remove",
                "messages": [
                    AIMessage(
                        content=(
                            "Remove this service? Reply 'confirm' to delete by correlation id, or 'decline' to cancel."
                        )
                    )
                ],
            }

        # ---------- confirmation handling (the subject's text-driven
        # flow, graph.py:353-367, carried forward + FR-006 decisions) ----
        awaiting_confirmation = state.get("awaiting_confirmation", False)
        pending_action = state.get("pending_action")

        if awaiting_confirmation and pending_action in ("confirm_1", "confirm_2", "confirm_remove"):
            if any(w in user_content_l for w in CONFIRM_WORDS):
                if pending_action == "confirm_remove":
                    # Remove-service: proceed to deployer tools without submission preconditions
                    self._audit(
                        state,
                        config,
                        "confirm",
                        reason="remove-service recorded: operator confirmed",
                    )
                    logger.info("user confirmed remove-service")
                    return {
                        "next_node": NodeStates.DEPLOYER,
                        "awaiting_confirmation": False,
                        "pending_action": None,
                        "messages": [],
                    }
                which = "confirmation_1" if pending_action == "confirm_1" else "confirmation_2"
                decision = Decision(
                    decided="confirm",
                    at=datetime.now(UTC),
                    principal=state.get("principal") or "operator",
                ).model_dump(mode="json")
                self._audit(
                    state,
                    config,
                    "confirm",
                    reason=f"{which} recorded: operator confirmed",
                )
                logger.info("user confirmed %s", which)
                if pending_action == "confirm_1":
                    # MAPPED -> (allocator runs) -> ALLOCATED
                    return {
                        "next_node": NodeStates.ALLOCATOR,
                        "awaiting_confirmation": False,
                        "pending_action": None,
                        "confirmation_1": decision,
                        "messages": [],
                    }
                # confirm_2: ALLOCATED -> APPROVED (T124 precondition source)
                return {
                    "next_node": NodeStates.DEPLOYER,
                    "awaiting_confirmation": False,
                    "pending_action": None,
                    "confirmation_2": decision,
                    "workflow_status": NetworkProvisioningStatus.APPROVED.value,
                    "messages": [],
                }
            if any(w in user_content_l for w in DECLINE_WORDS):
                if pending_action == "confirm_remove":
                    self._audit(
                        state,
                        config,
                        "decline",
                        reason="remove-service recorded: operator declined",
                    )
                    logger.info("user declined remove-service")
                    return {
                        "next_node": END,
                        "workflow_status": NetworkProvisioningStatus.FAILED.value,
                        "refusal_reason": "remove-service declined by operator",
                        "suggestion": DEFAULT_SUGGESTION,
                        "awaiting_confirmation": False,
                        "pending_action": None,
                        "messages": [
                            AIMessage(
                                content=(
                                    "Understood — the remove-service request was declined and nothing will be done."
                                )
                            )
                        ],
                    }
                which = "confirmation_1" if pending_action == "confirm_1" else "confirmation_2"
                decision = Decision(
                    decided="decline",
                    at=datetime.now(UTC),
                    principal=state.get("principal") or "operator",
                ).model_dump(mode="json")
                # FR-007: release the claims on decline (SC-014).
                released = []
                for claim in state.get("claimed_ids") or []:
                    c = dict(claim)
                    c["released_at"] = datetime.now(UTC).isoformat()
                    released.append(c)
                self._audit(
                    state,
                    config,
                    "decline",
                    reason=f"{which} recorded: operator declined; claims released",
                )
                logger.info("user declined %s", which)
                return {
                    "next_node": END,
                    "workflow_status": NetworkProvisioningStatus.FAILED.value,
                    "refusal_reason": f"{which} declined by operator",
                    "suggestion": DEFAULT_SUGGESTION,
                    "awaiting_confirmation": False,
                    "pending_action": None,
                    "claimed_ids": released,
                    "confirmation_1": decision if pending_action == "confirm_1" else state.get("confirmation_1"),
                    "confirmation_2": decision if pending_action == "confirm_2" else state.get("confirmation_2"),
                    "messages": [
                        AIMessage(
                            content=(
                                f"Understood — the request was declined at {which} and nothing will be "
                                "submitted. Any claimed identifiers were released. If you want to change "
                                "something, start a fresh request."
                            )
                        )
                    ],
                }
            # Neither confirm nor decline: re-ask (the thread stays alive).
            return {
                "next_node": END,
                "awaiting_confirmation": True,
                "messages": [
                    AIMessage(
                        content="Please answer with 'confirm' to proceed or 'decline' to cancel this request."
                    )
                ],
            }

        if awaiting_confirmation and pending_action == "clarify":
            # FR-010: the operator restated the request with the missing
            # fields — classify the restatement fresh.
            routed = await self._classify_and_route(state, config, user_content)
            routed["awaiting_confirmation"] = False
            routed["pending_action"] = None
            return routed

        # ---------- T090: deterministic direct-device refusal FIRST ------
        hit = detect_direct_device(user_content)
        if hit is not None:
            try:
                get_metrics().inc_refused_unsafe()
            except Exception:
                pass
            return self._refuse(state, config, hit.reason, hit.suggestion, stage="supervisor")

        # ---------- T088/FR-012: unsupported-feature refusal -------------
        hit = detect_unsupported_feature(user_content)
        if hit is not None:
            try:
                get_metrics().inc_refused_unsafe()
            except Exception:
                pass
            return self._refuse(state, config, hit.reason, hit.suggestion, stage="supervisor")

        # A mixed create + future-status request has an unambiguous primary
        # action. Run this narrow case after the safety/unsupported guards but
        # before the model classifier, whose informational bias toward the
        # trailing status phrase must not suppress provisioning. Ordinary
        # provisioning requests continue through the classifier as designed.
        if detect_provisioning_request(user_content) and detect_deployment_status_query(user_content):
            logger.info("supervisor recognized mixed provisioning and status-follow-up request")
            return self._start_provisioning()

        # ---------- T089: the three-way LLM classifier -------------------
        return await self._classify_and_route(state, config, user_content)

    async def _classify_and_route(self, state: GraphState, config: RunnableConfig, user_content: str) -> dict:
        """T089 — run the classifier on the nonce-fenced user text and
        route: provisionable -> mapper, informational -> general_info,
        unsupported -> refusal. An unparseable or failed classification
        never routes to a worker (it falls back to general_info).

        T414 — ensure the per-conversation token budget is keyed to the
        LangGraph conversation thread_id. We set the current thread id on
        entry so common.llm tracks tokens against this conversation, not
        the Python OS thread.
        """
        try:
            thread_id = (config or {}).get("configurable", {}).get("thread_id", "default_session")
            set_current_thread_id(thread_id)
        except Exception:
            pass
        nonce = new_request_nonce()
        fenced = wrap_user_text(redact_prompt(user_content), nonce)
        try:
            classification = await self._classify(fenced)
        except Exception as exc:  # noqa: BLE001
            logger.error("classifier (model) unavailable: %s", redact(str(exc)))
            classification = fallback_classification(user_content)
            if classification is RequestClassification.PROVISIONABLE:
                logger.warning("using deterministic provisionable classification while model is unavailable")
                return self._start_provisioning()
            if classification is RequestClassification.INFORMATIONAL:
                logger.warning("using deterministic informational classification while model is unavailable")
                return {
                    "next_node": NodeStates.GENERAL_INFO,
                    "classification": classification.value,
                }
            provider_label = LLM_MODEL.partition("/")[0] or "LLM"
            reason = provider_unavailable_message(provider_label)
            return {
                "next_node": END,
                "classification": None,
                "workflow_status": NetworkProvisioningStatus.FAILED.value,
                "refusal_reason": reason,
                "suggestion": "Configure the llm-provider Secret and retry the request.",
                "messages": [
                    AIMessage(content=reason)
                ],
            }
        if classification is RequestClassification.PROVISIONABLE:
            logger.info("supervisor classified request as provisionable")
            return self._start_provisioning()
        if classification is RequestClassification.INFORMATIONAL:
            logger.info("supervisor classified request as informational")
            return {"next_node": NodeStates.GENERAL_INFO, "classification": classification.value}
        if classification is RequestClassification.UNSUPPORTED:
            reason = "the request is outside the declarative service contract (classifier: unsupported/unsafe)"
            return self._refuse(state, config, reason, DEFAULT_SUGGESTION, stage="supervisor")
        # Unparseable: never route to a worker.
        logger.warning("unparseable classifier reply; falling back to general_info")
        return {
            "next_node": NodeStates.GENERAL_INFO,
            "classification": None,
            "messages": [
                AIMessage(
                    content="I could not classify that request. Please rephrase it as a service request "
                    "(type, the two endpoints, and the tenant) or as a question."
                )
            ],
        }

    async def _mapper_node(self, state: GraphState, config: RunnableConfig) -> dict:
        """Calls the mapper worker and validates the interpretation
        BEFORE routing onward (T096/T097/T100/T102)."""
        user_message = next((m for m in reversed(state["messages"]) if isinstance(m, HumanMessage)), None)
        if not user_message:
            return self._reject_out_of_contract(
                state, config, stage="mapper", error="no user message to map",
            )
        user_content = user_message.content

        nonce = new_request_nonce()
        fenced = wrap_user_text(redact_prompt(user_content), nonce)  # T094
        logger.info("[Mapper] calling mapper worker (fenced user text, nonce=%s)", nonce[:8])
        try:
            result = await self.transport.call_mapper(fenced)
        except WorkerUnavailableError as exc:
            # FR-026: name the unavailable worker, keep the thread resumable
            # (status is NOT terminal — the operator can retry).
            logger.warning("mapper unavailable: %s", exc)
            return {
                "next_node": END,
                "messages": [
                    AIMessage(
                        content=(
                            "The mapper worker is currently unavailable, so the request was not processed "
                            "(nothing was submitted). Please try again in a moment — your thread is kept."
                        )
                    )
                ],
            }

        payload, worker_text = extract_payload_and_text(result, MAPPER_MARKER, "mapper")  # T096/T097
        if payload is None:
            # Diagnostics: the reply arrived but carried no contract payload.
            try:
                dump = result.model_dump(mode="json", by_alias=True) if hasattr(result, "model_dump") else repr(result)
                logger.error(
                    "[Mapper] out-of-contract reply diagnostic: type=%s dump=%s",
                    type(result).__name__,
                    str(dump)[:800],
                )
            except Exception as diag_exc:  # noqa: BLE001
                logger.error("[Mapper] out-of-contract reply diagnostic failed: %s", diag_exc)
        interpretation, error = validate_mapper_payload(payload)  # T100/T102
        if error is not None or interpretation is None:
            try:
                get_metrics().record_stage_result(stage="mapper", success=False)
            except Exception:
                pass
            return self._reject_out_of_contract(
                state, config, stage="mapper", error=error or "payload is not an object", worker_text=worker_text
            )

        # FR-012: unsupported properties -> refusal naming them, NO
        # partial assignment (SC-003).
        if interpretation.unsupported_properties:
            props = ", ".join(interpretation.unsupported_properties)
            return self._refuse(
                state,
                config,
                f"unsupported properties: {props} (no equivalent in the fabric)",
                DEFAULT_SUGGESTION,
                stage="mapper",
            )

        # FR-010: missing fields -> clarification request, not an
        # interpretation; the supervisor must not route to the allocator.
        if interpretation.missing_fields:
            return {
                "next_node": END,
                "workflow_status": NetworkProvisioningStatus.MAPPED.value,
                # Redacted: the mapper's schema-validity placeholders are not
                # the operator's choices and must not be carried as if they were.
                "mapped_parameters": canonical_json(
                    redact_unsupplied(
                        interpretation.model_dump(mode="json"), interpretation.missing_fields
                    )
                ),
                "missing_fields": list(interpretation.missing_fields),
                "awaiting_confirmation": True,
                "pending_action": "clarify",
                "messages": [AIMessage(content=clarification_prompt(interpretation.missing_fields))],
            }

        # Complete, valid interpretation -> first confirmation point.
        summary = redact_model_response(worker_text.split("<!--")[0].strip()) or "Interpretation ready."
        try:
            get_metrics().record_stage_result(stage="mapper", success=True)
        except Exception:
            pass
        return {
            "next_node": NodeStates.REFLECTION,
            "workflow_status": NetworkProvisioningStatus.MAPPED.value,
            "mapped_parameters": canonical_json(interpretation.model_dump(mode="json")),
            "awaiting_confirmation": True,
            "pending_action": "confirm_1",
            "messages": [AIMessage(content=summary)],
        }

    async def _allocator_node(self, state: GraphState, config: RunnableConfig) -> dict:
        """Calls the allocator worker with the (validated) interpretation
        and validates the normalized intent BEFORE routing onward
        (T098/T099/T101/T102)."""
        mapped = state.get("mapped_parameters")
        if not mapped:
            return self._reject_out_of_contract(
                state, config, stage="allocator", error="no interpretation available to allocate",
            )
        try:
            interpretation = Interpretation.model_validate_json(mapped)
        except ValidationError as exc:
            return self._reject_out_of_contract(
                state,
                config,
                stage="allocator",
                error=f"stored interpretation invalid: {_format_validation_error(exc)}",
            )

        nonce = new_request_nonce()
        fenced = wrap_worker_text(redact_prompt(mapped), nonce)  # T095: worker-returned text
        logger.info("[Allocator] calling allocator worker (fenced interpretation, nonce=%s)", nonce[:8])
        try:
            result = await self.transport.call_allocator(fenced)
        except WorkerUnavailableError as exc:
            logger.warning("allocator unavailable: %s", exc)
            return {
                "next_node": END,
                "messages": [
                    AIMessage(
                        content=(
                            "The allocator worker is currently unavailable, so no identifiers were "
                            "allocated and nothing was submitted. Please confirm again to retry — your "
                            "thread is kept."
                        )
                    )
                ],
            }

        payload, worker_text = extract_payload_and_text(result, ALLOCATOR_MARKER, "allocator")  # T098/T099
        intent, error = validate_allocator_payload(payload, interpretation)  # T101/T102
        if error is not None or intent is None:
            try:
                get_metrics().record_stage_result(stage="allocator", success=False)
            except Exception:
                pass
            return self._reject_out_of_contract(
                state, config, stage="allocator", error=error or "payload is not an object", worker_text=worker_text
            )

        summary = redact_model_response(worker_text.split("<!--")[0].strip()) or "Allocation ready."
        try:
            get_metrics().record_stage_result(stage="allocator", success=True)
        except Exception:
            pass
        return {
            "next_node": NodeStates.REFLECTION,
            "workflow_status": NetworkProvisioningStatus.ALLOCATED.value,
            "allocated_resources": canonical_json(intent.model_dump(mode="json")),
            # FR-014 determinism: memoize on the interpretation hash.
            "awaiting_confirmation": True,
            "pending_action": "confirm_2",
            "messages": [AIMessage(content=summary)],
        }

    async def _deployer_node(self, state: GraphState, config: RunnableConfig) -> dict:
        """Deployment — with the structural submission preconditions
        (T124/T125) checked BEFORE any worker call or cluster access.

        Also handles status/remove tool routing (T256/T257): when tool_action
        is set, bypass submission preconditions and call the deployer tools
        path with the canonical tool_request.
        """
        # Tool path: call deployer for status/remove without submission preconditions
        tool_action = state.get("tool_action")
        if tool_action in ("status", "remove"):
            req = state.get("tool_request") or "{}"
            nonce = new_request_nonce()
            fenced = wrap_worker_text(redact_prompt(req), nonce)  # T095
            logger.info("[Deployer:tools] calling deployer worker (nonce=%s)", nonce[:8])
            try:
                result = await self.transport.call_deployer(fenced)
            except WorkerUnavailableError as exc:
                logger.warning("deployer unavailable: %s", exc)
                try:
                    get_metrics().record_stage_result(stage="deployer", success=False)
                except Exception:
                    pass
                return {
                    "next_node": END,
                    "messages": [
                        AIMessage(content=("The deployer worker is currently unavailable; please try again later."))
                    ],
                }
            payload, worker_text = extract_payload_and_text(result, DEPLOYER_MARKER, "deployer")
            # Minimal contract: expect a dict with either status or removed
            if not isinstance(payload, dict) or not any(k in payload for k in ("status", "removed")):
                return self._reject_out_of_contract(
                    state, config, stage="deployer", error="no contract tools report", worker_text=worker_text
                )
            # Build an operator-facing summary. Prefer the worker's text, but augment
            # status answers with unverified-property hints (T049a) carried in the payload.
            status_report = payload.get("status") if isinstance(payload, dict) else None
            if tool_action == "status" and isinstance(status_report, dict):
                phase = str(status_report.get("phase") or "Unknown")
                resources = status_report.get("resources") if isinstance(status_report.get("resources"), list) else []
                # Compose a short summary including any unverified properties so the
                # operator never sees a property as verified when the check did not run.
                parts: list[str] = []
                for r in resources:
                    if not isinstance(r, dict):
                        continue
                    name = f"{r.get('kind')}/{r.get('name')}"
                    detail = str(r.get("message") or r.get("reason") or "").strip()
                    suffix = ""
                    unver = r.get("unverified")
                    if isinstance(unver, list) and unver:
                        items: list[str] = []
                        for it in unver:
                            if isinstance(it, dict):
                                prop = str(it.get("property") or "property")
                                node = str(it.get("node") or "node")
                                items.append(f"{prop}@{node}")
                        if items:
                            suffix = "; unverified: " + ", ".join(items)
                    text = name
                    if detail:
                        text += f" ({detail}{suffix})"
                    elif suffix:
                        text += f" ({suffix.lstrip('; ')})"
                    parts.append(text)
                summary = redact_model_response((phase + ". " + "; ".join(parts)).strip())
            else:
                summary = redact_model_response(worker_text.split("<!--")[0].strip()) or "Tools result."
            out: dict[str, Any] = {
                "next_node": END,
                "tool_action": tool_action,
                "tool_result": canonical_json(payload),
                "messages": [AIMessage(content=summary)],
            }
            # A status answer resolves the transaction: the thread's status
            # becomes the cluster's verdict, so the operator is never told
            # "PROVISIONING" about a transaction that has already converged
            # (or already failed).
            if tool_action == "status" and isinstance(status_report, dict):
                resolved = _STATUS_PHASE_TO_WORKFLOW.get(str(status_report.get("phase") or ""))
                if resolved is not None:
                    out["workflow_status"] = resolved.value
                    if resolved is NetworkProvisioningStatus.FAILED:
                        out["refusal_reason"] = f"deployer resolved the deployment status: {summary}"
                        out["suggestion"] = DEFAULT_SUGGESTION
            return out

        # ---- Submission preconditions (T124/T125) -----------------------
        workflow_status = state.get("workflow_status")
        if workflow_status != NetworkProvisioningStatus.APPROVED.value:
            return self._refuse(
                state,
                config,
                f"submission precondition failed: workflow_status is '{workflow_status}', not "
                "APPROVED — nothing can be submitted",
                DEFAULT_SUGGESTION,
                stage="deployer",
            )
        confirmation_2 = state.get("confirmation_2")
        decided = confirmation_2.get("decided") if isinstance(confirmation_2, dict) else None
        if decided != "confirm":
            return self._refuse(
                state,
                config,
                f"submission precondition failed: confirmation_2.decided is '{decided}', not "
                "'confirm' — nothing can be submitted",
                DEFAULT_SUGGESTION,
                stage="deployer",
            )

        intent_json = state.get("allocated_resources")
        if not intent_json:
            return self._refuse(
                state, config,
                "submission precondition failed: no allocated normalized intent to submit",
                DEFAULT_SUGGESTION,
                stage="deployer",
            )

        # The production deployment envelope (docs/INTENT_TIER_DEPLOYMENT_
        # TRANSACTION.md): the validated intent plus the immutable request
        # context, so every submitted resource carries the conversation's
        # correlation metadata and the deployer audit event names the same
        # principal and thread.
        correlation_id = state.get("correlation_id") or ""
        if not correlation_id:
            correlation_id = new_request_nonce()
            state["correlation_id"] = correlation_id
        thread_id = (config or {}).get("configurable", {}).get("thread_id", "default_session")
        try:
            envelope = canonical_json(
                {
                    "action": "submit",
                    "intent": json.loads(intent_json),
                    "context": {
                        "correlationId": correlation_id,
                        "threadId": thread_id,
                        "principal": state.get("principal") or "operator",
                    },
                }
            )
        except (TypeError, ValueError) as exc:
            return self._refuse(
                state, config,
                f"submission precondition failed: allocated intent is not valid JSON ({exc})",
                DEFAULT_SUGGESTION,
                stage="deployer",
            )

        nonce = new_request_nonce()
        fenced = wrap_worker_text(redact_prompt(envelope), nonce)  # T095
        logger.info("[Deployer] preconditions held; calling deployer worker (nonce=%s)", nonce[:8])
        try:
            result = await self.transport.call_deployer(fenced)
        except WorkerUnavailableError as exc:
            logger.warning("deployer unavailable: %s", exc)
            try:
                get_metrics().record_stage_result(stage="deployer", success=False)
            except Exception:
                pass
            return {
                "next_node": END,
                "messages": [
                    AIMessage(
                        content=(
                            "The deployer worker is currently unavailable; nothing was submitted. "
                            "Please confirm again to retry — your thread is kept."
                        )
                    )
                ],
            }

        payload, worker_text = extract_payload_and_text(result, DEPLOYER_MARKER, "deployer")
        # A named transaction failure ({"failed": {...}}) is a contract
        # report, not an out-of-contract payload: the deployer names the
        # failed phase, the full rolled-back set, and any survivor, and
        # never reports the transaction as submitted (deployment contract,
        # failure behavior table).
        if isinstance(payload, dict) and isinstance(payload.get("failed"), dict):
            failure = payload["failed"]
            phase = str(failure.get("phase") or "transaction")
            resource = failure.get("resource")
            rolled_back = failure.get("rolledBack") or []
            survivors = failure.get("survivors") or []
            detail = str(failure.get("message") or "deployment transaction failed")
            try:
                get_metrics().record_stage_result(stage="deployer", success=False)
            except Exception:
                pass
            self._audit(
                state, config, "refuse",
                reason=f"deployer reported transaction failure during {phase}: {detail}",
            )
            content = redact_model_response(
                f"The deployment failed during the {phase} phase"
                + (f" ({resource})" if resource else "")
                + f": {detail}. Nothing is reported as submitted."
                + (f" {len(rolled_back)} resource(s) were rolled back." if rolled_back else "")
                + (
                    " Resources that could not be deleted (rollback survivors): "
                    + ", ".join(
                        f"{r.get('kind')}/{r.get('name')}" for r in survivors if isinstance(r, dict)
                    )
                    + "."
                    if survivors
                    else ""
                )
                + f" (correlation id: {state.get('correlation_id') or ''})"
            )
            return {
                "next_node": END,
                "workflow_status": NetworkProvisioningStatus.FAILED.value,
                "refusal_reason": f"deployer transaction failure during {phase}: {detail}",
                "suggestion": DEFAULT_SUGGESTION,
                "awaiting_confirmation": False,
                "pending_action": None,
                "messages": [AIMessage(content=content)],
            }
        # The deployer's real submission (Go translator, atomic all-or-nothing
        # apply, convergence watch — FR-017..FR-019) produced an authoritative
        # report {"submitted": [ResourceRef...]}; anything else is
        # out-of-contract and nothing is submitted.
        if isinstance(payload, dict) and isinstance(payload.get("submitted"), list):
            resources: list[ResourceRef] = []
            try:
                for item in payload["submitted"]:
                    resources.append(ResourceRef.model_validate(item))
            except ValidationError as exc:
                try:
                    get_metrics().record_stage_result(stage="deployer", success=False)
                except Exception:
                    pass
                return self._reject_out_of_contract(
                    state, config, stage="deployer",
                    error=f"submission report resources invalid: {_format_validation_error(exc)}",
                    worker_text=worker_text,
                )
            self._audit(state, config, "submit", resources=resources, reason="deployer submission report")
            # The deployer watched convergence (deployment contract step 7)
            # and reported one terminal observation per resource. That report
            # is the transaction's OUTCOME; ending the thread at PROVISIONING
            # while holding it would leave the operator with no in-band way
            # to learn whether the service came up.
            convergence = payload.get("convergence")
            convergence = convergence if isinstance(convergence, list) else []
            names = ", ".join(f"{r.kind}/{r.name}" for r in resources)
            correlation = state.get("correlation_id") or ""
            submitted_json = canonical_json([r.model_dump(mode="json") for r in resources])
            carried = {
                "next_node": END,
                "submitted_resources": submitted_json,
                "submitted_correlation_id": correlation,
                "convergence": canonical_json(convergence),
            }

            failed_obs = [c for c in convergence if isinstance(c, dict) and c.get("outcome") == "failed"]
            timed_out = [c for c in convergence if isinstance(c, dict) and c.get("outcome") == "timeout"]
            ready_obs = [c for c in convergence if isinstance(c, dict) and c.get("outcome") == "ready"]

            if failed_obs:
                # Submitted, then did not converge. The submission stands (the
                # objects are on the cluster and the submit audit event is
                # true); the transaction's outcome is a failure and is named
                # as one, with the controller's own condition message.
                detail = _describe_convergence(failed_obs)
                try:
                    get_metrics().record_stage_result(stage="deployer", success=False)
                except Exception:
                    pass
                return {
                    **carried,
                    "workflow_status": NetworkProvisioningStatus.FAILED.value,
                    "refusal_reason": f"deployer submitted {names} but convergence failed: {detail}",
                    "suggestion": (
                        "Inspect the resource's Ready condition, correct the intent, and submit a "
                        "fresh request; the submitted objects were not rolled back."
                    ),
                    "messages": [
                        AIMessage(
                            content=redact_model_response(
                                f"Deployment failed. {names} was submitted, but it did not converge: "
                                f"{detail}. The submitted objects remain on the cluster — nothing was "
                                f"rolled back, because the apply itself succeeded. "
                                f"(correlation id: {correlation})"
                            )
                        )
                    ],
                }

            if ready_obs and not timed_out:
                # Every submitted object reported Ready: this is the final,
                # verified outcome and the thread ends on it.
                detail = _describe_convergence(ready_obs)
                try:
                    get_metrics().record_stage_result(stage="deployer", success=True)
                except Exception:
                    pass
                return {
                    **carried,
                    "workflow_status": NetworkProvisioningStatus.COMPLETED.value,
                    "awaiting_confirmation": False,
                    "pending_action": None,
                    "messages": [
                        AIMessage(
                            content=redact_model_response(
                                f"Deployed. {len(ready_obs)} resource(s) reached Ready on the fabric: "
                                f"{detail}. (correlation id: {correlation})"
                            )
                        )
                    ],
                }

            try:
                get_metrics().record_stage_result(stage="deployer", success=True)
            except Exception:
                pass
            if timed_out:
                # Bounded watch, honest report: submitted and still converging.
                # This is NOT an outcome, and it does not claim to be one.
                detail = _describe_convergence(timed_out)
                return {
                    **carried,
                    "workflow_status": NetworkProvisioningStatus.PROVISIONING.value,
                    "messages": [
                        AIMessage(
                            content=redact_model_response(
                                f"Submitted {names}, still converging when the deployer's watch bound "
                                f"expired: {detail}. Nothing failed — ask \"what is the status of the "
                                f"deployment?\" on this thread and I will resolve the current condition "
                                f"from the cluster. (correlation id: {correlation})"
                            )
                        )
                    ],
                }
            # No convergence report at all (a deployer that ran with the watch
            # disabled): the submission is all that can be claimed.
            return {
                **carried,
                "workflow_status": NetworkProvisioningStatus.PROVISIONING.value,
                "messages": [
                    AIMessage(
                        content=(
                            "Submission report received: "
                            + names
                            + ". No convergence observation was reported, so the outcome is not yet "
                            "known — ask for the status of the deployment to resolve it. "
                            "(correlation id: "
                            + correlation
                            + ")"
                        )
                    )
                ],
            }
        try:
            get_metrics().record_stage_result(stage="deployer", success=False)
        except Exception:
            pass
        return self._reject_out_of_contract(
            state,
            config,
            stage="deployer",
            error="no contract submission report (expected {submitted: [ResourceRef...]}); nothing was submitted",
            worker_text=worker_text,
        )

    async def _general_response_node(self, state: GraphState, config: RunnableConfig) -> dict:
        """Informational path (T087): a scoped, deterministic answer from
        the tier's fixed capability description and the thread status.
        No tools, no model call, no device access — this node cannot be
        redirected, because it has nothing to redirect it with."""
        status = state.get("workflow_status") or NetworkProvisioningStatus.RECEIVED_REQUEST.value
        text = (
            "I provision declarative network services on the SONiC EVPN/VXLAN fabric: "
            "VPLS (full-mesh L2 bridge), VPWS (point-to-point L2 / E-Line), L3VPN, and IRB "
            "(integrated L2+L3), each between two or more attachment points for a named tenant. "
            f"The current status of this request thread is {status}. "
            "I never act directly on devices: every change flows through declarative service "
            "intent and the two-confirmation pipeline."
        )
        # A thread with a submission in flight says so, and says how to get
        # the outcome — rather than leaving the operator with a bare status
        # word for a transaction it cannot see.
        if status == NetworkProvisioningStatus.PROVISIONING.value and state.get("submitted_resources"):
            text += (
                " A submission on this thread is still converging; ask \"what is the status of the "
                "deployment?\" and I will resolve its condition from the cluster."
            )
        # An informational answer must not relabel the thread. Only a thread
        # with nothing in flight ends COMPLETED here; a transaction's status
        # is owned by the transaction (data-model.md §8).
        if status in (
            NetworkProvisioningStatus.FAILED.value,
            NetworkProvisioningStatus.PROVISIONING.value,
            NetworkProvisioningStatus.MAPPED.value,
            NetworkProvisioningStatus.ALLOCATED.value,
            NetworkProvisioningStatus.APPROVED.value,
        ):
            final_status = status
        else:
            final_status = NetworkProvisioningStatus.COMPLETED.value
        return {
            "messages": [AIMessage(content=text)],
            "workflow_status": final_status,
        }

    async def _reflection_node(self, state: GraphState, config: RunnableConfig) -> dict:
        """After mapper/allocator: pose the confirmation question (or end
        on terminal/bounded states). The subject's reflection decided
        loop-vs-end with the LLM; this tier decides it deterministically
        from the workflow state — the confirmation points are the only
        user-facing loop in the pipeline."""
        if state.get("awaiting_confirmation") and state.get("pending_action") in ("confirm_1", "confirm_2"):
            question = (
                "Confirm this interpretation? Reply 'confirm' to proceed to allocation, or "
                "'decline' to cancel."
                if state.get("pending_action") == "confirm_1"
                else "Deploy this service? Reply 'confirm' to submit it to the cluster, or "
                "'decline' to cancel (any claimed identifiers will be released)."
            )
            return {"next_node": END, "messages": [AIMessage(content=question)]}
        if state.get("awaiting_confirmation") and state.get("pending_action") == "clarify":
            return {"next_node": END}
        if state.get("workflow_status") in (
            NetworkProvisioningStatus.FAILED.value,
            NetworkProvisioningStatus.COMPLETED.value,
        ):
            return {"next_node": END}
        if self._deadline_exceeded(state):
            return self._bounded_exit(state, config, "wall-clock deadline exceeded")
        if state.get("iteration_count", 0) >= MAX_ITERATIONS:
            return self._bounded_exit(state, config, f"iteration bound {MAX_ITERATIONS} reached")
        return {
            "next_node": NodeStates.SUPERVISOR,
            "iteration_count": state.get("iteration_count", 0) + 1,
        }
