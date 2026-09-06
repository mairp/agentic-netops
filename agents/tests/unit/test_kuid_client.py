"""Unit tests for the allocator's KUID client identity (T211).

The regression these pin down: the client verified TLS against the default
trust store, which holds no cluster CA, so every claim died with

    [SSL: CERTIFICATE_VERIFY_FAILED] certificate verify failed: unable to
    get local issuer certificate

and reached the operator four hops away as an opaque A2A -32603. The trust
anchor is the ServiceAccount CA bundle mounted beside the token.
"""

from __future__ import annotations

import importlib
import json

import httpx
import pytest


@pytest.fixture
def kuid(monkeypatch):
    """Import the module with a clean environment each time."""
    for var in (
        "KUID_API_ENDPOINT",
        "AGENTIC_NETOPS_BEARER_TOKEN",
        "AGENTIC_NETOPS_VERIFY_TLS",
        "AGENTIC_NETOPS_CA_BUNDLE",
    ):
        monkeypatch.delenv(var, raising=False)
    module = importlib.import_module("provisioning.allocator.kuid")
    return importlib.reload(module)


def test_default_endpoint_is_the_aggregation_layer(kuid):
    """kuid-server is reached THROUGH the API server, not dialed directly.

    Its own serving certificate is a fixed placeholder (CN=basic.default.svc)
    that verifies for no name it is reached by — which is why its APIServices
    carry insecureSkipTLSVerify. The aggregated path is verifiable.
    """
    assert kuid._resolve_identity().endpoint == "https://kubernetes.default.svc:443"


def test_verify_uses_the_serviceaccount_ca_bundle(kuid, tmp_path, monkeypatch):
    ca = tmp_path / "ca.crt"
    ca.write_text("-----BEGIN CERTIFICATE-----\n")
    monkeypatch.setattr(kuid, "SA_CACERT_FILE", str(ca))

    identity = kuid._resolve_identity()

    assert identity.verify_tls is True
    assert identity.verify == str(ca)


def test_verify_falls_back_to_the_default_store_and_warns(kuid, tmp_path, monkeypatch, caplog):
    """No mounted bundle is a misconfiguration, and it must name itself."""
    monkeypatch.setattr(kuid, "SA_CACERT_FILE", str(tmp_path / "absent.crt"))

    with caplog.at_level("WARNING"):
        identity = kuid._resolve_identity()

    assert identity.verify is True
    assert "automountServiceAccountToken" in caplog.text


def test_ca_bundle_override_wins(kuid, monkeypatch):
    monkeypatch.setenv("AGENTIC_NETOPS_CA_BUNDLE", "/etc/ssl/custom.pem")
    assert kuid._resolve_identity().verify == "/etc/ssl/custom.pem"


def test_verification_can_be_turned_off(kuid, tmp_path, monkeypatch):
    """AGENTIC_NETOPS_VERIFY_TLS=0 disables verification outright — a bundle
    that happens to be mounted must not quietly turn it back on."""
    ca = tmp_path / "ca.crt"
    ca.write_text("-----BEGIN CERTIFICATE-----\n")
    monkeypatch.setattr(kuid, "SA_CACERT_FILE", str(ca))
    monkeypatch.setenv("AGENTIC_NETOPS_VERIFY_TLS", "0")

    assert kuid._resolve_identity().verify is False


def test_token_is_read_from_the_mounted_serviceaccount(kuid, tmp_path, monkeypatch):
    token = tmp_path / "token"
    token.write_text("  sa-token\n")
    monkeypatch.setattr(kuid, "SA_TOKEN_FILE", str(token))

    identity = kuid._resolve_identity()

    assert identity.token == "sa-token"
    assert kuid.KUIDClient(identity)._headers()["Authorization"] == "Bearer sa-token"


class _FallbackHTTP:
    def __init__(self):
        self.created: list[dict] = []
        self.deleted: list[str] = []

    def post(self, url, *, headers=None, content=None, **_kwargs):
        if url.endswith("/genidclaims") or url.endswith("/extcommclaims"):
            return httpx.Response(503, text="unsupported type: uint64")
        if url.endswith("/vlanclaims"):
            return httpx.Response(201, json={"metadata": {"name": "vlan-claim"}})
        if url.endswith("/leases"):
            body = json.loads(content or "{}")
            self.created.append(body)
            return httpx.Response(201, json=body)
        return httpx.Response(404, text=url)

    def get(self, url, *, headers=None, params=None, **_kwargs):
        if url.endswith("/leases"):
            return httpx.Response(200, json={"items": list(self.created)})
        if url.endswith("/vlanclaims/vlan-claim"):
            return httpx.Response(200, json={"metadata": {"name": "vlan-claim"}, "status": {"id": 123}})
        return httpx.Response(200, json={"items": []})

    def delete(self, url, *, headers=None, **_kwargs):
        self.deleted.append(url.rsplit("/", 1)[-1])
        return httpx.Response(200, json={})


def test_genid_allocation_falls_back_to_atomic_lease(kuid, monkeypatch):
    monkeypatch.setattr(kuid, "KUID_L2VNI_MIN", 5000)
    monkeypatch.setattr(kuid, "KUID_L2VNI_MAX", 5001)
    client = kuid.KUIDClient(kuid.KUIDIdentity("https://kubernetes.default.svc:443", "token", False))
    fake = _FallbackHTTP()
    client._client = fake

    assert client.allocate_l2vni("corr-1") == 5000

    lease = fake.created[0]
    assert lease["kind"] == "Lease"
    assert lease["metadata"]["name"] == "agentic-netops-l2vni-evpn-vni-5000"
    assert lease["metadata"]["annotations"][kuid.LEASE_CORRELATION_ANNOTATION] == "corr-1"
    assert lease["metadata"]["annotations"][kuid.LEASE_ID_ANNOTATION] == "5000"


def test_release_by_correlation_deletes_matching_fallback_leases(kuid):
    client = kuid.KUIDClient(kuid.KUIDIdentity("https://kubernetes.default.svc:443", "token", False))
    fake = _FallbackHTTP()
    fake.created.extend(
        [
            client._fallback_lease_body("l2vni", "evpn-vni", 5000, "corr-1"),
            client._fallback_lease_body("rt", "rt-index", 1, "other"),
        ]
    )
    client._client = fake

    assert client.release_by_correlation("corr-1") == 1
    assert fake.deleted == ["agentic-netops-l2vni-evpn-vni-5000"]


def test_l2_and_l3_fallback_share_the_vni_pool(kuid, monkeypatch):
    monkeypatch.setattr(kuid, "KUID_L2VNI_MIN", 5000)
    monkeypatch.setattr(kuid, "KUID_L2VNI_MAX", 5002)
    monkeypatch.setattr(kuid, "KUID_L3VNI_MIN", 5000)
    monkeypatch.setattr(kuid, "KUID_L3VNI_MAX", 5002)
    client = kuid.KUIDClient(kuid.KUIDIdentity("https://kubernetes.default.svc:443", "token", False))
    fake = _FallbackHTTP()
    client._client = fake

    assert client.allocate_l2vni("corr-1") == 5000
    assert client.allocate_l3vni("corr-1") == 5001



def test_release_by_correlation_no_claims_is_success(kuid):
    """Releasing by correlation when nothing was claimed is a success (0 deletions)."""
    client = kuid.KUIDClient(kuid.KUIDIdentity("https://kubernetes.default.svc:443", "token", False))
    fake = _FallbackHTTP()
    # No created leases; served claim resources also enumerate to empty
    client._client = fake

    assert client.release_by_correlation("corr-absent") == 0
