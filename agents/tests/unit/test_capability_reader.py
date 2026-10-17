"""Unit tests — the live capability reader (feature 004, T466/T469/T623).

The reader (``supervisors/provisioning/capability.py``) gets ConfigMap
``fabric-compat-pins`` in ``agentic-netops-system`` over HTTPS with the
service-account bearer token. Here the HTTP transport is stubbed at
``capability._http_get`` (the module-level seam), so no cluster is needed:

* T466 — (capability, supported variants) are parsed from the ConfigMap;
  absent, unreadable and not-"true" each return capability False; NOTHING is
  cached across calls (two reads -> two HTTP attempts).
* T623 — the verifiable attachments come from ``srv6-probe-attachments`` of
  the SAME read; absent or unreadable returns none.
* T469 — R2 and the clarification questions list ONLY the supported
  variants that read reported.
"""

from __future__ import annotations

import httpx
import pytest

from supervisors.provisioning.capability import (
    CAPABILITY_CONFIGMAP,
    CAPABILITY_NAMESPACE,
    SRv6Capability,
    read_capability,
)
from supervisors.provisioning.graph import graph as graph_mod
from supervisors.provisioning.graph.graph import (
    clarification_prompt,
    srv6_clarification_question,
    srv6_r2_reason,
)


class _StubHTTP:
    """Counting stand-in for capability._http_get."""

    def __init__(self, payload=None, status=200, error=None):
        self.payload = payload
        self.status = status
        self.error = error
        self.calls = 0
        self.urls: list[str] = []

    def __call__(self, url, *, headers, verify, timeout):
        self.calls += 1
        self.urls.append(url)
        if self.error is not None:
            raise self.error
        return httpx.Response(
            self.status,
            request=httpx.Request("GET", url),
            json=self.payload if self.status // 100 == 2 else {"reason": "Forbidden"},
        )


def _configmap(data: dict) -> dict:
    return {"apiVersion": "v1", "kind": "ConfigMap", "metadata": {"name": CAPABILITY_CONFIGMAP}, "data": data}


_FULL = {
    "cap-sai-srv6": "true",
    "srv6-supported": "ip-vrf/vpn,mac-vrf/evpn",
    "srv6-probe-attachments": "leaf01/wan1,leaf02/wan1",
    "lab-profile": "srv6-lab",
    "sonic-image": "sonic:2024",
}


@pytest.fixture
def bearer(monkeypatch):
    monkeypatch.setenv("AGENTIC_NETOPS_BEARER_TOKEN", "test-token")
    monkeypatch.delenv("AGENTIC_NETOPS_API_ENDPOINT", raising=False)


class TestCapabilityReader:
    def test_reads_capability_supported_and_attachments(self, monkeypatch, bearer):
        stub = _StubHTTP(_configmap(_FULL))
        monkeypatch.setattr("supervisors.provisioning.capability._http_get", stub)
        cap = read_capability()
        assert cap.available is True
        assert cap.supported == ("ip-vrf/vpn", "mac-vrf/evpn")
        assert cap.verifiable_attachments == ("leaf01/wan1", "leaf02/wan1")
        assert cap.lab_profile == "srv6-lab"
        assert cap.sonic_image == "sonic:2024"
        assert stub.calls == 1
        assert stub.urls[0].startswith("https://kubernetes.default.svc:443")
        assert f"/namespaces/{CAPABILITY_NAMESPACE}/configmaps/{CAPABILITY_CONFIGMAP}" in stub.urls[0]

    def test_absent_configmap_is_fail_closed(self, monkeypatch, bearer):
        stub = _StubHTTP(status=404)
        monkeypatch.setattr("supervisors.provisioning.capability._http_get", stub)
        cap = read_capability()
        assert cap == SRv6Capability(available=False, supported=(), verifiable_attachments=())

    def test_unreadable_configmap_is_fail_closed(self, monkeypatch, bearer):
        stub = _StubHTTP(error=httpx.ConnectError("boom"))
        monkeypatch.setattr("supervisors.provisioning.capability._http_get", stub)
        cap = read_capability()
        assert cap.available is False
        assert cap.supported == ()
        assert cap.verifiable_attachments == ()

    def test_malformed_body_is_fail_closed(self, monkeypatch, bearer):
        stub = _StubHTTP({"data": "not-an-object"})
        monkeypatch.setattr("supervisors.provisioning.capability._http_get", stub)
        assert read_capability().available is False

    @pytest.mark.parametrize("value", ["TRUE", "True", "1", "yes", "false", ""])
    def test_not_exactly_true_is_unavailable(self, monkeypatch, bearer, value):
        stub = _StubHTTP(_configmap({**_FULL, "cap-sai-srv6": value}))
        monkeypatch.setattr("supervisors.provisioning.capability._http_get", stub)
        cap = read_capability()
        assert cap.available is False
        assert cap.supported == () and cap.verifiable_attachments == ()

    def test_no_caching_two_calls_two_attempts(self, monkeypatch, bearer):
        stub = _StubHTTP(_configmap(_FULL))
        monkeypatch.setattr("supervisors.provisioning.capability._http_get", stub)
        assert read_capability().available is True
        stub.payload = _configmap({**_FULL, "cap-sai-srv6": "false"})
        second = read_capability()
        assert stub.calls == 2  # every call re-reads; nothing cached
        assert second.available is False  # ...and each reports what it read

    # --- T623: verifiable attachments from the same read ----------------
    def test_attachments_absent_returns_none(self, monkeypatch, bearer):
        data = {k: v for k, v in _FULL.items() if k != "srv6-probe-attachments"}
        stub = _StubHTTP(_configmap(data))
        monkeypatch.setattr("supervisors.provisioning.capability._http_get", stub)
        cap = read_capability()
        assert cap.available is True
        assert cap.verifiable_attachments == ()

    def test_attachments_absent_configmap_returns_none(self, monkeypatch, bearer):
        stub = _StubHTTP(status=404)
        monkeypatch.setattr("supervisors.provisioning.capability._http_get", stub)
        assert read_capability().verifiable_attachments == ()


