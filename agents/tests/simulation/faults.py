"""
Fault injection utilities for simulation.

Implements:
- T439: supervisor_restart_fault()
- T440: assert_inflight_thread_completes_without_double_submission(records)
"""
from __future__ import annotations

from collections.abc import Iterable

from agents.tests.simulation.harness import SessionResult


def supervisor_restart_fault(thread_id: str) -> None:
    """
    T439: Simulate a supervisor restart while a thread is in-flight.
    This is a no-op placeholder for CI simulation: the harness records
    submitted_count and we verify it remains 1.
    """
    # In real env we'd bounce the Deployment and wait for /v1/health.
    # For the dry-run, nothing to do.
    return None


def assert_inflight_thread_completes_without_double_submission(records: Iterable[SessionResult]) -> None:
    """
    T440: Ensure restarted in-flight thread completes with exactly one submission.
    """
    for r in records:
        if r.submitted_count != 1:
            raise AssertionError("Double submission detected for thread")
