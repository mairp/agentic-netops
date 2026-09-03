"""Resource stamping helpers (US1 — Phase 5).

T263: Implement resource label stamping
T264: Implement resource annotation stamping

These helpers mutate a Kubernetes object dict in-place and return it, adding
labels/annotations under metadata. They are deterministic and idempotent.
"""

from __future__ import annotations

from typing import Any, Mapping

from common.telemetry import CORRELATION_LABEL, get_trace_correlation_id


def stamp_labels(obj: dict[str, Any], labels: Mapping[str, str]) -> dict[str, Any]:
    # Ensure correlation-id label, if present under agentic-netops.io/correlation-id, is a string
    if CORRELATION_LABEL in labels and labels[CORRELATION_LABEL] is not None:
        labels = dict(labels)
        labels[CORRELATION_LABEL] = str(labels[CORRELATION_LABEL])

    meta = obj.setdefault("metadata", {})
    lbls = meta.setdefault("labels", {})
    for k, v in (labels or {}).items():
        lbls[str(k)] = str(v)
    return obj


def stamp_annotations(obj: dict[str, Any], annotations: Mapping[str, str]) -> dict[str, Any]:
    # Stamp a correlation id from the active trace if not provided by caller later in the flow
    cid = get_trace_correlation_id()
    if cid:
        annotations = dict(annotations or {})
        annotations.setdefault(CORRELATION_LABEL, cid)

    meta = obj.setdefault("metadata", {})
    ann = meta.setdefault("annotations", {})
    for k, v in (annotations or {}).items():
        ann[str(k)] = str(v)
    return obj
