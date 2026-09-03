"""The allocator's output — ``NormalizedServiceIntent`` (data-model.md §3).

This is FR-011's "no second translator": the shape is not invented here, it
is the contract ``pkg/migration`` already consumes — read off
``tests/unit/testdata/migration/supported_*.json`` and parsed by
``migration.ParseStrictBatch``, which rejects unknown fields (contracts/
translator-api.md: "The Python model must be equally strict so the failure
lands at the agent boundary rather than here (FR-017)").

Strictness parity with the Go side (T068-T070):

* every model sets ``model_config = ConfigDict(extra="forbid")`` because
  ``ParseStrictBatch`` rejects unknown fields;
* :meth:`NormalizedServiceIntent.validate_all_or_nothing` mirrors
  ``pkg/migration/input.go`` ``ValidateAllOrNothing`` field for field:
  required ``rdRt`` / VNI per type, ``addressFamilies`` prefixes for L3,
  the ``vpwsLimitedEquivalence`` policy opt-in, and the endpoint rules
  (count + vlan/vrf per type);
* the Go type literals are used verbatim — the translator's IRB type is
  ``L2L3-IRB`` (``pkg/migration/input.go:29``), not ``IRB``.

No identifier in this model may be locally generated: every ``l2vni``,
``l3vni``, and ``rd``/RT value must trace to the cluster allocation authority
(KUID where the pinned server works; Kubernetes Lease fallback for the broken
GENID/EXTCOMM pools).
"""

from __future__ import annotations

from dataclasses import dataclass, field

from pydantic import BaseModel, ConfigDict, Field


class RdRt(BaseModel):
    """Route distinguisher + route-targets (required for every VPN type).

    Values come from KUID claims (Decision 11), never generated locally.
    """

    model_config = ConfigDict(extra="forbid")

    rd: str = Field(min_length=1)
    importRT: list[str] = Field(default_factory=list)
    exportRT: list[str] = Field(default_factory=list)


class AddressFamilies(BaseModel):
    """AFI-specific properties for L3 (at least one prefix overall)."""

    model_config = ConfigDict(extra="forbid")

    ipv4Prefixes: list[str] = Field(default_factory=list)
    ipv6Prefixes: list[str] = Field(default_factory=list)


class Endpoint(BaseModel):
    """One attachment point on a target node.

    ``{node, attachment, vlan?}`` for L2, ``{node, attachment, vrf}`` for
    L3/IRB — which of vlan/vrf applies is enforced per service type in
    :meth:`NormalizedServiceIntent.validate_all_or_nothing`.
    """

    model_config = ConfigDict(extra="forbid")

    node: str = Field(min_length=1)
    attachment: str = Field(min_length=1)
    vlan: int | None = Field(default=None, ge=1, le=4094)
    vrf: str | None = None


class IRBGateway(BaseModel):
    """IRB per-BD gateways (required when type == L2L3-IRB)."""

    model_config = ConfigDict(extra="forbid")

    vrf: str = Field(min_length=1)
    gatewayIPv4: str = Field(min_length=1)
    gatewayIPv6: str = Field(min_length=1)


class Policies(BaseModel):
    """Explicit allow-listed options, passed to the translator unmodified."""

    model_config = ConfigDict(extra="forbid")

    # Must be true to allow VPWS-to-L2VNI limited-equivalence mapping.
    vpwsLimitedEquivalence: bool = False


class UnsupportedClaims(BaseModel):
    """Explicitly modeled unsupported features (FR-011).

    Presence of ANY of these is a terminal validation failure naming the
    property — mirrored from ``pkg/migration/input.go`` so the agent
    boundary rejects with the same causes the translator would.
    """

    model_config = ConfigDict(extra="forbid")

    tePolicy: dict | list | str | int | float | bool | None = None
    pseudowireOAM: dict | list | str | int | float | bool | None = None
    controlWord: dict | list | str | int | float | bool | None = None
    multicastVPN: dict | list | str | int | float | bool | None = None
    complexQoS: dict | list | str | int | float | bool | None = None
    serviceChain: dict | list | str | int | float | bool | None = None
    rawCLI: dict | list | str | int | float | bool | None = None

    @property
    def present(self) -> list[str]:
        """Names of the unsupported claims actually present (Go cause order)."""
        return [name for name in ("tePolicy", "pseudowireOAM", "controlWord", "multicastVPN",
                                  "complexQoS", "serviceChain", "rawCLI")
                if getattr(self, name) is not None]


@dataclass
class ValidationError:
    """Structured rejection with all causes (mirrors the Go ValidationError)."""

    causes: list[str] = field(default_factory=list)

    def __str__(self) -> str:
        return f"validation failed: {', '.join(self.causes)}"


