"""Schema acceptance + rejection tests (T073, T074).

Acceptance (T073): every supported migration fixture in
``tests/unit/testdata/migration/`` parses into ``NormalizedServiceIntent``
and passes ``validate_all_or_nothing()`` — the Python model is a faithful
client of the contract ``pkg/migration`` consumes (FR-011, SC-007's oracle
lives in those fixtures).

Rejection (T074): unknown fields and incomplete interpretations are
rejected at the agent boundary — ``extra="forbid"`` everywhere (the Go
``ParseStrictBatch`` parity, FR-017), and the per-type rules mirror
``pkg/migration/input.go`` ``ValidateAllOrNothing``.
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest
from pydantic import ValidationError

from common.schemas.audit import AuditEvent
from common.schemas.interpretation import EndpointIntent, Interpretation
from common.schemas.normalized_intent import NormalizedServiceIntent
from common.schemas.refs import ClaimRef, ResourceRef

# agents/tests/unit/ -> repo root is three levels up
REPO_ROOT = Path(__file__).resolve().parents[3]
FIXTURES = REPO_ROOT / "tests" / "unit" / "testdata" / "migration"


def load_fixture(name: str):
    return json.loads((FIXTURES / name).read_text(encoding="utf-8"))


# ---------------------------------------------------------------------------
# T073 — acceptance: the migration fixtures parse and validate
# ---------------------------------------------------------------------------


def _fold_legacy(payload: dict) -> dict:
    """Client-side mirror of the Go ``Canonicalize`` fold (US4): a legacy
    migration-source fixture is what an operator or a legacy system hands us;
    the normalized agent contract carries the construct it folds to. The
    legacy ``irbGateway`` block is the anycast gateway under its old name and
    only its addresses carry over; ``sourceType`` is Go-side bookkeeping and
    is not part of the agent wire contract."""
    out = json.loads(json.dumps(payload))  # deep copy
    aliases = {
        "VPLS": "mac-vrf",
        "VPWS": "mac-vrf",
        "ELINE": "mac-vrf",
        "L2L3-IRB": "mac-vrf",
        "IRB": "mac-vrf",
        "L3VPN": "ip-vrf",
    }
    t = out.get("type")
    out["type"] = aliases.get(t, t)
    gateway = out.pop("irbGateway", None)
    if gateway is not None and out.get("anycastGateway") is None:
        out["anycastGateway"] = {
            k: gateway[k] for k in ("gatewayIPv4", "gatewayIPv6") if gateway.get(k)
        }
    out.pop("sourceType", None)
    return out


@pytest.mark.parametrize(
    "fixture",
    ["supported_vpls.json", "supported_l3vpn.json", "supported_irb.json", "supported_vpws_optin.json"],
)
def test_supported_fixtures_parse_and_validate(fixture: str):
    obj = NormalizedServiceIntent.model_validate(_fold_legacy(load_fixture(fixture)))
    assert obj.validate_all_or_nothing() is None, f"{fixture} must fold to a valid construct"


def test_fixture_wire_names_are_the_go_json_names():
    """The model serializes back to the translator's wire names."""
    obj = NormalizedServiceIntent.model_validate(_fold_legacy(load_fixture("supported_vpls.json")))
    dumped = obj.model_dump(exclude_none=True)
    for key in ("serviceId", "type", "tenant", "rdRt", "l2vni", "endpoints"):
        assert key in dumped, f"wire name {key!r} must survive the round trip"
    assert dumped["type"] == "mac-vrf"
    assert dumped["rdRt"]["importRT"] == ["65000:100"]
    assert dumped["endpoints"][0] == {"node": "leaf01", "attachment": "client01", "vlan": 10}


