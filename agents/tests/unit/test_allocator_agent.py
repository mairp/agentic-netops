from __future__ import annotations

from common.schemas.interpretation import Interpretation
from provisioning.allocator.agent import AllocatorAgent


class _FakeKUID:
    def allocate_l3vni(self, _correlation_id: str) -> int:
        return 10018

    def allocate_rd_rt(self, _correlation_id: str) -> tuple[str, list[str], list[str]]:
        return "65000:18", ["65000:18"], ["65000:18"]


def test_l3vpn_preserves_operator_supplied_prefixes():
    allocator = AllocatorAgent.__new__(AllocatorAgent)
    allocator.kuid = _FakeKUID()
    interpretation = Interpretation.model_validate(
        {
            "service_id": "validation-test",
            "service_type": "L3VPN",
            "tenant": "validation-test",
            "endpoints": [
                {"site_or_node": "leaf01", "attachment": "wan1"},
                {"site_or_node": "leaf02", "attachment": "wan1"},
            ],
            "ipv4_prefixes": ["10.99.18.0/24"],
        }
    )

    intent = allocator._build_intent(interpretation, "c" * 32)

    assert intent.addressFamilies is not None
    assert intent.addressFamilies.ipv4Prefixes == ["10.99.18.0/24"]
    assert intent.addressFamilies.ipv6Prefixes == []


class _CountingKUID:
    """Hands out a fresh vlan on every call, the way the real pool does."""

    def __init__(self) -> None:
        self.vlans: list[int] = []
        self.l3vnis: list[int] = []

    def allocate_l2vni(self, _correlation_id: str) -> int:
        return 10004

    def allocate_l3vni(self, _correlation_id: str) -> int:
        # The real pool hands out the 10000-14094 sub-band (KUID_L3VNI_MAX).
        self.l3vnis.append(10000 + len(self.l3vnis))
        return self.l3vnis[-1]

    def allocate_rd_rt(self, _correlation_id: str) -> tuple[str, list[str], list[str]]:
        return "65000:5", ["65000:5"], ["65000:5"]

    def allocate_vlan(self, _correlation_id: str) -> int:
        self.vlans.append(100 + len(self.vlans))
        return self.vlans[-1]


def _interpretation(service_type: str, **extra) -> Interpretation:
    payload = {
        "service_id": "svc1",
        "service_type": service_type,
        "tenant": "acme",
        "endpoints": [
            {"site_or_node": "leaf01", "attachment": "ethernet1"},
            {"site_or_node": "leaf02", "attachment": "ethernet1"},
        ],
    }
    payload.update(extra)
    return Interpretation.model_validate(payload)


def _allocator(kuid) -> AllocatorAgent:
    allocator = AllocatorAgent.__new__(AllocatorAgent)
    allocator.kuid = kuid
    return allocator


def test_every_l2_service_type_lands_on_one_shared_vlan():
    """One bridge domain, one vlan.

    A vlan per endpoint is what made every VPWS and IRB fail at the fabric with
    "references vlan N with no bridgeDomain" — after the objects were already
    submitted and not rolled back.
    """

    for service_type in ("VPLS", "VPWS", "IRB"):
        kuid = _CountingKUID()
        intent = _allocator(kuid)._build_intent(_interpretation(service_type), "c" * 32)
        vlans = {ep.vlan for ep in intent.endpoints}
        assert vlans == {100}, f"{service_type} spread its endpoints over {vlans}"
        assert len(kuid.vlans) == 1, f"{service_type} claimed {len(kuid.vlans)} vlans for one bridge domain"


def test_operator_supplied_vlan_is_used_for_every_endpoint():
    kuid = _CountingKUID()
    interpretation = _interpretation("VPLS")
    interpretation.endpoints[0].vlan = 300
    intent = _allocator(kuid)._build_intent(interpretation, "c" * 32)
    assert {ep.vlan for ep in intent.endpoints} == {300}
    assert kuid.vlans == [], "a vlan was allocated even though the operator named one"


def test_two_different_requested_vlans_are_a_rejection_not_a_guess():
    interpretation = _interpretation("VPWS")
    interpretation.endpoints[0].vlan = 300
    interpretation.endpoints[1].vlan = 301
    try:
        _allocator(_CountingKUID())._build_intent(interpretation, "c" * 32)
    except ValueError as exc:
        assert "one vlan" in str(exc)
        assert "300" in str(exc) and "301" in str(exc)
    else:
        raise AssertionError("the allocator silently picked one of two requested vlans")


