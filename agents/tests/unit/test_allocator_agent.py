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
                    {"name": "allow-web", "priority": 100, "action": "permit", "protocol": "tcp", "destinationPort": "80"}
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

