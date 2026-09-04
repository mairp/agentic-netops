"""The mapper's output — ``Interpretation`` (data-model.md §2).

The artifact the operator confirms first, and the "published schema" of
FR-009. Validated against the subject's ``NetworkMapping`` shape
(``agents/provisioning/mapper/agent.py:32-50``), extended with the fields
this feature requires. FR-009's minimum — service type, tenant, endpoint
list, generated service identifier — is the required set here; validation
is a precondition for routing onward, not a post-hoc check.
"""

from __future__ import annotations

import ipaddress
import re
from enum import StrEnum

from pydantic import BaseModel, ConfigDict, Field, field_validator, model_validator

# RFC 1123 label: DNS-label rules for the tenant name (FR-010: required,
# never defaulted).
_RFC1123 = re.compile(r"^[a-z0-9]([-a-z0-9]*[a-z0-9])?$")


class ServiceType(StrEnum):
    """The set feature 001 can express (001:plan.md Component 7).

    Not extensible by this feature: a ``service_type`` outside the enum is
    a rejection, never a coercion (data-model.md §2). Note the mapper's
    vocabulary: the allocator maps ``IRB`` onto the translator's
    ``L2L3-IRB`` type (normalized_intent.py).
    """

    VPLS = "VPLS"
    VPWS = "VPWS"
    L3VPN = "L3VPN"
    IRB = "IRB"


class EndpointIntent(BaseModel):
    """One requested attachment point (data-model.md §2).

    ``{site_or_node, attachment, vlan?}`` — vlan is optional at the
    interpretation stage; the allocator resolves it (or rejects it).
    """

    model_config = ConfigDict(extra="forbid")

    site_or_node: str = Field(min_length=1)
    attachment: str = Field(min_length=1)
    vlan: int | None = Field(default=None, ge=1, le=4094)


class Interpretation(BaseModel):
    """FR-009's published interpretation schema (required set below).

    ``missing_fields`` and ``unsupported_properties`` are each terminal for
    the pipeline (data-model.md §2, FR-010 / FR-012):

    * ``missing_fields`` non-empty  => clarification request, not an
      interpretation; the supervisor must not route to the allocator.
    * ``unsupported_properties`` non-empty => rejection with the properties
      named; NO partial assignment may follow (SC-003).
    * the two are mutually exclusive with each other: a message is either a
      clarification request or a rejection, never both (T067).
    """

    model_config = ConfigDict(extra="forbid")

    # FR-009 minimum — required, no defaults (FR-010: tenant never defaulted)
    service_id: str = Field(min_length=1, max_length=15)
    service_type: ServiceType
    tenant: str
    endpoints: list[EndpointIntent] = Field(min_length=2)

    # Optional, absence is not a blocker (data-model.md §2)
    bandwidth: str | None = None
    sla: str | None = None
    ipv4_prefixes: list[str] = Field(default_factory=list)
    ipv6_prefixes: list[str] = Field(default_factory=list)

    # Terminal flags — mutually exclusive with each other (see class docstring)
    missing_fields: list[str] = Field(default_factory=list)
    unsupported_properties: list[str] = Field(default_factory=list)

    @field_validator("tenant")
    @classmethod
    def _tenant_rfc1123(cls, v: str) -> str:
        if not _RFC1123.fullmatch(v):
            raise ValueError(
                f"tenant must be an RFC 1123 label, got {v!r}"
            )
        return v

    @field_validator("ipv4_prefixes")
    @classmethod
    def _valid_ipv4_prefixes(cls, values: list[str]) -> list[str]:
        return cls._valid_prefixes(values, version=4)

    @field_validator("ipv6_prefixes")
    @classmethod
    def _valid_ipv6_prefixes(cls, values: list[str]) -> list[str]:
        return cls._valid_prefixes(values, version=6)

    @staticmethod
    def _valid_prefixes(values: list[str], *, version: int) -> list[str]:
        normalized: list[str] = []
        for value in values:
            try:
                network = ipaddress.ip_network(value, strict=False)
            except ValueError as exc:
                raise ValueError(f"invalid IPv{version} prefix {value!r}") from exc
            if network.version != version:
                raise ValueError(f"expected an IPv{version} prefix, got {value!r}")
            normalized.append(str(network))
        return normalized

    @field_validator("endpoints")
    @classmethod
    def _endpoints_nonempty_fields(cls, v: list[EndpointIntent]) -> list[EndpointIntent]:
        for i, ep in enumerate(v):
            if not ep.site_or_node or not ep.attachment:
                raise ValueError(f"endpoints[{i}]: site_or_node and attachment are required")
        return v

    @model_validator(mode="after")
    def _mutual_exclusion(self) -> Interpretation:
        """T067: missing_fields and unsupported_properties cannot both be
        non-empty — a clarification request and a rejection are different
        terminal outcomes, and naming both would leave the supervisor unable
        to route the thread unambiguously (FR-010 / FR-012)."""
        if self.missing_fields and self.unsupported_properties:
            raise ValueError(
                "missing_fields and unsupported_properties are mutually exclusive: "
                "name either the missing fields (clarification) or the unsupported "
                f"properties (rejection), not both (got missing={self.missing_fields!r}, "
                f"unsupported={self.unsupported_properties!r})"
            )
        return self

    @property
    def is_complete(self) -> bool:
        """True when the interpretation carries no terminal flag and may be
        routed onward (to the first confirmation, then the allocator)."""
        return not self.missing_fields and not self.unsupported_properties