def test_irb_folds_to_macvrf_with_anycast_gateway():
    """A legacy IRB input folds to a mac-vrf carrying the anycast gateway
    (symmetric IRB): same VNIs, addresses carried over, the legacy ``vrf``
    label dropped — the ip-vrf is resolved at translation time."""
    obj = NormalizedServiceIntent.model_validate(_fold_legacy(load_fixture("supported_irb.json")))
    assert obj.type == "mac-vrf"
    assert obj.l2vni == 10401 and obj.l3vni == 14001
    assert obj.anycastGateway is not None
    assert obj.anycastGateway.gatewayIPv4 == "10.0.20.1/24"
    assert obj.anycastGateway.gatewayIPv6 == "2001:db8:20::1/64"
    assert "vrf" not in obj.anycastGateway.model_dump(exclude_none=True)


def test_batch_duplicate_service_id_is_a_collision():
    """collision_duplicate.json: each item folds to a valid construct and is
    valid alone; the duplicate serviceId in the batch is a terminal collision
    (Go: dupServiceID)."""
    batch = load_fixture("collision_duplicate.json")
    assert isinstance(batch, list) and len(batch) == 2
    first = NormalizedServiceIntent.model_validate(_fold_legacy(batch[0]))
    second = NormalizedServiceIntent.model_validate(_fold_legacy(batch[1]))
    assert first.validate_all_or_nothing(dup_service_id=False) is None
    err = second.validate_all_or_nothing(dup_service_id=True)
    assert err is not None
    assert any("collision: duplicate serviceId 'dup-svc' in batch" in c for c in err.causes)


def test_supported_fixtures_are_exhaustive_of_the_dir():
    """Guard: if a new supported_*.json fixture lands, this test reminds the
    suite to accept it."""
    fixtures = {p.name for p in FIXTURES.glob("supported_*.json")}
    accepted = {"supported_vpls.json", "supported_l3vpn.json", "supported_irb.json", "supported_vpws_optin.json"}
    assert fixtures == accepted, f"unhandled supported fixtures: {fixtures - accepted}"


# ---------------------------------------------------------------------------
# T074 — rejection: unknown fields and incomplete interpretations
# ---------------------------------------------------------------------------


def test_unknown_field_is_rejected():
    """malformed_unknown_field.json: ParseStrictBatch rejects unknown fields;
    the Python model must be equally strict (extra="forbid")."""
    with pytest.raises(ValidationError) as excinfo:
        NormalizedServiceIntent.model_validate(load_fixture("malformed_unknown_field.json"))
    assert "unknown" in str(excinfo.value)


def test_unsupported_feature_rejects_named():
    """unsupported_te.json: the Go side rejects with 'unsupported: tePolicy';
    the Python boundary raises the identical cause (FR-011 / SC-003)."""
    obj = NormalizedServiceIntent.model_validate(load_fixture("unsupported_te.json"))
    err = obj.validate_all_or_nothing()
    assert err is not None
    assert "unsupported: tePolicy" in err.causes


def test_vpws_optin_has_no_effect_on_the_macvrf_construct():
    """The exactly-two-attachments and limited-equivalence opt-in rules are
    VPWS-alias rules and live on the Go brownfield path (input.go, keyed on
    SourceType == LegacyVPWS; covered by the Go unit tests). Asking for the
    mac-vrf construct directly claims no pseudowire, so the policy is absent
    and the construct validates."""
    obj = NormalizedServiceIntent.model_validate(_fold_legacy(load_fixture("supported_vpws_optin.json")))
    assert obj.type == "mac-vrf"
    assert obj.policies is not None and obj.policies.vpwsLimitedEquivalence is True
    # The construct itself needs no opt-in:
    obj.policies = None
    assert obj.validate_all_or_nothing() is None


def test_l3vpn_without_address_families_rejects():
    obj = NormalizedServiceIntent.model_validate(_fold_legacy(load_fixture("supported_l3vpn.json")))
    assert obj.type == "ip-vrf"
    obj.addressFamilies = None
    err = obj.validate_all_or_nothing()
    assert err is not None
    assert any("addressFamilies: at least one prefix is required for ip-vrf" in c for c in err.causes)


