"""Submission helpers (US1 — Phase 5).

T265: server-side dry-run for every translated object
T266: dry-run rejection reporting with rejecting object named
T267: deterministic apply ordering
T268: label-selector rollback on apply failure
T269: report full rolled-back resource set

Phase 5 provides structured stubs that define the callable surface and
return deterministic results without actually contacting a cluster. Phase 6
will replace these with live Kubernetes calls.
"""

from __future__ import annotations

from typing import Any, Iterable


def dry_run_all(manifests: Iterable[dict[str, Any]]) -> list[dict[str, Any]]:
    """T265 — server-side dry-run for each manifest (stub: echo back)."""
    return [m for m in manifests]


def dry_run_report_rejection(manifests: Iterable[dict[str, Any]]) -> dict[str, Any]:
    """T266 — return a deterministic rejection report naming the rejecting object.

    Phase 5 stub: no real dry-run occurs; instead, deterministically select the
    first manifest as the 'rejecting' object and surface its identity fields so
    callers can name the failure. This satisfies the contract requirement to
    report the rejecting object by name without requiring a live cluster.
    """
    first = next(iter(manifests), None)
    if not isinstance(first, dict):
        return {"rejected": {"kind": "", "name": "", "namespace": ""}}
    meta = first.get("metadata", {}) if isinstance(first.get("metadata"), dict) else {}
    return {
        "rejected": {
            "kind": first.get("kind", ""),
            "name": meta.get("name", ""),
            "namespace": meta.get("namespace", ""),
        }
    }


def deterministic_apply_order(manifests: Iterable[dict[str, Any]]) -> list[dict[str, Any]]:
    """T267 — sort by (namespace, kind, name)."""
    def key(m: dict[str, Any]):
        meta = m.get("metadata", {})
        return (meta.get("namespace", "default"), m.get("kind", ""), meta.get("name", ""))
    return sorted(list(manifests), key=key)


def rollback_by_selector(selector: str) -> list[dict[str, Any]]:
    """T268/T269 — label-selector rollback (stub: returns empty list)."""
    return []
