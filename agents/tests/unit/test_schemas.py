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
from common.schemas.interpretation import EndpointIntent, Interpretation, ServiceType
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


@pytest.mark.parametrize(
    "fixture",
    ["supported_vpls.json", "supported_l3vpn.json", "supported_irb.json", "supported_vpws_optin.json"],
)
def test_supported_fixtures_parse_and_validate(fixture: str):
    obj = NormalizedServiceIntent.model_validate(load_fixture(fixture))
    assert obj.validate_all_or_nothing() is None, f"{fixture} must validate cleanly"


def test_fixture_wire_names_are_the_go_json_names():
    """The model serializes back to the translator's wire names."""
    obj = NormalizedServiceIntent.model_validate(load_fixture("supported_vpls.json"))
    dumped = obj.model_dump(exclude_none=True)
    for key in ("serviceId", "type", "tenant", "rdRt", "l2vni", "endpoints"):
        assert key in dumped, f"wire name {key!r} must survive the round trip"
    assert dumped["rdRt"]["importRT"] == ["65000:100"]
    assert dumped["endpoints"][0] == {"node": "leaf01", "attachment": "client01", "vlan": 10}


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
