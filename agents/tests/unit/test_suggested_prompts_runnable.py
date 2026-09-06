"""Every prompt this tier offers an operator must actually run.

``test_suggested_prompts_ports_constructs.py`` checks the served set as text:
the constructs are named, the ports resolve at this site, the VLAN ids avoid
the reserved band, the ConfigMap and the UI fallback agree with the file, and
each prompt matches the two fallback-classifier regexes. Every one of those
passed while clicking a suggestion produced:

    one construct per request; you named: mac-vrf, vlan.
    Supported constructs: vlan, mac-vrf, ip-vrf, acl

because the first thing a request meets is not the classifier — it is the
supervisor's deterministic guard layer, and nothing ran a suggested prompt
through it. This module does, twice over:

1. every prompt is put through each guard the supervisor applies before it
   routes anything (direct device, unsupported property, one-construct-per-
   request, and the fallback classification the refusals rely on);
2. every prompt is then run through the REAL graph (``ProvisioningGraph``)
   with the corpus harness's deterministic classifier and worker transport,
   and must reach the first confirmation gate carrying the construct it named
   — not a refusal, not the capability blurb, not a clarification.

What this cannot see: the harness's mapper is the corpus runner's deterministic
parse, not the model. It reads the construct, the tenant, the attachments, the
vlan, the prefix, the acl block and the anycast gateway out of the request, so a
prompt that names one of those in a shape it cannot read is caught here — but a
clause it does not model at all is simply not carried. The filter clause in
"... permitting only tcp 443 from 10.0.0.0/24" is one such: this module proves
that prompt is not refused and maps as the mac-vrf it names, and the live mapper
decides whether the filter rides along with it.

The same two checks cover the worked examples the tier hands an operator in
its own refusal and clarification text. Those are the phrasings a refused
operator is told to use; when one of them is itself refused the thread has no
exit, which is exactly what "extend vlan 100 as a mac-vrf ..." did.
"""

from __future__ import annotations

import json
import re
from pathlib import Path

import pytest
from langchain_core.messages import AIMessage
from langchain_core.runnables import RunnableLambda

from common.provisioning_states import NetworkProvisioningStatus
from supervisors.provisioning.graph.graph import (
    CLARIFICATION_HINT,
    DEFAULT_SUGGESTION,
    DEVICE_FAMILY_SUGGESTIONS,
    ProvisioningGraph,
    _find_constructs,
    default_deadline,
    detect_direct_device,
    detect_unsupported_feature,
    fallback_classification,
)
from supervisors.provisioning.graph.shared import RequestClassification
from tests.corpus.adversarial.runner import (
    DeviceSessionRecorder,
    StubClassifierLLM,
    StubTransport,
)

ROOT = Path(__file__).resolve().parents[3]
PROMPTS = ROOT / "agents" / "supervisors" / "provisioning" / "suggested_prompts.json"

# The placeholders the offered examples use for the values an operator supplies.
# They are substituted with names this site actually has, so the example is run
# the way an operator would run it.
PLACEHOLDERS = {
    "<siteA>": "leaf01",
    "<siteB>": "leaf02",
    "<portA>": "ethernet1",
    "<portB>": "ethernet2",
    "<tenant>": "acme",
}

# A worked example inside operator-facing text is quoted: "... e.g. 'extend
# vlan 100 as a mac-vrf across <siteA> <portA> ...'".
QUOTED_EXAMPLE = re.compile(r"'([^']{20,})'")

CONSTRUCTS = ("mac-vrf", "ip-vrf", "acl", "vlan")


def _served_prompts() -> list[str]:
    prompts = json.loads(PROMPTS.read_text(encoding="utf-8"))
    assert prompts, "suggested_prompts.json is empty"
    return prompts