def test_macvrf_gateway_carries_the_addresses_the_operator_named():
    """The gateway carries exactly the addresses the operator named.

    A mac-vrf asks for a gateway by naming it on the same request; there is no
    fifth service name and no address invented from an unrelated prefix pool.
    """

    intent = _allocator(_CountingKUID())._build_intent(
        _interpretation(
            "mac-vrf",
            anycast_gateway={"ipv4": "10.30.0.1/24", "ipv6": "fd00:30::1/64"},
        ),
        "c" * 32,
    )
    assert intent.anycastGateway is not None
    assert intent.anycastGateway.gatewayIPv4 == "10.30.0.1/24"
    assert intent.anycastGateway.gatewayIPv6 == "fd00:30::1/64"


def test_gateway_carries_only_the_address_families_that_were_asked_for():
    """An IPv4-only request gets an IPv4-only gateway.

    Handing every gateway a fd00::1/64 address put an address family on the
    SVI that nobody requested, asked FRR to originate a Type-5 route for it,
    and then held the service to that route — which is how an IPv4 gateway
    failed to converge on a leaf whose zebra registered the address as a
    kernel rather than a connected route.
    """

    intent = _allocator(_CountingKUID())._build_intent(
        _interpretation("mac-vrf", anycast_gateway={"ipv4": "10.30.0.1/24"}), "c" * 32
    )
    assert intent.anycastGateway.gatewayIPv4 == "10.30.0.1/24"
    assert intent.anycastGateway.gatewayIPv6 == ""

    v6_only = _allocator(_CountingKUID())._build_intent(
        _interpretation("mac-vrf", anycast_gateway={"ipv6": "fd00:30::1/64"}), "c" * 32
    )
    assert v6_only.anycastGateway.gatewayIPv4 == ""
    assert v6_only.anycastGateway.gatewayIPv6 == "fd00:30::1/64"

    # A gateway naming no family at all is refused before anything is claimed.
    try:
        _allocator(_CountingKUID())._build_intent(
            _interpretation("mac-vrf", anycast_gateway={}), "c" * 32
        )
    except Exception as exc:
        assert "at least one of ipv4/ipv6" in str(exc)
    else:
        raise AssertionError("a gateway with no address was accepted")


def test_l3vni_is_claimed_only_when_a_macvrf_declares_a_gateway():
    """Routing is composition, not implication (US3, claim profiles §2).

    A gatewayless mac-vrf claims VLAN + L2VNI + RT and never an L3VNI; the
    same construct with a gateway claims the L3VNI from the 10000-14094
    sub-band; and a vlan or an acl claims no L3 identifier at all.
    """

    gatewayless = _allocator(_CountingKUID())._build_intent(
        _interpretation("mac-vrf"), "c" * 32
    )
    assert gatewayless.l3vni is None, "a gatewayless mac-vrf claimed an L3VNI"

    routed_kuid = _CountingKUID()
    routed = _allocator(routed_kuid)._build_intent(
        _interpretation("mac-vrf", anycast_gateway={"ipv4": "10.30.0.1/24"}), "c" * 32
    )
    assert routed.l3vni is not None
    assert 10000 <= routed.l3vni <= 14094, "L3VNI left the KUID_L3VNI sub-band"
    assert len(routed_kuid.l3vnis) == 1

    vlan_kuid = _CountingKUID()
    vlan_intent = _allocator(vlan_kuid)._build_intent(
        _interpretation("vlan"), "c" * 32
    )
    assert vlan_intent.l3vni is None
    assert vlan_kuid.l3vnis == [], "a vlan claimed an L3VNI"


