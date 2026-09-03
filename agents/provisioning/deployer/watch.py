"""Convergence watch helpers (US1 — Phase 5).

T270: Ready condition watch
T271: terminal failure condition watch
T272: convergence timeout handling

Phase 5 provides deterministic stubs so the supervisor can stream progress
chunks; live watches land in Phase 6.
"""

from __future__ import annotations

import time
from typing import Any, Callable, Iterator


def watch_ready(timeout_seconds: float = 10.0, on_progress: Callable[[dict[str, Any]], None] | None = None) -> bool:
    """T270/T272 — stubbed ready watch: emits a deterministic progress step and returns True."""
    start = time.time()
    if on_progress:
        on_progress({"step": "starting"})
    # Deterministic single step
    if on_progress:
        on_progress({"step": "pending"})
    return (time.time() - start) <= timeout_seconds


def watch_failure(timeout_seconds: float = 10.0, on_progress: Callable[[dict[str, Any]], None] | None = None) -> bool:
    """T271 — stubbed failure watch: never triggers in Phase 5 stubs."""
    return False
