"""Resource references and claim references (data-model.md §5, §6)."""

from __future__ import annotations

from datetime import datetime

from pydantic import BaseModel, ConfigDict, Field


class ResourceRef(BaseModel):
    """A submitted fabric resource (data-model.md §5).

    ``ready`` is ``None`` while the convergence watch is open, and resolves
    to the observed ``Ready`` condition, a terminal failure, or a timeout —
    FR-019 requires reporting which of the three. The ref is stamped with
    the correlation-id label so SC-010's reverse direction is a single
    label-selector query (contracts/kubernetes-objects.md).
    """

    model_config = ConfigDict(extra="forbid")

    apiVersion: str = Field(min_length=1)
    kind: str = Field(min_length=1)
    namespace: str = Field(min_length=1)
    name: str = Field(min_length=1)
    uid: str | None = None
    ready: bool | None = None


class ClaimRef(BaseModel):
    """A KUID Claim the tier created (data-model.md §6).

    ``namespace`` is always ``kuid-system`` — Claims must share a namespace
    with their index (Decision 11). ``allocated_value`` is ``None`` until
    allocated: qualified at the pin (research.md D11) the value is read back
    from the KUID API's entry objects (``ownerReferences[0].name == claim``),
    not the claim status. ``released_at`` is set when the claim is deleted
    on decline or rollback (FR-007, SC-014).

    Every claim carries the ``agentic-netops.io/correlation-id`` label, which is
    what makes SC-014's check a single label-selector query.
    """

    model_config = ConfigDict(extra="forbid")

    name: str = Field(min_length=1)
    namespace: str = "kuid-system"
    index_kind: str = Field(min_length=1)
    index_name: str = Field(min_length=1)
    allocated_value: str | int | None = None
    released_at: datetime | None = None
