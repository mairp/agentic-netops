"""The mapper's output — ``Interpretation`` (data-model.md §2).

The artifact the operator confirms first, and the "published schema" of
FR-009. Validated against the subject's ``NetworkMapping`` shape
("agents/provisioning/mapper/agent.py"), extended with the fields this
feature requires. FR-009's minimum — service type, tenant, endpoint list,
generated service identifier — is the required set here; validation is a
precondition for routing onward, not a post-hoc check.
"""

from __future__ import annotations

import ipaddress
import re
from enum import StrEnum
from typing import Any, Literal

from pydantic import BaseModel, ConfigDict, Field, field_validator, model_validator

# RFC 1123 label: DNS-label rules for the tenant name (FR-010: required,
# never defaulted).
_RFC1123 = re.compile(r"^[a-z0-9]([-a-z0-9]*[a-z0-9])?$")


class ServiceType(StrEnum):
    """Datacenter construct vocabulary (FR-001).

    The operator-visible service types are the four constructs used across
    the stack: ``vlan``, ``mac-vrf``, ``ip-vrf``, ``acl``. Legacy
    service-provider names (VPLS, VPWS, L3VPN, IRB) are accepted on input
    and folded to these constructs by a pre-validator (FR-002, migration
    Canonicalize parity).
    """

    VLAN = "vlan"
    MAC_VRF = "mac-vrf"
    IP_VRF = "ip-vrf"
    ACL = "acl"


# Map folded keys to canonical constructs and record legacy/alias spellings
_CANONICAL_TYPES: dict[str, ServiceType] = {
    "vlan": ServiceType.VLAN,
    "macvrf": ServiceType.MAC_VRF,
    "l2vni": ServiceType.MAC_VRF,
    "ipvrf": ServiceType.IP_VRF,
    "l3vni": ServiceType.IP_VRF,
    "acl": ServiceType.ACL,
    "accesslist": ServiceType.ACL,
    # legacy aliases (feature 001 migration sources)
    "vpls": ServiceType.MAC_VRF,
    "vpws": ServiceType.MAC_VRF,
    "eline": ServiceType.MAC_VRF,
    "l3vpn": ServiceType.IP_VRF,
    "l2l3irb": ServiceType.MAC_VRF,
    "irb": ServiceType.MAC_VRF,
}


def _type_key(s: str) -> str:
    """Fold case and separators (FR-002)."""
    out: list[str] = []
    for ch in s.lower():
        if ch in "-_ .+":
            continue
        out.append(ch)
    return "".join(out)


class EndpointIntent(BaseModel):
    """One requested attachment point (data-model.md §2).

    ``{site_or_node, attachment, vlan?}`` — vlan is optional at the
    interpretation stage; the allocator resolves it (or rejects it).
    """

    model_config = ConfigDict(extra="forbid")

    site_or_node: str = Field(min_length=1)
    attachment: str = Field(min_length=1)
    vlan: int | None = Field(default=None, ge=1, le=4094)


class ACLRule(BaseModel):
    model_config = ConfigDict(extra="forbid")
    name: str = Field(min_length=1)
    priority: int = Field(ge=2, le=65535)
    action: Literal["permit", "deny"]
    protocol: str | int | None = None
    sourcePrefix: str | None = None
    destinationPrefix: str | None = None
    sourcePort: str | None = None
    destinationPort: str | None = None
    description: str | None = None


class ACL(BaseModel):
    model_config = ConfigDict(extra="forbid")
    name: str | None = None
    stage: Literal["ingress", "egress"]
    type: Literal["l3", "l3v6"]
    # contracts/interpretation.schema.json names this property "default_action"
    # (the normalized intent's camelCase defaultAction is the Go wire name and
    # lives on common.schemas.normalized_intent.ACL, not here).
    default_action: Literal["permit", "deny"] | None = None
    rules: list[ACLRule]