def test_vpls_mismatched_vlans_reject():
    obj = NormalizedServiceIntent.model_validate(_fold_legacy(load_fixture("supported_vpls.json")))
    obj.endpoints[1].vlan = 11
    err = obj.validate_all_or_nothing()
    assert err is not None
    assert any("mac-vrf is one bridge domain" in c for c in err.causes)


def test_macvrf_requires_two_endpoints():
    """A gatewayless mac-vrf is a bridged service: one attachment extends
    nothing. (With an anycast gateway the minimum drops to 1 — the SVI gives
    the single attachment a routed reason to exist.)"""
    obj = NormalizedServiceIntent.model_validate(_fold_legacy(load_fixture("supported_vpws_optin.json")))
    obj.policies = None
    obj.endpoints = obj.endpoints[:1]
    err = obj.validate_all_or_nothing()
    assert err is not None
    assert any("mac-vrf requires >=2 endpoints" in c for c in err.causes)


def test_unknown_service_type_rejects_never_coerces():
    data = load_fixture("supported_vpls.json")
    data["type"] = "TE-VPLS"
    obj = NormalizedServiceIntent.model_validate(data)
    err = obj.validate_all_or_nothing()
    assert err is not None
    assert any("type: unsupported" in c for c in err.causes)


def test_nested_unknown_field_rejected():
    """extra="forbid" applies to every nested model (endpoint, rdRt, ...)."""
    data = load_fixture("supported_vpls.json")
    data["endpoints"][0]["bogus"] = 1
    with pytest.raises(ValidationError):
        NormalizedServiceIntent.model_validate(data)
    data = load_fixture("supported_vpls.json")
    data["rdRt"]["extraRT"] = ["65000:1"]
    with pytest.raises(ValidationError):
        NormalizedServiceIntent.model_validate(data)


# ---------------------------------------------------------------------------
# T074 — rejection: incomplete interpretations (data-model.md §2)
# ---------------------------------------------------------------------------

VALID_INTERPRETATION = {
    "service_id": "ACME-L1-L2-101",
    "service_type": "VPLS",
    "tenant": "acme",
    "endpoints": [
        {"site_or_node": "leaf01", "attachment": "client01", "vlan": 10},
        {"site_or_node": "leaf02", "attachment": "client02", "vlan": 10},
    ],
}


def test_complete_interpretation_validates():
    interp = Interpretation.model_validate(VALID_INTERPRETATION)
    assert interp.is_complete
    # The legacy alias folds to the construct; provenance records what the
    # operator actually said (US4).
    assert interp.service_type.value == "mac-vrf"
    assert interp.source_service_type == "VPLS"
    assert interp.endpoints[0].vlan == 10


@pytest.mark.parametrize("field", ["service_id", "service_type", "tenant", "endpoints"])
def test_interpretation_required_fields_rejected(field: str):
    data = dict(VALID_INTERPRETATION)
    data.pop(field)
    with pytest.raises(ValidationError):
        Interpretation.model_validate(data)


def test_interpretation_requires_at_least_one_endpoint():
    """FR-011 / T024: the schema minimum drops to 1 — a vlan, an ip-vrf or an
    acl binds to a single port, and a mac-vrf with an anycast gateway needs
    only one. Zero endpoints is no service at all. The per-construct minima
    (a gatewayless mac-vrf needs >=2) fire where the construct is known: the
    normalized intent (see test_macvrf_requires_two_endpoints)."""
    data = dict(VALID_INTERPRETATION)
    data["endpoints"] = [VALID_INTERPRETATION["endpoints"][0]]
    interp = Interpretation.model_validate(data)
    assert len(interp.endpoints) == 1
    data["endpoints"] = []
    with pytest.raises(ValidationError):
        Interpretation.model_validate(data)