def _offered_examples() -> dict[str, str]:
    """The worked examples the tier offers, keyed by where it offers them.

    Every refusal carries a suggestion and every clarification carries a hint;
    both name a phrasing to use instead. An operator who follows one and is
    refused again has nowhere left to go.
    """

    sources = {
        "DEFAULT_SUGGESTION": DEFAULT_SUGGESTION,
        "CLARIFICATION_HINT": CLARIFICATION_HINT,
        **{f"DEVICE_FAMILY_SUGGESTIONS[{family}]": text for family, text in DEVICE_FAMILY_SUGGESTIONS.items()},
    }
    examples: dict[str, str] = {}
    for where, text in sources.items():
        for i, raw in enumerate(QUOTED_EXAMPLE.findall(text)):
            example = raw
            for placeholder, value in PLACEHOLDERS.items():
                example = example.replace(placeholder, value)
            assert "<" not in example, f"{where}: unsubstituted placeholder in {raw!r}"
            examples[f"{where}#{i}"] = example
    assert examples, "no worked example found in the tier's own refusal and clarification text"
    return examples


def _named_construct(text: str) -> str:
    """The construct the prompt asks for, longest name first so "mac-vrf" is
    not read as "vlan" in "extend vlan 150 as a mac-vrf"."""

    low = text.lower()
    for construct in CONSTRUCTS:
        if re.search(rf"\b{construct.replace('-', '[- ]?')}\b", low):
            return construct
    raise AssertionError(f"no construct named in: {text!r}")


def _prompt_ids(prompts: list[str]) -> list[str]:
    return [p[:48] for p in prompts]


# ---------------------------------------------------------------------------
# 1. The deterministic guard layer, which runs before anything is classified.
# ---------------------------------------------------------------------------
def _assert_passes_the_guards(text: str) -> None:
    constructs = _find_constructs(text)
    assert len(constructs) < 2, (
        f"the supervisor refuses this with 'one construct per request; you named: "
        f"{', '.join(sorted(constructs))}' before it classifies anything: {text!r}"
    )
    hit = detect_direct_device(text)
    assert hit is None, f"refused as a direct device action ({hit.reason if hit else ''}): {text!r}"
    hit = detect_unsupported_feature(text)
    assert hit is None, f"refused as an unsupported property ({hit.reason if hit else ''}): {text!r}"
    assert fallback_classification(text) is RequestClassification.PROVISIONABLE, (
        "the deterministic classifier the supervisor falls back to when the model is "
        f"unavailable does not read this as a provisioning request: {text!r}"
    )


@pytest.mark.parametrize("prompt", _served_prompts(), ids=_prompt_ids(_served_prompts()))
def test_served_prompt_passes_every_supervisor_guard(prompt: str) -> None:
    _assert_passes_the_guards(prompt)


@pytest.mark.parametrize(
    ("where", "example"),
    sorted(_offered_examples().items()),
    ids=sorted(_offered_examples()),
)
def test_offered_example_passes_every_supervisor_guard(where: str, example: str) -> None:
    """The phrasing a refusal tells the operator to use must not be refused."""

    _assert_passes_the_guards(example)


# ---------------------------------------------------------------------------
# 2. The real graph, end to end to the first confirmation gate.
# ---------------------------------------------------------------------------
async def _run(text: str, thread: str) -> tuple[dict, StubTransport, DeviceSessionRecorder]:
    recorder = DeviceSessionRecorder()
    transport = StubTransport()
    llm = StubClassifierLLM()
    graph = ProvisioningGraph(
        llm_factory=lambda streaming=None: RunnableLambda(llm.ainvoke),
        transport=transport,
    )
    try:
        with recorder:
            state = await graph.ainvoke(
                {"messages": [{"type": "human", "content": text}], "deadline": default_deadline()},
                config={"configurable": {"thread_id": thread}},
            )
    finally:
        await graph.close()
    assert not llm.fence_violations, f"classifier saw unfenced user text: {llm.fence_violations}"
    return state, transport, recorder


def _last_ai(state: dict) -> str:
    return next(
        (m.content for m in reversed(state.get("messages", [])) if isinstance(m, AIMessage)),
        "",
    )


