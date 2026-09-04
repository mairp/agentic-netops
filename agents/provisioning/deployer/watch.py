"""Convergence watch for submitted intent-tier objects (deployment contract
step 7 of docs/INTENT_TIER_DEPLOYMENT_TRANSACTION.md).

Poll every submitted object until one of the three terminal observations:

* its ``Ready`` condition is true                       -> ``ready``
* a terminal failure condition/phase is observed        -> ``failed``
* the configured convergence timeout expires            -> ``timeout``

The submission report records ``ready=true``, ``ready=false``, or
``ready=null`` respectively and includes the named outcome. An object that
disappears mid-watch is a ``failed`` observation, not a timeout: desired
state vanished while the transaction was still open.
"""

from __future__ import annotations

import logging
import time
from collections.abc import Callable
from dataclasses import dataclass
from typing import Any, Protocol

from common.schemas.refs import ResourceRef

logger = logging.getLogger("agentic_netops.network_deployer.watch")

READY_CONDITION_TYPE = "Ready"

# Named convergence outcomes reported per resource (doc step 7).
OUTCOME_READY = "ready"
OUTCOME_FAILED = "failed"
OUTCOME_TIMEOUT = "timeout"

# Condition types whose True value is terminal, whatever Ready says.
TERMINAL_FAILURE_CONDITIONS = frozenset({"Failed", "Error"})
# status.phase values that are terminal failures.
TERMINAL_FAILURE_PHASES = frozenset({"Failed", "Error", "Rejected"})


class ConvergenceWatchError(RuntimeError):
    """The watch could not observe an object at all (API failure)."""


class WatchClient(Protocol):
    """The read side of the intent API the watch needs."""

    def get(self, ref: ResourceRef) -> dict[str, Any] | None: ...


@dataclass(frozen=True)
class ConvergenceOutcome:
    """One resource's terminal convergence observation."""

    ref: ResourceRef
    outcome: str  # ready | failed | timeout
    detail: str | None = None

    def report(self) -> dict[str, Any]:
        return {
            "resource": f"{self.ref.kind}/{self.ref.name}",
            "outcome": self.outcome,
            "ready": self.ref.ready,
            "detail": self.detail,
        }


def _observe(obj: dict[str, Any]) -> tuple[bool | None, str | None]:
    """Classify one object read as (ready, failure_detail).

    ``None`` means "still converging" — keep polling.
    """
    status = obj.get("status") if isinstance(obj.get("status"), dict) else {}
    conditions = status.get("conditions") if isinstance(status.get("conditions"), list) else []
    ready_false_detail: str | None = None
    for condition in conditions:
        if not isinstance(condition, dict):
            continue
        cond_type = str(condition.get("type") or "")
        cond_status = str(condition.get("status") or "").lower()
        if cond_type == READY_CONDITION_TYPE:
            if cond_status == "true":
                return True, None
            if cond_status == "false":
                ready_false_detail = str(
                    condition.get("message") or condition.get("reason") or "Ready condition is False"
                )
        elif cond_type in TERMINAL_FAILURE_CONDITIONS and cond_status == "true":
            return False, str(
                condition.get("message") or condition.get("reason") or f"{cond_type} condition is True"
            )
    if ready_false_detail is not None:
        # Ready=False is only terminal when no progressive condition can
        # still flip it; the tier's controllers set Ready=False terminally.
        return False, ready_false_detail
    phase = str(status.get("phase") or "")
    if phase in TERMINAL_FAILURE_PHASES:
        return False, f"phase {phase}"
    return None, None


def watch_convergence(
    client: WatchClient,
    refs: list[ResourceRef],
    *,
    timeout_seconds: float,
    poll_seconds: float,
    on_progress: Callable[[dict[str, Any]], None] | None = None,
) -> list[ConvergenceOutcome]:
    """Poll every submitted ref to a terminal observation (T270/T271/T272).

    Returns one :class:`ConvergenceOutcome` per ref, in the input order.
    Each ref's ``ready`` field is set from the observation: ``True`` for
    ready, ``False`` for failed, ``None`` for timeout.
    """

    outcomes: dict[int, ConvergenceOutcome] = {}
    # Work on copies so the caller's submitted refs are updated, not aliased.
    pending: dict[int, ResourceRef] = {i: ref.model_copy(deep=True) for i, ref in enumerate(refs)}
    deadline = time.monotonic() + max(0.0, timeout_seconds)

    while pending:
        for index, ref in list(pending.items()):
            try:
                obj = client.get(ref)
            except Exception as exc:  # noqa: BLE001 - an unreadable object cannot be called converged
                logger.warning("convergence read failed for %s/%s: %s", ref.kind, ref.name, exc)
                continue
            if obj is None:
                ref.ready = False
                outcomes[index] = ConvergenceOutcome(
                    ref, OUTCOME_FAILED, "object disappeared during convergence watch"
                )
                del pending[index]
                continue
            ready, detail = _observe(obj)
            if ready is True:
                ref.ready = True
                outcomes[index] = ConvergenceOutcome(ref, OUTCOME_READY, detail)
                del pending[index]
            elif ready is False:
                ref.ready = False
                outcomes[index] = ConvergenceOutcome(ref, OUTCOME_FAILED, detail)
                del pending[index]
            elif on_progress:
                on_progress({"resource": f"{ref.kind}/{ref.name}", "step": "pending"})

        if not pending:
            break
        if time.monotonic() >= deadline:
            break
        time.sleep(max(0.05, min(poll_seconds, max(0.0, deadline - time.monotonic()))))

    for index, ref in pending.items():
        ref.ready = None
        outcomes[index] = ConvergenceOutcome(
            ref, OUTCOME_TIMEOUT, f"convergence timeout after {timeout_seconds:g}s"
        )
    return [outcomes[i] for i in range(len(refs))]


__all__ = [
    "ConvergenceOutcome",
    "ConvergenceWatchError",
    "WatchClient",
    "OUTCOME_READY",
    "OUTCOME_FAILED",
    "OUTCOME_TIMEOUT",
    "READY_CONDITION_TYPE",
    "watch_convergence",
]