class AnycastGatewayIntent(BaseModel):
    """The gateway an operator asked a ``mac-vrf`` to route (US3, FR-008).

    Present iff the operator asked the mac-vrf to route; its presence is what
    makes the service symmetric IRB. At least one family is required and an
    unrequested family is never added (contracts/interpretation.schema.json
    ``anycast_gateway``).
    """

    model_config = ConfigDict(extra="forbid", populate_by_name=True)

    ipv4: str | None = None
    ipv6: str | None = None

    @model_validator(mode="after")
    def _at_least_one_family(self) -> AnycastGatewayIntent:
        if self.ipv4 is None and self.ipv6 is None:
            raise ValueError(
                "anycast_gateway: name at least one of ipv4/ipv6 — a gateway with no address routes nothing"
            )
        return self


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
    # Provenance of a legacy alias (optional): e.g. "VPLS" → service_type "mac-vrf".
    source_service_type: str | None = None
    tenant: str
    # FR-011: endpoints minimum lowered to 1 for constructs (vlan, ip-vrf, acl)
    endpoints: list[EndpointIntent] = Field(min_length=1)

    # Optional, absence is not a blocker (data-model.md §2)
    bandwidth: str | None = None
    sla: str | None = None
    ipv4_prefixes: list[str] = Field(default_factory=list)
    ipv6_prefixes: list[str] = Field(default_factory=list)

    # ACL model (US2 T046): required when service_type == acl
    acl: ACL | None = None

    # mac-vrf anycast gateway (US3 T055): refused on every other construct
    anycast_gateway: AnycastGatewayIntent | None = None

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

    @model_validator(mode="before")
    @classmethod
    def _record_source_alias(cls, data: Any) -> Any:
        # Provenance (US4): when the operator named a legacy alias, record what
        # they said before the fold. Only a true alias is recorded — a
        # differently-formatted construct name ("MAC VRF") is not one.
        if isinstance(data, dict):
            raw = data.get("service_type")
            if isinstance(raw, str) and raw and not data.get("source_service_type"):
                if _CANONICAL_TYPES.get(_type_key(raw)) is not None:
                    canonical_key = _type_key(_CANONICAL_TYPES[_type_key(raw)].value)
                    if _type_key(raw) != canonical_key:
                        data["source_service_type"] = raw
        return data

    @field_validator("service_type", mode="before")
    @classmethod
    def _fold_service_type(cls, v: ServiceType | str) -> ServiceType:
        # Accept enum or string; fold strings (case/separators) and legacy aliases
        if isinstance(v, ServiceType):
            return v
        key = _type_key(str(v))
        st = _CANONICAL_TYPES.get(key)
        if st is None:
            raise ValueError(
                f"unsupported service_type {v!r}; constructs are: vlan, mac-vrf, ip-vrf, acl"
            )
        return st

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

    @model_validator(mode="after")
    def _gateway_scoped_to_mac_vrf(self) -> Interpretation:
        """US3 (T055): only a mac-vrf carries an anycast gateway.

        Naming one on ``vlan``, ``ip-vrf`` or ``acl`` is refused here, before
        the request can route, so the operator is never asked to restate the
        request as a different service — the composition is the feature.
        """
        if self.anycast_gateway is not None and self.service_type != ServiceType.MAC_VRF:
            raise ValueError(
                f"anycast_gateway: only a mac-vrf carries an anycast gateway "
                f"(got service_type {self.service_type.value!r})"
            )
        return self

    @model_validator(mode="after")
    def _acl_required_and_bounded(self) -> Interpretation:
        # When the construct is acl, require the acl field and bound rule shapes
        if self.service_type == ServiceType.ACL:
            if self.acl is None:
                raise ValueError("acl: required when service_type == acl")
            # Enforce protocol enum excluding icmpv6 at interpretation time when protocol is str
            for i, r in enumerate(self.acl.rules):
                if isinstance(r.protocol, str):
                    p = r.protocol.strip().lower()
                    allowed = {"any", "tcp", "udp", "icmp", "igmp", "rsvp", "gre", "ah", "pim", "l2tp"}
                    if p and p not in allowed and not p.isdigit():
                        raise ValueError(
                            f"acl.rules[{i}].protocol: one of any, tcp, udp, icmp, igmp, rsvp, "
                            f"gre, ah, pim, l2tp or a numeric IP protocol 0-255 (got "
                            f"{r.protocol!r})"
                        )
                    if p in {"icmpv6", "ipv6-icmp"}:
                        raise ValueError(
                            f"acl.rules[{i}].protocol: icmpv6 is not supported by the pinned image"
                        )
        return self

    @property
    def is_complete(self) -> bool:
        """True when the interpretation carries no terminal flag and may be
        routed onward (to the first confirmation, then the allocator)."""
        return not self.missing_fields and not self.unsupported_properties
