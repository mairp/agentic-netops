"""The allocator's output — ``NormalizedServiceIntent`` (data-model.md §3).

FR-011: no second translator — this model mirrors the Go side's
``pkg/migration`` ServiceInput exactly (wire names and validation rules),
now in the datacenter construct vocabulary: ``vlan``, ``mac-vrf``,
``ip-vrf``, ``acl``.

Strictness parity (T068–T070):

- every model sets ``model_config = ConfigDict(extra="forbid")`` because
  the Go decoder rejects unknown fields;
- :meth:`NormalizedServiceIntent.validate_all_or_nothing` mirrors
  ``pkg/migration/input.go`` ``ValidateAllOrNothing`` construct by
  construct — required/forbidden variables, endpoint minima, the reserved
  VLAN band 4001–4094 and the L3VNI band 10000–14094;
- the four construct literals are used verbatim.

No identifier in this model may be locally generated: every ``l2vni``,
``l3vni``, and ``rd``/RT value must trace to the cluster allocation authority.
"""

from __future__ import annotations

from dataclasses import dataclass, field

from pydantic import BaseModel, ConfigDict, Field


class RdRt(BaseModel):
    """Route distinguisher + route-targets (VPNs only)."""

    model_config = ConfigDict(extra="forbid")

    rd: str = Field(min_length=1)
    importRT: list[str] = Field(default_factory=list)
    exportRT: list[str] = Field(default_factory=list)


class AddressFamilies(BaseModel):
    """AFI-specific properties for ip-vrf (at least one prefix overall)."""

    model_config = ConfigDict(extra="forbid")

    ipv4Prefixes: list[str] = Field(default_factory=list)
    ipv6Prefixes: list[str] = Field(default_factory=list)


class Endpoint(BaseModel):
    """One attachment point on a target node.

    ``{node, attachment, vlan?}`` for L2 constructs (vlan, mac-vrf);
    ``{node, attachment, vrf}`` for ip-vrf — which of vlan/vrf applies is
    enforced per construct in :meth:`NormalizedServiceIntent.validate_all_or_nothing`.
    """

    model_config = ConfigDict(extra="forbid")

    node: str = Field(min_length=1)
    attachment: str = Field(min_length=1)
    vlan: int | None = Field(default=None, ge=1, le=4094)
    vrf: str | None = None


class AnycastGateway(BaseModel):
    """mac-vrf anycast gateway (symmetric IRB) — optional.

    When present, mac-vrf requires an ``l3vni`` and the gateway SVI carries
    at least one of these addresses inside the ip-vrf the service routes into.
    """

    model_config = ConfigDict(extra="forbid")

    ipVrf: str | None = None
    gatewayIPv4: str = ""
    gatewayIPv6: str = ""


class Policies(BaseModel):
    model_config = ConfigDict(extra="forbid")

    # legacy VPWS mapping (kept for parity with the Go validator; has no effect for constructs)
    vpwsLimitedEquivalence: bool = False


class UnsupportedClaims(BaseModel):
    """Explicitly modeled unsupported features (FR-011)."""

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
        return [name for name in ("tePolicy", "pseudowireOAM", "controlWord", "multicastVPN",
                                  "complexQoS", "serviceChain", "rawCLI") if getattr(self, name) is not None]


@dataclass
class ValidationError:
    causes: list[str] = field(default_factory=list)

    def __str__(self) -> str:
        return f"validation failed: {', '.join(self.causes)}"