class TestSupportedSetFiltering:
    """T469 — R2 and the clarifications list ONLY the supported variants."""

    CAP = SRv6Capability(
        available=True,
        supported=("ip-vrf/vpn", "mac-vrf/evpn"),
        verifiable_attachments=("leaf01/wan1", "leaf02/wan1"),
    )

    def test_r2_lists_only_the_supported_set(self):
        text = srv6_r2_reason("ip-vrf/evpn", self.CAP.supported)
        assert "`ip-vrf over srv6 with evpn signalling` is not supported on this image." in text
        assert "Supported SRv6 services: `ip-vrf over srv6, mac-vrf over srv6`." in text

    def test_r2_bridged_gloss_is_the_kl001_wording(self):
        assert srv6_r2_reason("mac-vrf/evpn", self.CAP.supported) == (
            "`mac-vrf over srv6` (bridged EVPN over SRv6) is not supported on this image."
        )

    def test_c1_construct_question_lists_only_supported(self):
        q = srv6_clarification_question("srv6_construct", self.CAP)
        assert q == "Which SRv6 service: ip-vrf over srv6 (routed) or mac-vrf over srv6 (bridged)?"

    def test_c1_excludes_an_unsupported_variant(self):
        cap = SRv6Capability(available=True, supported=("ip-vrf/vpn",), verifiable_attachments=())
        q = srv6_clarification_question("srv6_construct", cap)
        assert q == "Which SRv6 service: ip-vrf over srv6 (routed)?"
        assert "mac-vrf" not in q

    def test_c2_signalling_question_lists_only_supported(self):
        cap = SRv6Capability(
            available=True,
            supported=("ip-vrf/vpn", "mac-vrf/evpn", "ip-vrf/evpn"),
            verifiable_attachments=(),
        )
        assert srv6_clarification_question("srv6_signalling", cap) == (
            "Routed (ip-vrf over srv6 with evpn signalling) or bridged (mac-vrf over srv6)?"
        )
        cap = SRv6Capability(available=True, supported=("mac-vrf/evpn",), verifiable_attachments=())
        assert srv6_clarification_question("srv6_signalling", cap) == "bridged (mac-vrf over srv6)?"

    def test_other_endpoint_prefix_vlan_questions_verbatim(self):
        assert srv6_clarification_question("srv6_other_endpoint", self.CAP) == (
            "An SRv6 service joins two attachment points. Which node and port is the other end?"
        )
        assert srv6_clarification_question("srv6_prefix", self.CAP) == "Which prefix does each side use?"
        assert srv6_clarification_question("srv6_vlan", self.CAP) == "Which vlan does the service carry?"

    def test_preferred_spine_question_lists_site_spines(self, monkeypatch):
        monkeypatch.setenv("FABRIC_SPINE_NODES", "spine01,spine02")
        assert srv6_clarification_question("srv6_preferred_spine", self.CAP) == (
            "Which spine is preferred: spine01 or spine02?"
        )

    def test_preferred_spine_without_inventory_keeps_generic_wording(self, monkeypatch):
        monkeypatch.delenv("FABRIC_SPINE_NODES", raising=False)
        assert srv6_clarification_question("srv6_preferred_spine", self.CAP) is None


class TestClarificationTextWiring:
    """Non-SRv6 missing fields keep today's text EXACTLY; SRv6 tokens get
    their §2 question appended before the hint (T488)."""

    CAP = SRv6Capability(
        available=True,
        supported=("ip-vrf/vpn", "mac-vrf/evpn"),
        verifiable_attachments=("leaf01/wan1", "leaf02/wan1"),
    )

    def test_non_srv6_clarification_text_is_unchanged(self):
        fields = ["tenant", "endpoints"]
        assert clarification_prompt(fields, None) == clarification_prompt(fields)
        assert "Which SRv6 service" not in clarification_prompt(fields)

    def test_srv6_token_appends_its_question(self):
        text = clarification_prompt(["srv6_construct"], [
            srv6_clarification_question("srv6_construct", self.CAP)
        ])
        assert "Before I can map this service I need: srv6_construct." in text
        assert "Which SRv6 service: ip-vrf over srv6 (routed) or mac-vrf over srv6 (bridged)?" in text
        assert text.endswith(graph_mod.CLARIFICATION_HINT)
