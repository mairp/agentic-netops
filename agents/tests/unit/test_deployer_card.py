"""Unit tests for the deployer's agent card (US4, spec FR-013).

The confirmation surface advertises the SRv6 capability in exactly the
wording the contract restates: "ip-vrf over srv6", "mac-vrf over srv6", and
the single gloss "(bridged EVPN over SRv6)" refusal R2 allows beside them.
No retired service name may appear anywhere in the card's strings — the
vocabulary rule that governs every operator-facing surface (FR-018).
"""
from __future__ import annotations

import re

from provisioning.deployer import card

RETIRED = re.compile(r"\b(vpls|vpws|e-line|l3vpn|l2l3-irb)\b", re.IGNORECASE)

RESTATED_FORMS = [
    "ip-vrf over srv6",
    "mac-vrf over srv6",
]

GLOSS = "(bridged EVPN over SRv6)"


def _card_strings() -> list[str]:
    """Every string the card carries, via its pydantic dump."""
    dumped = card.AGENT_CARD.model_dump()
    return [str(v) for v in _walk(dumped)]


def _walk(obj) -> list[str]:
    if isinstance(obj, str):
        return [obj]
    if isinstance(obj, dict):
        return [s for v in obj.values() for s in _walk(v)]
    if isinstance(obj, (list, tuple)):
        return [s for v in obj for s in _walk(v)]
    return []


def test_tags_carry_the_restated_srv6_forms():
    for form in RESTATED_FORMS:
        assert form in card.DEPLOY_SERVICE_SKILL.tags, form


def test_examples_carry_the_fr013_worded_lines():
    examples = card.DEPLOY_SERVICE_SKILL.examples
    assert any("ip-vrf over srv6" in e and "vpn signalling" in e for e in examples)
    assert any("mac-vrf over srv6" in e and "evpn signalling" in e for e in examples)
    assert any(GLOSS in e for e in examples)


def test_existing_tags_and_examples_are_kept():
    for tag in ("network", "provisioning", "deployer", "vlan", "mac-vrf", "ip-vrf", "acl"):
        assert tag in card.DEPLOY_SERVICE_SKILL.tags, tag
    assert any("mac-vrf service with allocated L2VNI" in e for e in card.DEPLOY_SERVICE_SKILL.examples)
    assert any("ip-vrf with allocated L3VNI" in e for e in card.DEPLOY_SERVICE_SKILL.examples)


def test_no_retired_vocabulary_anywhere_in_the_card_strings():
    offenders = [s for s in _card_strings() if RETIRED.search(s)]
    assert not offenders, f"retired vocabulary in the deployer card: {offenders}"


def test_no_retired_vocabulary_anywhere_in_card_module_source():
    source = (card.__file__ and open(card.__file__, encoding="utf-8").read()) or ""
    offenders = [line for line in source.splitlines() if RETIRED.search(line)]
    assert not offenders, f"retired vocabulary in card.py source: {offenders}"