def test_anycast_gateway_is_refused_on_every_other_construct():
    """The gateway belongs to the mac-vrf whose SVI carries it.

    Naming it on a vlan, an ip-vrf or an acl is refused at the interpretation
    boundary — before anything routes — with the construct named.
    """

    for service_type in ("vlan", "ip-vrf", "acl"):
        payload = {
            "service_id": "svc-gw",
            "service_type": service_type,
            "tenant": "acme",
            "endpoints": [{"site_or_node": "leaf01", "attachment": "ethernet1"}],
            "anycast_gateway": {"ipv4": "10.30.0.1/24"},
        }
        if service_type == "acl":
            payload["acl"] = {
                "stage": "ingress",
                "type": "l3",
                "rules": [
                    {
                        "name": "allow-web",
                        "priority": 100,
                        "action": "permit",
                        "protocol": "tcp",
                        "destinationPort": "80",
                    }
                ],
            }
        try:
            Interpretation.model_validate(payload)
        except Exception as exc:
            assert "only a mac-vrf carries an anycast gateway" in str(exc), service_type
        else:
            raise AssertionError(f"{service_type} accepted an anycast gateway")


def test_vlan_claim_profile_strands_no_l2vni():
    allocator = _allocator(_CountingKUID())
    interpretation = Interpretation.model_validate(
        {
            "service_id": "svc-vlan",
            "service_type": "vlan",
            "tenant": "acme",
            "endpoints": [
                {"site_or_node": "leaf01", "attachment": "ethernet1"}
            ],
        }
    )
    intent = allocator._build_intent(interpretation, "c" * 32)
    assert intent.type == "vlan"
    assert intent.l2vni is None
    assert intent.rdRt is None



def test_a_standalone_acl_carries_its_rules_into_the_normalized_intent():
    """The filter is the request; an acl intent without it deploys nothing.

    The allocator built the acl intent from serviceId/type/tenant/endpoints and
    dropped ``interpretation.acl`` on the floor, so the rules an operator
    confirmed never reached the deployer. The one wire-name difference between
    the two contracts (``default_action`` -> ``defaultAction``) is translated
    here, not guessed at downstream.
    """

    interpretation = Interpretation.model_validate(
        {
            "service_id": "svc-acl",
            "service_type": "acl",
            "tenant": "acme",
            "endpoints": [{"site_or_node": "leaf01", "attachment": "wan1"}],
            "acl": {
                "stage": "ingress",
                "type": "l3",
                "default_action": "deny",
                "rules": [
                    {
                        "name": "rule-1",
                        "priority": 100,
                        "action": "permit",
                        "protocol": "tcp",
                        "destinationPort": "443",
                        "sourcePrefix": "10.0.0.0/24",
                    }
                ],
            },
        }
    )

    intent = _allocator(_CountingKUID())._build_intent(interpretation, "c" * 32)

    assert intent.acl is not None, "the access list was dropped between the mapper and the deployer"
    assert intent.acl.stage == "ingress"
    assert intent.acl.defaultAction == "deny"
    assert [r.model_dump(exclude_none=True) for r in intent.acl.rules] == [
        {
            "name": "rule-1",
            "priority": 100,
            "action": "permit",
            "protocol": "tcp",
            "destinationPort": "443",
            "sourcePrefix": "10.0.0.0/24",
        }
    ]
    assert intent.validate_all_or_nothing() is None


class _ZeroClaimKUID:
    """A KUID client that records every allocate call — srv6 must claim no
    VXLAN identifier (vlan/l2vni/l3vni/rdRt), and mac-vrf must claim nothing
    at all."""

    def __init__(self) -> None:
        self.calls: list[str] = []

    def allocate_vlan(self, _correlation_id: str) -> int:
        self.calls.append("vlan")
        return 100

    def allocate_l2vni(self, _correlation_id: str) -> int:
        self.calls.append("l2vni")
        return 10004

    def allocate_l3vni(self, _correlation_id: str) -> int:
        self.calls.append("l3vni")
        return 10018

    def allocate_rd_rt(self, _correlation_id: str) -> tuple[str, list[str], list[str]]:
        self.calls.append("rd_rt")
        return "65000:18", ["65000:18"], ["65000:18"]

    def allocate_client_prefix(self, *, correlation_id: str, attachment: str) -> str:
        self.calls.append(f"client_prefix:{attachment}")
        raise AssertionError("this fake must not be asked for a client /24")


class _ClaimingKUID(_ZeroClaimKUID):
    """Serves the measured client /24s the lab pool hands out in order."""

    def allocate_client_prefix(self, *, correlation_id: str, attachment: str) -> str:
        self.calls.append(f"client_prefix:{attachment}")
        return {
            "leaf01-wan1": "192.168.1.0/24",
            "leaf02-wan1": "192.168.2.0/24",
        }[attachment]