def test_interpretation_rejects_unknown_field():
    data = dict(VALID_INTERPRETATION)
    data["traffic_engineering"] = "yes"
    with pytest.raises(ValidationError):
        Interpretation.model_validate(data)


def test_interpretation_rejects_non_rfc1123_tenant():
    data = dict(VALID_INTERPRETATION)
    data["tenant"] = "ACME!"
    with pytest.raises(ValidationError):
        Interpretation.model_validate(data)


def test_interpretation_mutual_exclusion_of_terminal_flags():
    """T067: a message cannot be BOTH a clarification request and a
    rejection — naming both is a schema rejection."""
    data = dict(VALID_INTERPRETATION)
    data["missing_fields"] = ["bandwidth"]
    data["unsupported_properties"] = ["tePolicy"]
    with pytest.raises(ValidationError) as excinfo:
        Interpretation.model_validate(data)
    assert "mutually exclusive" in str(excinfo.value)


def test_interpretation_clarification_request_is_terminal_but_valid_shape():
    """missing_fields alone => clarification request: valid model, not
    complete, and the supervisor must not route it onward (FR-010)."""
    data = dict(VALID_INTERPRETATION)
    data["missing_fields"] = ["bandwidth"]
    interp = Interpretation.model_validate(data)
    assert interp.is_complete is False
    assert interp.missing_fields == ["bandwidth"]


def test_interpretation_rejection_is_terminal_but_valid_shape():
    """unsupported_properties alone => rejection; no partial assignment may
    follow (FR-012, SC-003)."""
    data = dict(VALID_INTERPRETATION)
    data["unsupported_properties"] = ["tePolicy"]
    interp = Interpretation.model_validate(data)
    assert interp.is_complete is False
    assert interp.unsupported_properties == ["tePolicy"]


def test_interpretation_service_id_max_length():
    data = dict(VALID_INTERPRETATION)
    data["service_id"] = "x" * 16
    with pytest.raises(ValidationError):
        Interpretation.model_validate(data)


def test_endpoint_intent_rejects_unknown_field():
    with pytest.raises(ValidationError):
        EndpointIntent.model_validate({"site_or_node": "n", "attachment": "a", "bogus": 1})


# ---------------------------------------------------------------------------
# refs.py / audit.py sanity (T071, T072)
# ---------------------------------------------------------------------------

CORRELATION_ID = "4bf92f3577b34da6a3ce929d0e0e4736"


def test_resource_ref_shape():
    ref = ResourceRef(
        apiVersion="network.kubenet.dev/v1alpha1",
        kind="Network",
        namespace="agentic-netops-intent",
        name="svc1",
    )
    assert ref.ready is None  # convergence watch open
    ref.ready = True
    assert ref.ready is True


def test_claim_ref_defaults_and_release():
    claim = ClaimRef(
        name="svc1-vni-claim",
        index_kind="VNIIndex",
        index_name="evpn-vni",
    )
    assert claim.namespace == "kuid-system"
    assert claim.allocated_value is None
    assert claim.released_at is None


def test_audit_event_shapes():
    submit = AuditEvent(
        event_type="submit",
        correlation_id=CORRELATION_ID,
        thread_id="t-1",
        principal="operator@example",
        at="2026-09-01T12:00:00Z",
        resources=[
            ResourceRef(
                apiVersion="network.kubenet.dev/v1alpha1",
                kind="Network",
                namespace="agentic-netops-intent",
                name="svc1",
            )
        ],
    )
    assert submit.validate_event_shape() == []

    refuse = AuditEvent(
        event_type="refuse",
        correlation_id=CORRELATION_ID,
        thread_id="t-1",
        principal="operator@example",
        at="2026-09-01T12:01:00Z",
        reason="unsupported property: tePolicy",
    )
    assert refuse.validate_event_shape() == []

    # refuse must not carry resources (data-model §7)
    bad = AuditEvent(
        event_type="refuse",
        correlation_id=CORRELATION_ID,
        thread_id="t-1",
        principal="operator@example",
        at="2026-09-01T12:01:00Z",
        resources=[
            ResourceRef(
                apiVersion="network.kubenet.dev/v1alpha1",
                kind="Network",
                namespace="agentic-netops-intent",
                name="svc1",
            )
        ],
    )
    assert bad.validate_event_shape()

    # correlation_id is a 32-hex W3C trace id
    with pytest.raises(ValidationError):
        AuditEvent(
            event_type="confirm",
            correlation_id="nothex",
            thread_id="t-1",
            principal="p",
            at="2026-09-01T12:00:00Z",
        )