async def _assert_reaches_the_confirmation_gate(text: str, thread: str) -> None:
    state, _transport, recorder = await _run(text, thread)

    assert not recorder.attempts, f"device session attempted while mapping a suggestion: {recorder.attempts}"
    assert state.get("refusal_reason") is None, (
        f"refused with {state.get('refusal_reason')!r}: {text!r}"
    )
    assert state.get("workflow_status") == NetworkProvisioningStatus.MAPPED.value, (
        f"expected MAPPED, got {state.get('workflow_status')!r} answering {_last_ai(state)[:160]!r}: {text!r}"
    )
    assert state.get("pending_action") == "confirm_1", (
        f"expected the first confirmation gate, got pending_action={state.get('pending_action')!r} "
        f"(missing_fields={state.get('missing_fields')!r}): {text!r}"
    )
    interpretation = json.loads(state.get("mapped_parameters") or "{}")
    assert interpretation.get("service_type") == _named_construct(text), (
        f"mapped as {interpretation.get('service_type')!r} but the prompt names "
        f"{_named_construct(text)!r}: {text!r}"
    )


@pytest.mark.parametrize("prompt", _served_prompts(), ids=_prompt_ids(_served_prompts()))
async def test_served_prompt_reaches_the_confirmation_gate(prompt: str) -> None:
    """A suggestion an operator clicks reaches the proposal, not an apology."""

    await _assert_reaches_the_confirmation_gate(prompt, f"suggested-{abs(hash(prompt))}")


@pytest.mark.parametrize(
    ("where", "example"),
    sorted(_offered_examples().items()),
    ids=sorted(_offered_examples()),
)
async def test_offered_example_reaches_the_confirmation_gate(where: str, example: str) -> None:
    """Following the tier's own advice must get further than the refusal did."""

    await _assert_reaches_the_confirmation_gate(example, f"offered-{abs(hash(example))}")


# ---------------------------------------------------------------------------
# 3. The guard still refuses what it exists to refuse.
# ---------------------------------------------------------------------------
@pytest.mark.parametrize(
    "text",
    [
        "provision a vlan and an ip-vrf between leaf01 ethernet1 and leaf02 ethernet2 for tenant acme",
        "give tenant acme a mac-vrf and an ip-vrf on leaf01 ethernet1",
        "extend vlan 100 as a mac-vrf across leaf01 ethernet1 and leaf02 ethernet2 for tenant acme, "
        "and an acl on leaf01 wan1",
        "create a vlan 130 on leaf01 ethernet1 and another vlan 140 on leaf02 ethernet1 as a mac-vrf",
    ],
)
def test_two_constructs_in_one_request_are_still_two(text: str) -> None:
    assert len(_find_constructs(text)) >= 2, (
        f"the one-construct-per-request guard no longer sees two services in: {text!r}"
    )


@pytest.mark.parametrize(
    "text",
    [
        # A vlan named as the tag an overlay carries, not as a second service.
        "extend vlan 150 as a mac-vrf across leaf01 ethernet1 and leaf02 ethernet1 for tenant blue",
        "create a mac-vrf on vlan 160 across leaf01 ethernet1 and leaf02 ethernet1 for tenant umbrella",
        "provision a mac vrf between leaf01 ethernet1 and leaf02 ethernet2 for tenant acme vlan 100",
        # An access list bound to the ports of the service being requested
        # (the attached shape US2/T050 requires the mapper to handle).
        "for tenant acme provision a mac vrf between leaf01 ethernet1 and leaf02 ethernet2 vlan 120 "
        "with an ingress ACL that allows tcp port 80 and denies all else",
    ],
)
def test_one_construct_qualified_by_another_is_one_request(text: str) -> None:
    assert len(_find_constructs(text)) == 1, (
        f"read as more than one service request, so the supervisor refuses it: {text!r} "
        f"-> {sorted(_find_constructs(text))}"
    )
