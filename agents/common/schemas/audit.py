"""AuditEvent (data-model.md §7) — the immutable audit record.

Emitted for every confirmation, decline, submission, and refusal (FR-030),
as both a span event and a Kubernetes ``Event`` in ``agentic-netops-intent``.
SC-006 reconciles the NDJSON stream against the resources actually present
under the correlation-id label; the counts must be equal, and any resource
without a matching ``confirm`` is a failure.
"""

from __future__ import annotations

from datetime import datetime
from typing import Literal

from pydantic import BaseModel, ConfigDict, Field

from .refs import ResourceRef

AuditEventType = Literal["confirm", "decline", "submit", "refuse"]


class AuditEvent(BaseModel):
    """One immutable audit record (data-model.md §7).

    * ``resources`` is empty for ``refuse`` and ``decline``;
    * ``reason`` names the unsupported properties (``refuse``) or carries
      the refusal/decline explanation.
    """

    model_config = ConfigDict(extra="forbid")

    event_type: AuditEventType
    correlation_id: str = Field(min_length=32, max_length=32,
                                pattern=r"^[0-9a-f]{32}$")
    thread_id: str = Field(min_length=1)
    principal: str = Field(min_length=1)
    at: datetime
    resources: list[ResourceRef] = Field(default_factory=list)
    reason: str | None = None

    def validate_event_shape(self) -> list[str]:
        """Cross-field rules: refuse/decline carry no resources (data-model
        §7). Returns a list of violations (empty = valid)."""
        violations: list[str] = []
        if self.event_type in ("refuse", "decline") and self.resources:
            violations.append(
                f"event_type={self.event_type!r} must carry no resources "
                f"(got {len(self.resources)})"
            )
        if self.event_type == "submit" and not self.resources:
            violations.append("event_type='submit' requires the submitted resources")
        return violations
