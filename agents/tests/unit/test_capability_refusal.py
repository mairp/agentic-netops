"""Unit tests — the capability gate (feature 004, T549).

With the capability absent, unreadable or false, an SRv6 request is refused
(R4) BEFORE the mapper runs, with zero allocator or deployer calls (and zero
worker calls of any kind — the gate sits in front of ``call_mapper``). With
the capability true, the request proceeds to mapping and the first
confirmation. A non-SRv6 request never triggers the capability read at all.

The real graph runs; only the classifier LLM, the worker transport and the
capability seam (``graph.read_srv6_capability``) are stand-ins.
"""

from __future__ import annotations

import asyncio
from typing import Any

import pytest
from langchain_core.messages import AIMessage, HumanMessage

from common.audit import reset_audit_sink
from common.provisioning_states import NetworkProvisioningStatus
from supervisors.provisioning.capability import SRv6Capability
from supervisors.provisioning.graph import graph as graph_mod
from supervisors.provisioning.graph.graph import ProvisioningGraph, default_deadline

SRV6_REQUEST = (
    "give tenant acme an ip-vrf over srv6 between leaf01 wan1 and leaf02 wan1"
)
VXLAN_REQUEST = (
    "give tenant acme an ip-vrf between leaf01 wan1 and leaf02 wan1 with prefix 10.50.0.0/24"
)

AVAILABLE = SRv6Capability(
    available=True,
    supported=("ip-vrf/vpn", "mac-vrf/evpn"),
    verifiable_attachments=("leaf01/wan1", "leaf02/wan1"),
)


def _srv6_interpretation(**over: Any) -> dict:
    payload: dict[str, Any] = {
        "service_id": "svc-srv6001",
        "service_type": "ip-vrf",
        "tenant": "acme",
        "endpoints": [
            {"site_or_node": "leaf01", "attachment": "wan1"},
            {"site_or_node": "leaf02", "attachment": "wan1"},
        ],
        "transport": "srv6",
        "signalling": "vpn",
    }
    payload.update(over)
    return payload


def _vxlan_interpretation() -> dict:
    """No transport field: absent means vxlan (legacy shape, byte-identical
    to the pre-US4 interpretation dump)."""
    return {
        "service_id": "svc-vxln001",
        "service_type": "ip-vrf",
        "tenant": "acme",
        "endpoints": [
            {"site_or_node": "leaf01", "attachment": "wan1"},
            {"site_or_node": "leaf02", "attachment": "wan1"},
        ],
    }


class _Srv6Transport:
    """Canned mapper payload; counts every worker call by stage."""

    def __init__(self, mapper_payload: dict):
        self.mapper_payload = mapper_payload
        self.calls: list[str] = []

    async def call_mapper(self, text: str) -> Any:
        self.calls.append("mapper")
        return {
            "parts": [
                {"data": self.mapper_payload},
                {"text": "Interpretation ready."},
            ]
        }

    async def call_allocator(self, text: str) -> Any:  # pragma: no cover - must not run
        self.calls.append("allocator")
        raise AssertionError("allocator must not be called by these cases")

    async def call_deployer(self, text: str) -> Any:  # pragma: no cover - must not run
        self.calls.append("deployer")
        raise AssertionError("deployer must not be called by these cases")


def _seed(text: str) -> dict:
    return {
        "messages": [HumanMessage(content=text)],
        "correlation_id": "a" * 32,
        "principal": "unit-test",
        "workflow_status": NetworkProvisioningStatus.RECEIVED_REQUEST.value,
        "deadline": default_deadline(),
    }


def _config() -> dict:
    return {"configurable": {"thread_id": "unit-capability"}}


async def _run(monkeypatch, capability, text: str, payload: dict | None = None):
    from langchain_core.runnables import RunnableLambda

    reads = {"n": 0}

    def _counting():
        reads["n"] += 1
        return capability

    monkeypatch.setattr(graph_mod, "read_srv6_capability", _counting)
    transport = _Srv6Transport(payload if payload is not None else _srv6_interpretation())
    llm_factory = lambda **kw: RunnableLambda(lambda _in: AIMessage(content="provisionable"))  # noqa: E731
    graph = ProvisioningGraph(llm_factory=llm_factory, transport=transport)
    state = await graph.ainvoke(_seed(text), _config())
    await graph.close()
    reset_audit_sink()
    return state, transport, reads


class TestCapabilityGate:
    @pytest.mark.parametrize(
        "capability",
        [
            SRv6Capability(available=False, supported=(), verifiable_attachments=()),
            # an unreadable cluster and a profile without the capability are
            # the same fail-closed shape the reader produces
            SRv6Capability(available=False, supported=("ip-vrf/vpn",), verifiable_attachments=()),
        ],
    )
    def test_unavailable_capability_refuses_r4_before_mapper(self, monkeypatch, capability):
        state, transport, reads = asyncio.run(_run(monkeypatch, capability, SRV6_REQUEST))
        assert state["workflow_status"] == NetworkProvisioningStatus.FAILED.value
        assert state["refusal_reason"] == (
            "SRv6 is not available on this lab profile: the capability has not been proven here."
        )
        assert reads["n"] == 1
        # BEFORE the mapper runs, and nothing claimed
        assert transport.calls == []
        assert not state.get("mapped_parameters")
        assert state.get("claimed_ids") in (None, [])

    def test_available_capability_lets_the_request_proceed(self, monkeypatch):
        state, transport, reads = asyncio.run(_run(monkeypatch, AVAILABLE, SRV6_REQUEST))
        assert state["workflow_status"] == NetworkProvisioningStatus.MAPPED.value
        assert transport.calls == ["mapper"]
        assert state.get("pending_action") == "confirm_1"
        assert reads["n"] == 1  # one read serves R4, R2 and R9 in the turn

    def test_non_srv6_request_never_triggers_the_read(self, monkeypatch):
        state, transport, reads = asyncio.run(
            _run(monkeypatch, AVAILABLE, VXLAN_REQUEST, _vxlan_interpretation())
        )
        assert reads["n"] == 0
        assert transport.calls == ["mapper"]
        assert state["workflow_status"] == NetworkProvisioningStatus.MAPPED.value