# ---------------------------------------------------------------------------
# US4 — SRv6 transport on the normalized intent (contracts/intent-srv6.md)
# ---------------------------------------------------------------------------

SRV6_IPVRF = {
    "serviceId": "acme-routed",
    "type": "ip-vrf",
    "transport": "srv6",
    "signalling": "vpn",
    "tenant": "acme",
    "endpoints": [
        {"node": "leaf01", "attachment": "wan1", "prefixes": ["2001:db8:3::30/127"]},
        {"node": "leaf02", "attachment": "wan1", "prefixes": ["2001:db8:4::40/127"]},
    ],
    "preferredSpine": "spine01",
}


def test_srv6_fields_default_to_vxlan_wire_names():
    """§1: transport defaults to vxlan; signalling and preferredSpine default
    to none. Omitted transport is exactly the pre-US4 model."""
    data = load_fixture("supported_l3vpn.json")
    obj = NormalizedServiceIntent.model_validate(_fold_legacy(data))
    assert obj.transport == "vxlan"
    assert obj.signalling is None
    assert obj.preferredSpine is None
    dumped = obj.model_dump()
    assert dumped["transport"] == "vxlan"  # exact wire spelling
    assert "preferredSpine" in dumped and dumped["preferredSpine"] is None


def test_srv6_ip_vrf_without_vxlan_identifiers_validates_clean():
    """§3 interplay: over srv6 the VXLAN identifier requirements are lifted —
    no l3vni, no rdRt, no addressFamilies; prefixes ride on the attachments."""
    obj = NormalizedServiceIntent.model_validate(SRV6_IPVRF)
    assert obj.validate_all_or_nothing() is None


def test_v1_unsupported_transport_cause():
    obj = NormalizedServiceIntent.model_validate({**SRV6_IPVRF, "transport": "mpls"})
    err = obj.validate_all_or_nothing()
    assert err is not None
    assert "transport: unsupported 'mpls' (transports: vxlan, srv6)" in err.causes


def test_v2_srv6_vlan_construct_cause():
    base = load_fixture("construct_vlan.json")
    data = dict(base)
    data["transport"] = "srv6"
    obj = NormalizedServiceIntent.model_validate(data)
    err = obj.validate_all_or_nothing()
    assert err is not None
    assert "transport: srv6 applies to ip-vrf and mac-vrf only" in err.causes


def test_v3_srv6_supplied_identifier_cause():
    obj = NormalizedServiceIntent.model_validate({**SRV6_IPVRF, "l3vni": 14001})
    err = obj.validate_all_or_nothing()
    assert err is not None
    assert "srv6: identifiers are allocated by the fabric, not supplied" in err.causes


def test_v4_macvrf_vpn_signalling_over_srv6_cause():
    data = {**SRV6_IPVRF, "type": "mac-vrf", "signalling": "vpn"}
    obj = NormalizedServiceIntent.model_validate(data)
    err = obj.validate_all_or_nothing()
    assert err is not None
    assert "signalling: mac-vrf over srv6 uses evpn" in err.causes


def test_v5_signalling_with_vxlan_transport_cause():
    obj = NormalizedServiceIntent.model_validate(
        {**SRV6_IPVRF, "transport": "vxlan", "l3vni": 14001, "rdRt": {"rd": "65000:100"}}
    )
    err = obj.validate_all_or_nothing()
    assert err is not None
    assert "signalling: only valid with transport srv6" in err.causes
    assert "preferredSpine: only valid with transport srv6" in err.causes


