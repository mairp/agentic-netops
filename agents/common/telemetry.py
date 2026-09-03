"""Telemetry helpers for correlation-id binding (US5 — Phase 8).

T330: Bind the active W3C trace id to a correlation id stable across sinks so
one request is recoverable as one trace and can be joined to fabric resources
without timestamp matching.

The binding is implemented by returning the current span's trace_id (hex) as
``get_trace_correlation_id()``, and by providing helpers to stamp this value
onto resource dicts under the conventional ainetops.io/correlation-id label.
"""
from __future__ import annotations

from typing import Any

from opentelemetry import trace


CORRELATION_LABEL = "ainetops.io/correlation-id"


def get_trace_correlation_id() -> str:
    """Return the active W3C trace id (32-hex) for correlation-id stamping.

    If no span is recording, returns an empty string.
    """
    span = trace.get_current_span()
    ctx = span.get_span_context() if span is not None else None
    if ctx is None or not ctx.is_valid:
        return ""
    # TraceId is a 128-bit int; represent as 32 lowercase hex
    tid = format(ctx.trace_id, "032x")
    return tid


def stamp_correlation_label(obj: dict[str, Any], correlation_id: str) -> dict[str, Any]:
    meta = obj.setdefault("metadata", {})
    labels = meta.setdefault("labels", {})
    labels[CORRELATION_LABEL] = correlation_id
    return obj
