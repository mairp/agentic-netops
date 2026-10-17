"""US4 T465 — Python/Go intent-contract parity over the srv6 fixtures.

Every ``tests/unit/testdata/migration/srv6_*.json`` fixture (owned by the Go
side, ``pkg/migration``) is fed to the Python ``NormalizedServiceIntent``
through ``model_validate`` (the strict-parse equivalent of the Go
``ParseStrictBatch``: unknown fields refuse at the boundary) and then through
``validate_all_or_nothing()``. Accept fixtures must validate clean; each
refusal fixture must produce a cause list containing exactly the §3 cause
its rule names (contracts/intent-srv6.md §3 — identical strings on both
sides).

A fixture the Go worker has not written yet skips with a named message;
``test_all_srv6_fixtures_exist`` fails loudly listing whatever is missing so
parity cannot silently rot.
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from common.schemas.normalized_intent import NormalizedServiceIntent

REPO_ROOT = Path(__file__).resolve().parents[3]
FIXTURES = REPO_ROOT / "tests" / "unit" / "testdata" / "migration"

# Fixture -> expected §3 cause. Accept fixtures map to None. Where the cause
# embeds the offending value, it is built from the fixture payload itself so
# the expected string stays exact (V1's '<x>', V7's '<x>').
EXPECTED: dict[str, str | None] = {
    # accepts (T431–T433)
    "srv6_ip_vrf_vpn.json": None,
    "srv6_ip_vrf_evpn.json": None,
    "srv6_mac_vrf_evpn.json": None,
    # refusals, V1..V8
    "srv6_v1_transport.json": "transport: unsupported '{transport}' (transports: vxlan, srv6)",
    "srv6_v2_construct.json": "transport: srv6 applies to ip-vrf and mac-vrf only",
    "srv6_v3_identifiers.json": "srv6: identifiers are allocated by the fabric, not supplied",
    "srv6_v4_macvpn.json": "signalling: mac-vrf over srv6 uses evpn",
    "srv6_v5_vxlan_spine.json": "preferredSpine: only valid with transport srv6",
    "srv6_v6_endpoints.json": "endpoints: an srv6 service joins exactly two attachments on distinct nodes",
    "srv6_v7_spine.json": "preferredSpine: unknown '{preferredSpine}' (site has: spine01, spine02)",
    "srv6_v8_tepolicy.json": "unsupported: tePolicy",
}

ALL_SRV6_FIXTURES = sorted(EXPECTED)


def _expected_cause(fixture: str, payload: dict) -> str:
    tmpl = EXPECTED[fixture]
    assert tmpl is not None
    return tmpl.format(
        transport=payload.get("transport", ""),
        preferredSpine=payload.get("preferredSpine", ""),
    )


@pytest.mark.parametrize("fixture", ALL_SRV6_FIXTURES)
def test_srv6_fixture_matches_go_outcome(fixture: str, monkeypatch: pytest.MonkeyPatch):
    path = FIXTURES / fixture
    if not path.exists():
        pytest.skip(f"Go fixture not created yet: tests/unit/testdata/migration/{fixture}")
    payload = json.loads(path.read_text(encoding="utf-8"))
    # The Go golden test does t.Setenv with the same value.
    monkeypatch.setenv("FABRIC_SPINE_NODES", "spine01,spine02")
    obj = NormalizedServiceIntent.model_validate(payload)  # strict parse
    err = obj.validate_all_or_nothing()
    expected = EXPECTED[fixture]
    if expected is None:
        assert err is None, f"{fixture}: Go accepts this fixture, Python refuses: {err}"
    else:
        assert err is not None, f"{fixture}: Go refuses this fixture, Python accepts"
        assert _expected_cause(fixture, payload) in err.causes, (
            f"{fixture}: expected the exact §3 cause, got {err.causes}"
        )


def test_all_srv6_fixtures_exist():
    """Loud guard: the parity table is exhaustive over the Go worker's
    srv6 fixtures. A missing file is named, not skipped."""
    missing = [f for f in ALL_SRV6_FIXTURES if not (FIXTURES / f).exists()]
    assert not missing, (
        "missing Go fixtures (parity test cannot run): "
        + ", ".join(f"tests/unit/testdata/migration/{m}" for m in missing)
    )