class NormalizedServiceIntent(BaseModel):
    """The normalized service-intent contract (data-model.md §3).

    Field names are the Go JSON wire names (``serviceId``, ``rdRt``,
    ``l2vni``, ...) — this model serializes byte-compatibly with
    ``pkg/migration``'s ``ServiceInput``.
    """

    model_config = ConfigDict(extra="forbid")

    # Identity
    serviceId: str = Field(min_length=1)
    # VPLS | L3VPN | VPWS | L2L3-IRB — the Go literals, verbatim
    type: str
    tenant: str = Field(min_length=1)

    # VPN properties
    rdRt: RdRt | None = None
    l2vni: int | None = Field(default=None, ge=1)
    l3vni: int | None = Field(default=None, ge=1)
    addressFamilies: AddressFamilies | None = None

    # IRB per-BD gateways (when type == L2L3-IRB)
    irbGateway: IRBGateway | None = None

    # Endpoints
    endpoints: list[Endpoint]

    # Explicit policy opt-ins / explicitly modeled unsupported features
    policies: Policies | None = None
    unsupported: UnsupportedClaims | None = None

    # ------------------------------------------------------------------
    # Validation — mirrors pkg/migration/input.go ValidateAllOrNothing
    # (T069: rdRt, VNI, address-family, policy, and endpoint rules).
    # Returns None when valid, a ValidationError with all causes otherwise
    # (all-or-nothing: a single rejection fails the object, nothing partial).
    # ------------------------------------------------------------------
    def validate_all_or_nothing(self, dup_service_id: bool = False) -> ValidationError | None:
        causes: list[str] = []
        if not self.serviceId:
            causes.append("serviceId: required")
        if not self.tenant:
            causes.append("tenant: required")
        if not self.type:
            causes.append("type: required")
        if dup_service_id:
            causes.append(f"collision: duplicate serviceId '{self.serviceId}' in batch")

        # Unsupported claims — any presence is a terminal failure, named
        if self.unsupported is not None:
            for name in self.unsupported.present:
                causes.append(f"unsupported: {name}")

        # Endpoints basics
        if len(self.endpoints) == 0:
            causes.append("endpoints: at least one endpoint is required")

        if self.type == "VPLS":
            if not self.l2vni:
                causes.append("l2vni: required for VPLS")
            if self.rdRt is None:
                causes.append("rdRt: required for VPLS")
            if len(self.endpoints) < 2:
                causes.append("endpoints: VPLS requires >=2 endpoints")
            # All endpoints must specify the same VLAN
            vlan = 0
            for i, ep in enumerate(self.endpoints):
                if not ep.vlan:
                    causes.append(f"endpoints[{i}].vlan: required for VPLS")
                if i == 0:
                    vlan = ep.vlan or 0
                elif ep.vlan and ep.vlan != vlan:
                    causes.append("endpoints.vlan: must be equal across all endpoints for VPLS")
        elif self.type == "L3VPN":
            if not self.l3vni:
                causes.append("l3vni: required for L3VPN")
            if self.rdRt is None:
                causes.append("rdRt: required for L3VPN")
            af = self.addressFamilies
            if af is None or (len(af.ipv4Prefixes) == 0 and len(af.ipv6Prefixes) == 0):
                causes.append("addressFamilies: at least one prefix is required for L3VPN")
            if len(self.endpoints) < 1:
                causes.append("endpoints: L3VPN requires >=1 endpoint")
            for i, ep in enumerate(self.endpoints):
                if not ep.vrf:
                    causes.append(f"endpoints[{i}].vrf: required for L3VPN")
        elif self.type == "VPWS":
            if not self.l2vni:
                causes.append("l2vni: required for VPWS")
            if self.rdRt is None:
                causes.append("rdRt: required for VPWS")
            if len(self.endpoints) != 2:
                causes.append("endpoints: VPWS requires exactly 2 endpoints")
            for i, ep in enumerate(self.endpoints):
                if not ep.vlan:
                    causes.append(f"endpoints[{i}].vlan: required for VPWS")
            if not (self.policies and self.policies.vpwsLimitedEquivalence):
                causes.append("policy: vpwsLimitedEquivalence must be true to allow limited equivalence mapping")
        elif self.type == "L2L3-IRB":
            if not self.l2vni:
                causes.append("l2vni: required for IRB bridge domain")
            if not self.l3vni:
                causes.append("l3vni: required for IRB VRF")
            if self.rdRt is None:
                causes.append("rdRt: required for IRB VRF")
            if self.irbGateway is None:
                causes.append("irbGateway: required for IRB")
            else:
                if not self.irbGateway.vrf:
                    causes.append("irbGateway.vrf: required")
                if not self.irbGateway.gatewayIPv4:
                    causes.append("irbGateway.gatewayIPv4: required")
                if not self.irbGateway.gatewayIPv6:
                    causes.append("irbGateway.gatewayIPv6: required")
            if len(self.endpoints) < 1:
                causes.append("endpoints: IRB requires at least one endpoint")
            for i, ep in enumerate(self.endpoints):
                if not ep.vlan:
                    causes.append(f"endpoints[{i}].vlan: required for IRB")
        else:
            causes.append(f"type: unsupported '{self.type}'")

        if causes:
            return ValidationError(causes=causes)
        return None
