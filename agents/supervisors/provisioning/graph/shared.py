"""Shared types for the provisioning supervisor graph.

Carries the subject's ``graph/shared.py`` (the Agntcy factory accessor,
used by ``graph/tools.py``) plus the Phase 3 additions:

* :class:`RequestClassification` (T085) — the three-way classifier enum.
  The supervisor classifies every request into exactly one member; the
  values are the words the classifier prompt constrains its reply to
  (``prompts/system.py``), and they are the only routing vocabulary the
  ``_supervisor_node`` LLM path accepts (T089). The third class is
  "unsupported/unsafe" (FR-001's third class, plan.md §2): anything
  outside the declarative contract — including every direct-device
  request (FR-027) — lands here and is refused.
* :func:`new_request_nonce` (T093) — per-request nonce generation for the
  FR-028 data blocks (``prompts/system.py`` ``wrap_user_text`` /
  ``wrap_worker_text``). One nonce per request, 128 bits of CSPRNG
  entropy, so a fenced block is bound to the request it fences and cannot
  be replayed across requests.
* :class:`Decision` — data-model.md §1's confirmation decision
  (``{decided, at, principal}``); the deployer's submission preconditions
  read ``confirmation_2.decided == "confirm"`` (T125).
"""

from __future__ import annotations

import secrets
from datetime import datetime
from enum import StrEnum
from typing import Literal

from agntcy_app_sdk.factory import AgntcyFactory
from pydantic import BaseModel, ConfigDict, Field


# ---------------------------------------------------------------------------
# T085 — request classifier enum (the three-way vocabulary).
# ---------------------------------------------------------------------------
class RequestClassification(StrEnum):
    """The supervisor's three-way classification of an operator request.

    * ``PROVISIONABLE`` — a declarative service request; route to the
      mapper (T086 semantics).
    * ``INFORMATIONAL`` — a question / status or capability inquiry;
      answer from the scoped general-info path, no pipeline (T087).
    * ``UNSUPPORTED`` — outside the contract or unsafe: direct device
      action, no-fabric-equivalent construct, or a redirect attempt.
      Refused with the supported declarative equivalent named (T088,
      FR-012, FR-027).

    The members' values are the single words the classifier prompt
    constrains its reply to; ``_supervisor_node`` (T089) parses the
    model's reply against this enum and accepts nothing else.
    """

    PROVISIONABLE = "provisionable"
    INFORMATIONAL = "informational"
    UNSUPPORTED = "unsupported"


# ---------------------------------------------------------------------------
# T093 — per-request nonce generation (FR-028 data blocks).
# ---------------------------------------------------------------------------
NONCE_BYTES = 16  # 128 bits — a replay across requests is infeasible


def new_request_nonce() -> str:
    """Generate a fresh per-request nonce (T093).

    Returns 32 lowercase hex characters (16 CSPRNG bytes). A new nonce is
    generated per request and per worker call (the mapper's user-text
    fence and the allocator's worker-text fence each carry their own),
    binding every fenced data block to exactly one use site.
    """
    return secrets.token_hex(NONCE_BYTES)


# ---------------------------------------------------------------------------
# Decision — data-model.md §1 (FR-006 confirmation record).
# ---------------------------------------------------------------------------
class Decision(BaseModel):
    """One operator decision at a confirmation point (data-model.md §1).

    ``decided`` is the closed set ``confirm | decline``. The deployer's
    submission preconditions (T124/T125) require
    ``workflow_status == APPROVED`` AND ``confirmation_2.decided == "confirm"``.
    """

    model_config = ConfigDict(extra="forbid")

    decided: Literal["confirm", "decline"]
    at: datetime
    principal: str = Field(min_length=1)


# ---------------------------------------------------------------------------
# Agntcy factory accessor — ported unchanged in shape from the subject's
# graph/shared.py (the supervisor's A2A call helpers in graph/tools.py
# hard-require the SLIM transport through this factory).
# ---------------------------------------------------------------------------
_factory: AgntcyFactory | None = None


def set_factory(factory: AgntcyFactory) -> None:
    """Inject a factory (tests, or the transport bootstrap)."""
    global _factory
    _factory = factory


def get_factory() -> AgntcyFactory:
    """The supervisor's Agntcy factory (created on first use)."""
    global _factory
    if _factory is None:
        _factory = AgntcyFactory("devnet.provisioning_supervisor", enable_tracing=True)
    return _factory
