"""Shared Pydantic schemas for the intent tier (data-model.md).

Validation is not advisory: FR-017 makes schema rejection the barrier
between an agent and the cluster, so a model that fails to validate ends
its stage in FAILED and submits nothing.
"""

from __future__ import annotations

from .audit import AuditEvent
from .interpretation import EndpointIntent, Interpretation, ServiceType
from .normalized_intent import (
    AddressFamilies,
    Endpoint,
    IRBGateway,
    NormalizedServiceIntent,
    Policies,
    RdRt,
    UnsupportedClaims,
)
from .refs import ClaimRef, ResourceRef

__all__ = [
    "AddressFamilies",
    "AuditEvent",
    "ClaimRef",
    "Endpoint",
    "EndpointIntent",
    "IRBGateway",
    "Interpretation",
    "NormalizedServiceIntent",
    "Policies",
    "RdRt",
    "ResourceRef",
    "ServiceType",
    "UnsupportedClaims",
]
