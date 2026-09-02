"""Resource stamping helpers (US1 — Phase 5).

T263: Implement resource label stamping
T264: Implement resource annotation stamping

These helpers mutate a Kubernetes object dict in-place and return it, adding
labels/annotations under metadata. They are deterministic and idempotent.
"""

from __future__ import annotations

from typing import Any, Mapping


def stamp_labels(obj: dict[str, Any], labels: Mapping[str, str]) -> dict[str, Any]:
    meta = obj.setdefault("metadata", {})
    lbls = meta.setdefault("labels", {})
    for k, v in (labels or {}).items():
        lbls[str(k)] = str(v)
    return obj


def stamp_annotations(obj: dict[str, Any], annotations: Mapping[str, str]) -> dict[str, Any]:
    meta = obj.setdefault("metadata", {})
    ann = meta.setdefault("annotations", {})
    for k, v in (annotations or {}).items():
        ann[str(k)] = str(v)
    return obj