def _srv6_interpretation(service_type: str, **extra) -> Interpretation:
    payload = {
        "service_id": "svc-srv6",
        "service_type": service_type,
        "tenant": "acme",
        "transport": "srv6",
        "endpoints": [
            {"site_or_node": "leaf01", "attachment": "wan1"},
            {"site_or_node": "leaf02", "attachment": "wan1"},
        ],
    }
    payload.update(extra)
    return Interpretation.model_validate(payload)


def test_srv6_ip_vrf_claims_no_vxlan_identifier_but_claims_client_prefixes():
    """US4 ip-vrf claim profile: no VXLAN identifier is claimed, but each
    attachment's gateway /24 IS (SRv6Service CRD rule A9 via intent-srv6.md §4:
    endpoints[].prefixes → spec.attachments[].gateway).

    srv6 identifiers are fabric-allocated: the intent carries type, tenant and
    endpoints with no l2vni, no l3vni and no rdRt. The gateway prefixes are
    claimed, never invented: one client /24 per attachment, keyed the way the
    srv6-controller's claim name keys it (<node>-<port>), and the endpoint
    carries the claimed subnet's first usable host — the x.y.z.1/n convention
    (.1 the leaf SVI, .2 the client the data-path probe pings).
    """

    kuid = _ClaimingKUID()
    intent = _allocator(kuid)._build_intent(
        _srv6_interpretation("ip-vrf", ipv6_prefixes=["2001:db8:3::30/127"]), "c" * 32
    )
    assert sorted(kuid.calls) == [
        "client_prefix:leaf01-wan1",
        "client_prefix:leaf02-wan1",
    ], f"expected exactly the two attachment /24 claims, got: {kuid.calls}"
    assert intent.type == "ip-vrf"
    assert intent.tenant == "acme"
    assert len(intent.endpoints) == 2
    assert intent.l2vni is None
    assert intent.l3vni is None
    assert intent.rdRt is None
    assert intent.transport == "srv6"
    assert intent.signalling == "vpn"
    gateways = {ep.node: ep.prefixes for ep in intent.endpoints}
    assert gateways == {
        "leaf01": ["192.168.1.1/24"],
        "leaf02": ["192.168.2.1/24"],
    }, f"endpoints must carry the claimed gateway prefixes, got: {gateways}"
    assert intent.validate_all_or_nothing() is None


def test_srv6_mac_vrf_claims_nothing_and_carries_the_named_vlan():
    kuid = _ZeroClaimKUID()
    interp = _srv6_interpretation(
        "mac-vrf", signalling="evpn", preferredSpine="spine01"
    )
    interp.endpoints[0].vlan = 300
    interp.endpoints[1].vlan = 300
    intent = _allocator(kuid)._build_intent(interp, "c" * 32)
    assert kuid.calls == [], f"srv6 allocation claimed: {kuid.calls}"
    assert intent.type == "mac-vrf"
    assert intent.transport == "srv6"
    assert intent.signalling == "evpn"
    assert intent.preferredSpine == "spine01"
    assert {ep.vlan for ep in intent.endpoints} == {300}, (
        "the operator-named vlan must be carried through, never claimed"
    )
    assert intent.l2vni is None and intent.l3vni is None and intent.rdRt is None
    assert intent.validate_all_or_nothing() is None


def test_srv6_mac_vrf_without_a_named_vlan_still_claims_nothing():
    """No vlan named means no vlan on the intent — never a KUID claim."""
    kuid = _ZeroClaimKUID()
    intent = _allocator(kuid)._build_intent(
        _srv6_interpretation("mac-vrf", signalling="evpn"), "c" * 32
    )
    assert kuid.calls == []
    assert all(ep.vlan is None for ep in intent.endpoints)


def test_transport_none_still_claims_like_vxlan():
    """An interpretation without a transport keeps the VXLAN claim profile."""
    kuid = _ZeroClaimKUID()
    intent = _allocator(kuid)._build_intent(_interpretation("ip-vrf"), "c" * 32)
    assert sorted(kuid.calls) == ["l3vni", "rd_rt"]
    assert intent.transport == "vxlan"
    assert intent.l3vni is not None and intent.rdRt is not None
