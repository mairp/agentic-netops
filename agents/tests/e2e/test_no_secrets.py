"""US2 e2e — trace/log/transcript credential scan (T134, NFR-003/FR-031/SC-016).

Runs the real supervisor graph on a request that CARRIES credentials of
every pattern shape ``common/redaction.py`` (T106) defines, with an
echoing mapper stub (a model that repeats what it is shown — the
worst case), and scans every artifact the tier produces:

* the **chat transcript** (every message in the final graph state),
* the **log records** (captured through the ``RedactingFilter`` wired by
  ``config/logging_config.py``, T108),
* the **audit events** (sink records, including ``reason``),
* the **span events** (the OTel ``intent.audit`` span events emitted by
  ``common/audit.py``, T103, read back from an in-memory exporter).

Every artifact must scan clean under ``common.redaction.contains_credential``
(zero credentials survived) while the redaction marker is present where the
echoing model repeated the prompt (redaction happened, not just absence).

Runs when selected (``pytest -m e2e``); no cluster is needed — the scan is
on process-local artifacts.
"""

from __future__ import annotations

import logging
import secrets

import pytest
from langchain_core.messages import AIMessage, HumanMessage
from langchain_core.runnables import RunnableLambda
from opentelemetry import trace as otel_trace
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import SimpleSpanProcessor
from opentelemetry.sdk.trace.export.in_memory_span_exporter import InMemorySpanExporter

from common.audit import get_audit_sink, reset_audit_sink
from common.provisioning_states import NetworkProvisioningStatus
from common.redaction import contains_credential, redaction_marker
from common.schemas.interpretation import Interpretation
from config.logging_config import RedactingFilter
from supervisors.provisioning.graph.graph import ProvisioningGraph, default_deadline
from tests.corpus.adversarial.runner import StubClassifierLLM, StubTransport, parse_service_request

pytestmark = pytest.mark.e2e

# One credential of every T106 pattern shape, embedded in a legitimate
# provisionable request.
CREDENTIALS = (
    "password=SuperSecret123 "
    "api_key=sk-abcdefghijklmnopqrstuvwxyz012345 "
    "token: Bearer eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJ0ZXN0In0.c2lnbmF0dXJl "
    "AKIAIOSFODNN7EXAMPLE "
    "https://user:SecretPass456@slim.example:46357"
)
REQUEST = (
    "provision a point-to-point 1Gbps VPWS service between leaf01 ethernet1 "
    f"and leaf02 ethernet2 for tenant acme, vlan 100 (credentials: {CREDENTIALS})"
)


class EchoingMapperTransport(StubTransport):
    """A mapper that repeats (echoes) the prompt it was given — the
    model-echo worst case for FR-031. It receives the REDACTED, fenced
    prompt, so its echo can only carry the redaction markers."""

    async def call_mapper(self, text: str):
        self.calls.append(("mapper", text))
        payload = parse_service_request(self._fenced_body(text))
        if payload is None:
            raise AssertionError("echoing mapper could not parse the request shape")
        interp = Interpretation.model_validate(payload)
        return {
            "parts": [
                {"data": interp.model_dump(mode="json")},
                {"text": f"Interpretation ready.\nEcho of request: {self._fenced_body(text)}"},
            ]
        }


class _CapturingHandler(logging.Handler):
    def __init__(self) -> None:
        super().__init__()
        self.records: list[str] = []

    def emit(self, record: logging.LogRecord) -> None:
        try:
            self.records.append(self.format(record))
        except Exception:  # noqa: BLE001
            self.records.append(str(record.msg))


def _scan(name: str, texts: list[str], violations: list[str]) -> None:
    for text in texts:
        if text and contains_credential(text):
            violations.append(f"{name}: a credential pattern survived in: {text[:120]!r}")


async def test_no_secrets_in_trace_log_transcript() -> None:
    violations: list[str] = []

    # --- log capture through the T108 RedactingFilter --------------------
    capture = _CapturingHandler()
    capture.setFormatter(logging.Formatter("%(name)s: %(message)s"))
    capture.addFilter(RedactingFilter())
    root = logging.getLogger()
    root.addHandler(capture)

    # --- span capture (T103 span events) ---------------------------------
    exporter = InMemorySpanExporter()
    provider = TracerProvider()
    provider.add_span_processor(SimpleSpanProcessor(exporter))
    try:
        otel_trace.set_tracer_provider(provider)
    except Exception:  # noqa: BLE001 - a pre-set provider keeps the test honest below
        pass
    tracer = otel_trace.get_tracer("e2e.no-secrets")

    reset_audit_sink()
    llm = StubClassifierLLM()
    graph = ProvisioningGraph(
        llm_factory=lambda streaming=None: RunnableLambda(llm.ainvoke),
        transport=EchoingMapperTransport(),
    )
    cid = secrets.token_hex(16)
    config = {"configurable": {"thread_id": f"nosecrets-{cid[:12]}"}}
    seed = {
        "messages": [HumanMessage(content=REQUEST)],
        "correlation_id": cid,
        "principal": "no-secrets-probe",
        "workflow_status": NetworkProvisioningStatus.RECEIVED_REQUEST.value,
        "deadline": default_deadline(),
    }
    try:
        with tracer.start_as_current_span("e2e.no-secrets.request"):
            state = await graph.ainvoke(seed, config=config)
            # A decline turn so the scan also covers a real audit event
            # (the decline's reason/reason fields go through the same
            # redaction path as every other free text).
            state = await graph.ainvoke({"messages": [HumanMessage(content="decline")]}, config=config)
    finally:
        await graph.close()
        root.removeHandler(capture)

    # The mapper echoes the (already redacted) prompt in its text part —
    # the echoing-model worst case. The echo carries the redaction markers,
    # never the raw secrets.
    assert state.get("workflow_status") == NetworkProvisioningStatus.FAILED.value  # declined

    # The transcript scanned here is what the TIER generated (AIMessage);
    # the operator's own HumanMessage is the operator's data in the
    # operator's thread (data-model.md: original_text is stored verbatim).
    transcript = [m.content for m in state.get("messages", []) if isinstance(m, AIMessage)]
    audit_texts = [e.model_dump_json() for e in get_audit_sink().by_correlation(cid)]
    span_texts: list[str] = []
    for span in exporter.get_finished_spans():
        for event in span.events:
            for key, value in event.attributes.items():
                span_texts.append(f"{key}={value}")

    # --- the scan (T134) ---------------------------------------------------
    _scan("transcript", transcript, violations)
    _scan("log-records", capture.records, violations)
    _scan("audit-events", audit_texts, violations)
    _scan("span-events", span_texts, violations)

    # Redaction demonstrably happened (not just absence): the echoing
    # model's repetition of the prompt must carry the marker.
    assert redaction_marker() in "\n".join(transcript), (
        "the echoing model's prompt repetition was not redacted (no marker in transcript)"
    )
    # And the raw secrets are nowhere.
    for secret in ("SuperSecret123", "sk-abcdefghijklmnopqrstuvwxyz012345", "SecretPass456"):
        joined = "\n".join(transcript + capture.records + audit_texts + span_texts)
        assert secret not in joined, f"raw secret {secret!r} leaked into an artifact"

    assert not violations, "\n".join(violations)
