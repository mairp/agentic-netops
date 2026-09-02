from __future__ import annotations

import json
from typing import Any

import pytest

from provisioning.deployer.tools.deployer_tools import submit_service


# Golden input fixtures represent the NormalizedServiceIntent shapes that
# pkg/migration already consumes. We verify that the translator sidecar,
# bound to 127.0.0.1:8090, would accept and deterministically echo
# manifests/YAML for each supported type. In Phase 5, we do not start the
# sidecar in CI; these tests assert request construction and stub a 422
# response for unsupported/malformed through a monkeypatched client.


SUPPORTED_FIXTURES: list[tuple[str, dict[str, Any]]] = [
    (
        "VPLS",
        {
            "serviceId": "golden-vpls",
            "type": "VPLS",
            "tenant": "acme",
            "rdRt": {"rd": "65000:100", "importRT": ["65000:100"], "exportRT": ["65000:100"]},
            "l2vni": 10,
            "endpoints": [
                {"node": "leaf01", "attachment": "xe-0/0/1", "vlan": 100},
                {"node": "leaf02", "attachment": "xe-0/0/2", "vlan": 100},
            ],
            "policies": {"vpwsLimitedEquivalence": True},
        },
    ),
    (
        "VPWS",
        {
            "serviceId": "golden-vpws",
            "type": "VPWS",
            "tenant": "acme",
            "rdRt": {"rd": "65000:200", "importRT": ["65000:200"], "exportRT": ["65000:200"]},
            "l2vni": 20,
            "endpoints": [
                {"node": "leaf01", "attachment": "xe-0/0/3", "vlan": 200},
                {"node": "leaf02", "attachment": "xe-0/0/4", "vlan": 200},
            ],
            "policies": {"vpwsLimitedEquivalence": True},
        },
    ),
    (
        "L3VPN",
        {
            "serviceId": "golden-l3vpn",
            "type": "L3VPN",
            "tenant": "acme",
            "rdRt": {"rd": "65000:300", "importRT": ["65000:300"], "exportRT": ["65000:300"]},
            "l3vni": 30,
            "addressFamilies": {"ipv4Prefixes": ["10.0.0.0/24"]},
            "endpoints": [
                {"node": "leaf01", "attachment": "irb.10", "vrf": "acme"},
            ],
        },
    ),
    (
        "IRB",
        {
            "serviceId": "golden-irb",
            "type": "L2L3-IRB",
            "tenant": "acme",
            "rdRt": {"rd": "65000:400", "importRT": ["65000:400"], "exportRT": ["65000:400"]},
            "l2vni": 40,
            "l3vni": 41,
            "irbGateway": {"vrf": "acme", "gatewayIPv4": "10.0.10.1/24", "gatewayIPv6": "2001:db8::1/64"},
            "endpoints": [
                {"node": "leaf01", "attachment": "xe-0/0/10", "vlan": 10},
            ],
        },
    ),
]


@pytest.mark.parametrize("name, payload", SUPPORTED_FIXTURES)
def test_supported_golden_inputs_shape(name: str, payload: dict[str, Any], monkeypatch: pytest.MonkeyPatch):
    # Monkeypatch httpx.Client.post to avoid network I/O and simulate a 200
    class DummyResp:
        def __init__(self, json_obj: dict[str, Any], status_code: int = 200):
            self._json = json_obj
            self.status_code = status_code
            self.text = json.dumps(json_obj)

        def json(self) -> dict[str, Any]:
            return self._json

    def fake_post(url: str, headers: dict[str, str], content: str):  # type: ignore[override]
        body = json.loads(content)
        # Return deterministic echo matching translator shape
        return DummyResp({"manifests": [{"apiVersion": "network.kubenet.dev/v1alpha1", "kind": "Network", "metadata": {"name": body.get("serviceId", "")}}], "yaml": "apiVersion: network.kubenet.dev/v1alpha1\nkind: Network\nmetadata:\n  name: %s\n" % body.get("serviceId", "")})

    class DummyClient:
        def __init__(self, timeout: float):
            self.timeout = timeout

        def __enter__(self):
            return self

        def __exit__(self, exc_type, exc, tb):
            return False

        def post(self, url: str, headers: dict[str, str], content: str):
            return fake_post(url, headers, content)

    import httpx

    monkeypatch.setattr(httpx, "Client", DummyClient)  # type: ignore[attr-defined]

    resp = submit_service(payload)
    assert "manifests" in resp and isinstance(resp["manifests"], list)
    assert resp["manifests"][0].get("kind") == "Network"
    assert isinstance(resp.get("yaml"), str) and "kind: Network" in resp["yaml"]


NEGATIVE_FIXTURES: list[tuple[str, Any]] = [
    ("unsupported-type", {"serviceId": "x", "type": "E-TREE", "tenant": "acme", "endpoints": []}),
    ("malformed-missing-fields", {"serviceId": "", "type": "VPLS", "tenant": "", "endpoints": []}),
]


@pytest.mark.parametrize("name, payload", NEGATIVE_FIXTURES)
def test_negative_inputs_surface_422(name: str, payload: dict[str, Any], monkeypatch: pytest.MonkeyPatch):
    # Monkeypatch httpx.Client.post to simulate a 422 structured validation error
    class DummyResp:
        def __init__(self, json_obj: dict[str, Any], status_code: int):
            self._json = json_obj
            self.status_code = status_code
            self.text = json.dumps(json_obj)

        def json(self) -> dict[str, Any]:
            return self._json

    def fake_post(url: str, headers: dict[str, str], content: str):  # type: ignore[override]
        return DummyResp({"error": "validation", "causes": ["type: unsupported E-TREE"]}, 422)

    class DummyClient:
        def __init__(self, timeout: float):
            self.timeout = timeout

        def __enter__(self):
            return self

        def __exit__(self, exc_type, exc, tb):
            return False

        def post(self, url: str, headers: dict[str, str], content: str):
            return fake_post(url, headers, content)

    import httpx

    monkeypatch.setattr(httpx, "Client", DummyClient)  # type: ignore[attr-defined]

    resp = submit_service(payload)
    assert resp.get("error") == "validation"
    assert isinstance(resp.get("causes"), list) and len(resp["causes"]) >= 1
