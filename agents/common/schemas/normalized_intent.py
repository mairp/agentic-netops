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

import ipaddress
from dataclasses import dataclass, field
from typing import Literal

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
    stage: Literal["ingress", "egress"] | None = None
    type: Literal["l3", "l3v6"] | None = None
    defaultAction: Literal["permit", "deny"] | None = None
    bindTo: str | None = None
    rules: list[ACLRule] | None = None


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

    # Access-list (US2): optional on normalized intent, validated in parity branch
    acl: ACL | None = None

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
                causes.append(
                    "l3vni: a vlan carries no routed instance; ask for an ip-vrf, or a mac-vrf "
                    "with an anycastGateway"
                )
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
                            f"endpoints[{i}].vlan: vlan is one bridge domain, so every endpoint "
                            f"must share one vlan (got {vlan} and {ep.vlan})"
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
                            f"endpoints[{i}].vlan: mac-vrf is one bridge domain, so every "
                            f"endpoint must share one vlan (got {vlan} and {ep.vlan})"
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
                causes.append(
                    "l2vni: an ip-vrf carries no bridge domain; ask for a mac-vrf with an "
                    "anycastGateway to get both"
                )
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
                    "acl: an acl binds to ports and carries no VNI, route targets or gateway; "
                    "attach it to a vlan, mac-vrf or ip-vrf to filter that service"
                )
            if len(self.endpoints) < 1:
                causes.append("endpoints: acl requires >=1 endpoint to bind to")
            # Mirror aclCauses prefix family and port rules for parity (refusal before submit)
            # These are a best-effort mirror; exact messages match Go causes.
            # No defaultAction handling here; reserved priority 1 is per-rule refusal.
            seen_names: set[str] = set()
            seen_prios: set[int] = set()
            a = getattr(self, "acl", None)
            if a:
                # Normalize to a dict view for parity with Go-side messages
                if isinstance(a, BaseModel):
                    ad = a.model_dump(mode="json", by_alias=True)
                else:
                    ad = a  # assume dict-like
                if ad.get("stage") not in ("ingress", "egress"):
                    causes.append(f"acl.stage: required, one of ingress, egress (got {ad.get('stage')!r})")
                if ad.get("type") not in ("l3", "l3v6"):
                    causes.append(f"acl.type: required, one of l3, l3v6 (got {ad.get('type')!r})")
                if ad.get("bindTo") and ad.get("bindTo") != "port":
                    causes.append(
                        f"acl.bindTo: {ad.get('bindTo')!r} is unsupported; an access list binds to ports"
                    )
                rules = ad.get("rules") or []
                if not rules:
                    causes.append("acl.rules: at least one rule is required")
                    if ad.get("name"):
                        causes.append(
                            "acl: a service carries its own rules and its name is a label; "
                            "provide rules instead of referencing by name"
                        )
                for i, r in enumerate(rules):
                    # r may be a dict or a pydantic object; use getattr/[] tolerant access
                    if isinstance(r, BaseModel):
                        rd = r.model_dump(mode="json", by_alias=True)
                    else:
                        rd = r
                    name = str((rd.get("name") if isinstance(rd, dict) else "") or "")
                    if not name:
                        causes.append(f"acl.rules[{i}].name: required")
                    elif name in seen_names:
                        causes.append(f"acl.rules[{i}].name: duplicate rule name {name!r}")
                    else:
                        seen_names.add(name)
                    prio = int((rd.get("priority") if isinstance(rd, dict) else 0) or 0)
                    if prio == 1:
                        causes.append(
                            f"acl.rules[{i}].priority: 1 is reserved for the default action; "
                            f"usable priorities are 2-65535"
                        )
                    elif prio < 2 or prio > 65535:
                        causes.append(f"acl.rules[{i}].priority: must be 2-65535 (got {prio})")
                    elif prio in seen_prios:
                        causes.append(
                            f"acl.rules[{i}].priority: {prio} is already used by another rule; "
                            f"priorities must be distinct"
                        )
                    else:
                        seen_prios.add(prio)
                    action_raw = (rd.get("action") if isinstance(rd, dict) else None)
                    action = str(action_raw or "").lower()
                    if action not in ("permit", "deny"):
                        causes.append(
                            f"acl.rules[{i}].action: required, one of permit, deny (got {action_raw!r})"
                        )
                    proto_raw = rd.get("protocol") if isinstance(rd, dict) else None
                    proto = str(proto_raw or "").lower()
                    if proto and proto not in ("any", "tcp", "udp", "icmp", "igmp", "rsvp", "gre", "ah", "pim", "l2tp"):
                        try:
                            n = int(proto)
                            if n < 0 or n > 255:
                                raise ValueError
                        except Exception:
                            causes.append(
                                f"acl.rules[{i}].protocol: one of any, tcp, udp, icmp, igmp, "
                                f"rsvp, gre, ah, pim, l2tp or an IP protocol number 0-255 (got "
                                f"{proto_raw!r})"
                            )
                    if proto in ("icmpv6", "ipv6-icmp"):
                        causes.append(
                            f"acl.rules[{i}].protocol: one of any, tcp, udp, icmp, igmp, rsvp, "
                            f"gre, ah, pim, l2tp or an IP protocol number 0-255 (got "
                            f"{proto_raw!r})"
                        )
                    # Prefix family check
                    for field in ("sourcePrefix", "destinationPrefix"):
                        prefix = rd.get(field) if isinstance(rd, dict) else None
                        if not prefix:
                            continue
                        try:
                            net = ipaddress.ip_network(str(prefix), strict=False)
                        except Exception:
                            causes.append(f"acl.rules[{i}].{field}: not a CIDR prefix ({prefix!r})")
                            continue
                        if ad.get("type") == "l3" and net.version != 4:
                            causes.append(
                                f"acl.rules[{i}].{field}: {prefix} is IPv6 but the acl type is l3 (IPv4); use type l3v6"
                            )
                        if ad.get("type") == "l3v6" and net.version != 6:
                            causes.append(
                                f"acl.rules[{i}].{field}: {prefix} is IPv4 but the acl type is l3v6; use type l3"
                            )
                    # L4 port rules
                    for field in ("sourcePort", "destinationPort"):
                        port = str((rd.get(field) if isinstance(rd, dict) else "") or "")
                        if not port:
                            continue
                        if proto not in ("tcp", "udp"):
                            causes.append(
                                f"acl.rules[{i}].{field}: L4 ports require protocol tcp or udp (got {proto_raw!r})"
                            )
                            continue
                        if "-" in port:
                            lo, hi = port.split("-", 1)
                            try:
                                lo_n = int(lo.strip())
                                hi_n = int(hi.strip())
                                if lo_n < 0 or lo_n > 65535 or hi_n < 0 or hi_n > 65535:
                                    raise ValueError
                                if hi_n < lo_n:
                                    causes.append(
                                        f"acl.rules[{i}].{field}: range {port!r} ends below where it starts"
                                    )
                            except Exception:
                                causes.append(
                                    f"acl.rules[{i}].{field}: not a port range in 0-65535 ({port!r})"
                                )
                        else:
                            try:
                                n = int(port)
                                if n < 0 or n > 65535:
                                    raise ValueError
                            except Exception:
                                causes.append(
                                    f"acl.rules[{i}].{field}: not a port in 0-65535 ({port!r})"
                                )
        else:
            causes.append(f"type: unsupported '{self.type}'")

        if causes:
            return ValidationError(causes=causes)
        return None
