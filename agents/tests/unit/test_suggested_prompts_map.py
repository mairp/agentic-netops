"""Every served prompt must map — through the REAL mapper, not a stand-in.

``test_suggested_prompts_runnable.py`` runs the prompts through the supervisor
graph with the corpus harness's deterministic stand-in for the mapper worker.
That covers the supervisor: its guards, its classifier, its routing. It cannot
cover the mapper's own parse, and the parse is where the next failure was: the
mapper read endpoints out of "between A and B" and "attach A and B" but not
"across A and B", so three of the six served prompts — and the worked example
in CLARIFICATION_HINT — were answered with

    Before I can map this service I need: endpoints.

naming the one thing the operator had just given it. The deployed tier did this
with every one of those prompts while the whole test suite was green.

The mapper is deterministic (regex extraction, no model call), so the real
agent runs here directly.
"""

from __future__ import annotations

import json
import re
from pathlib import Path

import pytest

from common.schemas.interpretation import Interpretation
from provisioning.mapper.agent import MappingAgent

ROOT = Path(__file__).resolve().parents[3]
PROMPTS = ROOT / "agents" / "supervisors" / "provisioning" / "suggested_prompts.json"

CONSTRUCTS = ("mac-vrf", "ip-vrf", "acl", "vlan")


def _served_prompts() -> list[str]:
    prompts = json.loads(PROMPTS.read_text(encoding="utf-8"))
    assert prompts, "suggested_prompts.json is empty"
    return prompts


def _named_construct(text: str) -> str:
    low = text.lower()
    for construct in CONSTRUCTS:
        if re.search(rf"\b{construct.replace('-', '[- ]?')}\b", low):
            return construct
    raise AssertionError(f"no construct named in: {text!r}")


def _expected_attachments(text: str) -> set[tuple[str, str]]:
    """The (node, attachment) pairs the prompt spells out."""

    pairs = re.findall(r"\b(leaf\d+|spine\d+)\s+(ethernet\d+|wan\d+|eth\d+)\b", text, re.I)
    return {(n.lower(), a.lower()) for (n, a) in pairs}


@pytest.mark.parametrize("prompt", _served_prompts(), ids=[p[:48] for p in _served_prompts()])
async def test_served_prompt_maps_to_a_complete_interpretation(prompt: str) -> None:
    agent = MappingAgent()
    _message, interpretation = await agent.ainvoke(prompt)

    assert isinstance(interpretation, Interpretation)
    assert not interpretation.unsupported_properties, (
        f"mapper called this unsupported ({interpretation.unsupported_properties}): {prompt!r}"
    )
    assert not interpretation.missing_fields, (
        f"mapper asked for {interpretation.missing_fields} — the prompt supplies them: {prompt!r}"
    )
    assert interpretation.service_type.value == _named_construct(prompt)
    assert interpretation.tenant, f"no tenant parsed from: {prompt!r}"

    got = {(ep.site_or_node.lower(), ep.attachment.lower()) for ep in interpretation.endpoints}
    expected = _expected_attachments(prompt)
    assert expected, f"this test cannot check a prompt that names no node/port pair: {prompt!r}"
    assert got == expected, f"endpoints {sorted(got)} do not match the prompt's {sorted(expected)}: {prompt!r}"


def _filter_clause(text: str) -> bool:
    """The prompt asks for a filter, either as the acl construct or riding on
    another construct ("... permitting only ingress tcp port 443 ...")."""

    return re.search(r"\bacl\b|access[- ]list|\bpermitting\b|\bpermit\b|\ballow\b|\bdeny\b", text, re.I) is not None


@pytest.mark.parametrize("prompt", _served_prompts(), ids=[p[:48] for p in _served_prompts()])
async def test_a_prompt_that_asks_for_a_filter_gets_one(prompt: str) -> None:
    """A filter clause is never dropped on the way to the proposal.

    The composed shape — a mac-vrf that carries an access list bound to its own
    ports — is the one the tier advertises, and mapping it to a bare mac-vrf
    hands the operator a service that forwards exactly what they asked to
    block.
    """

    if not _filter_clause(prompt):
        pytest.skip("prompt asks for no filter")
    _message, interpretation = await MappingAgent().ainvoke(prompt)
    assert interpretation.acl is not None, f"the filter clause was dropped: {prompt!r}"
    assert interpretation.acl.stage in ("ingress", "egress")
    assert interpretation.acl.rules, "an access list with no rules filters nothing"


@pytest.mark.parametrize(
    ("text", "expected"),
    [
        (
            "extend vlan 100 as a mac-vrf across leaf01 ethernet2 and leaf02 ethernet2 for tenant acme",
            {("leaf01", "ethernet2"), ("leaf02", "ethernet2")},
        ),
        (
            "provision a mac-vrf between leaf01 ethernet1 and leaf02 ethernet2 for tenant acme vlan 100",
            {("leaf01", "ethernet1"), ("leaf02", "ethernet2")},
        ),
        (
            "give tenant acme an ip-vrf carrying 10.50.0.0/24 on leaf01 wan1",
            {("leaf01", "wan1")},
        ),
    ],
)
async def test_the_phrasings_the_tier_offers_are_parsed(text: str, expected: set[tuple[str, str]]) -> None:
    """The worked examples in DEFAULT_SUGGESTION and CLARIFICATION_HINT.

    A refused operator is told to say exactly these; the mapper has to read
    them, or the advice sends them back into the same clarification.
    """

    agent = MappingAgent()
    _message, interpretation = await agent.ainvoke(text)
    got = {(ep.site_or_node.lower(), ep.attachment.lower()) for ep in interpretation.endpoints}
    assert got == expected, f"parsed {sorted(got)} from {text!r}"
    assert not interpretation.missing_fields, interpretation.missing_fields
