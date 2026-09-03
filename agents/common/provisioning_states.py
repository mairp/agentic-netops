"""Provisioning workflow status vocabulary — ported from the subject's
``common/provisioning_states.py`` (verified byte-for-byte in semantics; the
subject's 2-space indents are normalized for ruff).

FR-005 status mapping (research.md Decision 16): this enum is the closed set
that FR-005's required statuses map onto, and the ONLY status vocabulary that
may appear anywhere in the tier — including the NDJSON stream and the chat
surface (data-model.md §8).

    | FR-005 status | Member            | Meaning in this tier                          |
    |---------------|-------------------|-----------------------------------------------|
    | received      | RECEIVED_REQUEST  | request accepted, thread opened               |
    | —             | VALIDATED         | interpretation passed its Pydantic schema     |
    | interpreted   | MAPPED            | interpretation returned, awaiting 1st confirm |
    | assigned      | ALLOCATED         | normalized intent built, awaiting 2nd confirm |
    | approved      | APPROVED          | 2nd confirmation recorded, nothing submitted  |
    | submitting    | PROVISIONING      | dry-run passed, bundle applying               |
    | —             | CONFIGURED        | every object accepted by the API server       |
    | —             | VERIFIED          | every object reported Ready                   |
    | converged     | COMPLETED         | outcome reported to the operator              |
    | failed        | FAILED            | terminal failure, responsible stage named     |
    | —             | STATUS_UNKNOWN    | transport or state loss; never a success      |
"""

from __future__ import annotations

import logging
from enum import Enum

logger = logging.getLogger("agentic_netops.common.logistics_states")


class NetworkProvisioningStatus(Enum):
    RECEIVED_REQUEST = "RECEIVED_REQUEST"
    VALIDATED = "VALIDATED"
    MAPPED = "MAPPED"
    ALLOCATED = "ALLOCATED"  # NEW
    APPROVED = "APPROVED"
    PROVISIONING = "PROVISIONING"
    CONFIGURED = "CONFIGURED"
    VERIFIED = "VERIFIED"
    COMPLETED = "COMPLETED"
    FAILED = "FAILED"
    STATUS_UNKNOWN = "STATUS_UNKNOWN"


# Lowercase lookup map -> canonical enum
STATUS_LOOKUP = {s.value: s for s in NetworkProvisioningStatus}


def extract_status(message: str) -> NetworkProvisioningStatus | None:
    """Extract the provisioning status from a given message string.

    Returns the corresponding NetworkProvisioningStatus enum member if found,
    else STATUS_UNKNOWN (the subject's behaviour is preserved).
    """
    if "IDLE" not in message:
        logger.info(f"Extracting status from message: {message}")

    for key, status in STATUS_LOOKUP.items():
        if key in message:
            return status
    return NetworkProvisioningStatus.STATUS_UNKNOWN