def test_v6_srv6_endpoints_cause():
    data = {**SRV6_IPVRF, "endpoints": [SRV6_IPVRF["endpoints"][0]]}
    obj = NormalizedServiceIntent.model_validate(data)
    err = obj.validate_all_or_nothing()
    assert err is not None
    assert "endpoints: an srv6 service joins exactly two attachments on distinct nodes" in err.causes


def test_v7_unknown_preferred_spine_cause(monkeypatch: pytest.MonkeyPatch):
    monkeypatch.setenv("FABRIC_SPINE_NODES", "spine01,spine02")
    obj = NormalizedServiceIntent.model_validate({**SRV6_IPVRF, "preferredSpine": "spine99"})
    err = obj.validate_all_or_nothing()
    assert err is not None
    assert "preferredSpine: unknown 'spine99' (site has: spine01, spine02)" in err.causes


def test_v7_validates_nothing_without_site_inventory(monkeypatch: pytest.MonkeyPatch):
    """SiteInventory parity: FABRIC_SPINE_NODES unset => V7 never fires."""
    monkeypatch.delenv("FABRIC_SPINE_NODES", raising=False)
    obj = NormalizedServiceIntent.model_validate({**SRV6_IPVRF, "preferredSpine": "spine99"})
    assert obj.validate_all_or_nothing() is None


def test_v8_tepolicy_suppresses_preferred_spine_causes(monkeypatch: pytest.MonkeyPatch):
    """V8: tePolicy present with preferredSpine => refused as tePolicy only;
    no V5/V7 causes are added for preferredSpine."""
    monkeypatch.setenv("FABRIC_SPINE_NODES", "spine01,spine02")
    data = {
        **SRV6_IPVRF,
        "transport": "vxlan",
        "l3vni": 14001,
        "rdRt": {"rd": "65000:100"},
        "unsupported": {"tePolicy": {"mode": "rsvp-te"}},
    }
    obj = NormalizedServiceIntent.model_validate(data)
    err = obj.validate_all_or_nothing()
    assert err is not None
    assert "unsupported: tePolicy" in err.causes
    assert not any("preferredSpine" in c for c in err.causes)


def test_srv6_strict_parse_rejects_unknown_srv6_field():
    """ParseStrictBatch parity: an srv6-ish unknown field is a parse error."""
    data = {**SRV6_IPVRF, "srv6Locator": "fc00:0:1::/48"}
    with pytest.raises(ValidationError) as excinfo:
        NormalizedServiceIntent.model_validate(data)
    assert "srv6Locator" in str(excinfo.value)


def test_interpretation_srv6_fields():
    """T464: the Interpretation carries transport/signalling/preferredSpine
    under their wire names; they never make it incomplete."""
    data = {
        **VALID_INTERPRETATION,
        "transport": "srv6",
        "signalling": "evpn",
        "preferredSpine": "spine01",
    }
    interp = Interpretation.model_validate(data)
    assert interp.transport == "srv6"
    assert interp.signalling == "evpn"
    assert interp.preferred_spine == "spine01"
    assert interp.is_complete
    assert interp.model_dump(exclude_none=True)["preferred_spine"] == "spine01"


def test_interpretation_transport_defaults_and_rejects_bad_value():
    """None is the pre-US4 shape: the supervisor reads None as vxlan (Go
    parity — ServiceInput.Transport has no default either), and the legacy
    interpretation dumps stay byte-identical (SC-016)."""
    interp = Interpretation.model_validate(VALID_INTERPRETATION)
    assert interp.transport is None
    assert interp.signalling is None
    assert interp.preferred_spine is None
    data = {**VALID_INTERPRETATION, "transport": "mpls"}
    with pytest.raises(ValidationError):
        Interpretation.model_validate(data)
