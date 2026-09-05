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

    def allocate_l2vni(self, _correlation_id: str) -> int:
        return 10004

    def allocate_l3vni(self, _correlation_id: str) -> int:
        return 10006

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


def test_irb_gateway_comes_from_the_operators_prefix():
    intent = _allocator(_CountingKUID())._build_intent(
        _interpretation("IRB", ipv4_prefixes=["10.30.0.0/24"], ipv6_prefixes=["fd00:30::/64"]),
        "c" * 32,
    )
    assert intent.irbGateway is not None
    assert intent.irbGateway.gatewayIPv4 == "10.30.0.1/24"
    assert intent.irbGateway.gatewayIPv6 == "fd00:30::1/64"


def test_irb_carries_only_the_address_families_that_were_asked_for():
    """An IPv4-only request gets an IPv4-only IRB.

    Handing every IRB a fd00::1/64 gateway put an address family on the SVI
    that nobody requested, asked FRR to originate a Type-5 route for it, and
    then held the service to that route — which is how an IPv4 IRB failed to
    converge on a leaf whose zebra registered the address as a kernel rather
    than a connected route.
    """

    intent = _allocator(_CountingKUID())._build_intent(
        _interpretation("IRB", ipv4_prefixes=["10.30.0.0/24"]), "c" * 32
    )
    assert intent.irbGateway.gatewayIPv4 == "10.30.0.1/24"
    assert intent.irbGateway.gatewayIPv6 == ""

    v6_only = _allocator(_CountingKUID())._build_intent(
        _interpretation("IRB", ipv6_prefixes=["fd00:30::/64"]), "c" * 32
    )
    assert v6_only.irbGateway.gatewayIPv4 == ""
    assert v6_only.irbGateway.gatewayIPv6 == "fd00:30::1/64"

    # A request that named no addressing at all still gets somewhere to route.
    neither = _allocator(_CountingKUID())._build_intent(_interpretation("IRB"), "c" * 32)
    assert neither.irbGateway.gatewayIPv4 == "10.0.0.1/24"
    assert neither.irbGateway.gatewayIPv6 == ""


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