class NormalizedServiceIntent(BaseModel):
    """The normalized service-intent contract (data-model.md §3)."""

    model_config = ConfigDict(extra="forbid")

    # Identity
    serviceId: str = Field(min_length=1)
    # vlan | mac-vrf | ip-vrf | acl — construct literals
    type: str
    tenant: str = Field(min_length=1)

    # VPN properties
    rdRt: RdRt | None = None
    l2vni: int | None = Field(default=None, ge=1)
    l3vni: int | None = Field(default=None, ge=1)
    addressFamilies: AddressFamilies | None = None

    # mac-vrf anycast gateway (symmetric IRB)
    anycastGateway: AnycastGateway | None = None

    # Endpoints
    endpoints: list[Endpoint]

    # Explicit policy opt-ins / explicitly modeled unsupported features
    policies: Policies | None = None
    unsupported: UnsupportedClaims | None = None

    # ------------------------------------------------------------------
    # Validation — mirrors pkg/migration/input.go ValidateAllOrNothing.
    # Returns None when valid, a ValidationError otherwise.
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

        t = self.type
        if t == "vlan":
            # Wrong-construct variables
            if self.l2vni:
                causes.append("l2vni: a vlan is local to the node; ask for a mac-vrf to extend it over the fabric")
            if self.l3vni:
                causes.append("l3vni: a vlan carries no routed instance; ask for an ip-vrf, or a mac-vrf with an anycastGateway")
            if self.rdRt is not None:
                causes.append("rdRt: a vlan is not advertised by EVPN and has no route distinguisher or targets")
            if self.anycastGateway is not None:
                causes.append("anycastGateway: only a mac-vrf carries an anycast gateway")
            if len(self.endpoints) < 1:
                causes.append("endpoints: vlan requires >=1 endpoint")
            # VLAN required on every endpoint and reserved band refusal; equality across endpoints
            vlan = 0
            for i, ep in enumerate(self.endpoints):
                if not ep.vlan:
                    causes.append(f"endpoints[{i}].vlan: required for vlan")
                else:
                    if ep.vlan > 4000:
                        causes.append(f"endpoints[{i}].vlan: {ep.vlan} is reserved (4001-4094); usable range is 1-4000")
                    if vlan == 0:
                        vlan = ep.vlan
                    elif ep.vlan != vlan:
                        causes.append(
                            f"endpoints[{i}].vlan: vlan is one bridge domain, so every endpoint must share one vlan (got {vlan} and {ep.vlan})"
                        )
        elif t == "mac-vrf":
            if not self.l2vni:
                causes.append("l2vni: required for mac-vrf")
            if self.rdRt is None:
                causes.append("rdRt: required for mac-vrf")
            min_eps = 2
            if self.anycastGateway is not None:
                min_eps = 1
            if len(self.endpoints) < min_eps:
                causes.append(f"endpoints: mac-vrf requires >={min_eps} endpoints")
            # Reserved VLAN band and vlan presence / equality across endpoints
            vlan = 0
            for i, ep in enumerate(self.endpoints):
                if not ep.vlan:
                    causes.append(f"endpoints[{i}].vlan: required for mac-vrf")
                else:
                    if ep.vlan > 4000:
                        causes.append(f"endpoints[{i}].vlan: {ep.vlan} is reserved (4001-4094); usable range is 1-4000")
                    if vlan == 0:
                        vlan = ep.vlan
                    elif ep.vlan != vlan:
                        causes.append(
                            f"endpoints[{i}].vlan: mac-vrf is one bridge domain, so every endpoint must share one vlan (got {vlan} and {ep.vlan})"
                        )
            # anycastGateway requires l3vni in the ip-vrf it routes into
            if self.anycastGateway is not None:
                if not self.l3vni:
                    causes.append("l3vni: required for a mac-vrf with an anycastGateway (the ip-vrf it routes into)")
                if not (10000 <= (self.l3vni or 0) <= 14094):
                    causes.append(
                        f"l3vni: {self.l3vni} has no derivable service VLAN; this fabric renders L3VNIs in 10000-14094"
                    )
            elif self.l3vni:
                causes.append("l3vni: a mac-vrf carries an L3VNI only when it declares an anycastGateway")
        elif t == "ip-vrf":
            if not self.l3vni:
                causes.append("l3vni: required for ip-vrf")
            if not (self.l3vni is None or 10000 <= self.l3vni <= 14094):
                causes.append(
                    f"l3vni: {self.l3vni} has no derivable service VLAN; this fabric renders L3VNIs in 10000-14094"
                )
            if self.rdRt is None:
                causes.append("rdRt: required for ip-vrf")
            af = self.addressFamilies
            if af is None or (len(af.ipv4Prefixes) == 0 and len(af.ipv6Prefixes) == 0):
                causes.append("addressFamilies: at least one prefix is required for ip-vrf")
            if self.l2vni:
                causes.append("l2vni: an ip-vrf carries no bridge domain; ask for a mac-vrf with an anycastGateway to get both")
            if self.anycastGateway is not None:
                causes.append("anycastGateway: belongs to the mac-vrf whose SVI carries it, not to the ip-vrf")
            if len(self.endpoints) < 1:
                causes.append("endpoints: ip-vrf requires >=1 endpoint")
            for i, ep in enumerate(self.endpoints):
                if not ep.vrf:
                    causes.append(f"endpoints[{i}].vrf: required for ip-vrf")
        elif t == "acl":
            if self.l2vni or self.l3vni or self.rdRt is not None or self.anycastGateway is not None:
                causes.append(
                    "acl: an acl binds to ports and carries no VNI, route targets or gateway; attach it to a vlan, mac-vrf or ip-vrf to filter that service"
                )
            if len(self.endpoints) < 1:
                causes.append("endpoints: acl requires >=1 endpoint to bind to")
        else:
            causes.append(f"type: unsupported '{self.type}'")

        if causes:
            return ValidationError(causes=causes)
        return None
