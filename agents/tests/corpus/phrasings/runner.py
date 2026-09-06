"""Phrasing corpus runners — US2 polish (T355–T361, T119–T123).

This module provides two independent runners:

1) Unsupported phrasings (US2 T119–T123):
   Loads natural-language phrasings under
   ``agents/tests/corpus/phrasings/unsupported/*.yaml`` (transport
   engineering, pseudowire OAM, multicast, service chaining) and asserts
   FR-012 / SC-003 on every case — the refusal must NAME the exact
   unsupported property (Go literal) and the refusal is terminal, audited,
   and performs no worker calls and no device sessions.

2) Positive service phrasings (Phase 9 T355–T361):
   Loads natural-language service requests from
   ``agents/tests/corpus/phrasings/{vpls,vpws,l3vpn,irb}.yaml`` and verifies:
   - T359 — phrasing corpus loader: the four files are loaded with
     (service_type, id, text, first_pass) for every case.
   - T360 — first-pass correctness scoring: for cases with
     ``first_pass: true`` we assert the first pass reaches the MAPPED
     confirmation gate (pending_action == "confirm_1"), and the mapped
     Interpretation JSON names the expected ``service_type``.
   - T361 — clarifying-question assertion: for cases with
     ``first_pass: false`` we assert the mapper returns a clarification
     request (pending_action == "clarify"), carries ``missing_fields``,
     and the operator-facing message asks for the missing fields.

Run locally:
  cd agents && .venv/bin/python -m tests.corpus.phrasings.runner
Exit:
  0 iff every phrasing meets its assertions (both unsupported and positive).
"""

from __future__ import annotations

import asyncio
import json
from dataclasses import dataclass, field
from pathlib import Path
from typing import Iterable

import yaml
from langchain_core.messages import AIMessage

from supervisors.provisioning.graph.graph import (
    ProvisioningGraph,
    default_deadline,
    detect_unsupported_feature,
)
from tests.corpus.adversarial.runner import (
    AdversarialCase,
    StubClassifierLLM,
    StubTransport,
    _run_once,
    check_case,
)
from common.provisioning_states import NetworkProvisioningStatus
from langchain_core.runnables import RunnableLambda

# ----------------------------------------------------------------------------
# Unsupported-phrasings runner (US2 T119–T123).
# ----------------------------------------------------------------------------
UNSUPPORTED_DIR = Path(__file__).resolve().parent / "unsupported"
EXPECTED_PROPERTIES = ("tePolicy", "pseudowireOAM", "multicastVPN", "serviceChain")


def load_unsupported(root: Path = UNSUPPORTED_DIR) -> list[tuple[str, AdversarialCase]]:
    """Load every ``unsupported/*.yaml``; returns (property, case) pairs.

    Keeps the original acceptance harness for T123 and friends.
    """
    out: list[tuple[str, AdversarialCase]] = []
    for path in sorted(root.glob("*.yaml")):
        data = yaml.safe_load(path.read_text(encoding="utf-8"))
        property_name = data["property"]
        assert property_name in EXPECTED_PROPERTIES, f"{path.name}: unknown property {property_name!r}"
        for raw in data.get("cases", []):
            out.append(
                (
                    property_name,
                    AdversarialCase(
                        id=raw["id"],
                        category=data.get("category", path.stem),
                        text=raw["text"],
                        expect=raw.get("expect", "refusal"),
                        reason_contains=[f"unsupported property: {property_name}"],
                        assert_no_worker_calls=True,
                    ),
                )
            )
    return out


@dataclass
class UnsupportedResult:
    property_name: str
    case: AdversarialCase
    result: object | None
    violations: list[str] = field(default_factory=list)


def run_unsupported(root: Path = UNSUPPORTED_DIR) -> list[UnsupportedResult]:
    """Run every unsupported phrasing; return per-phrasing results."""
    results: list[UnsupportedResult] = []
    for property_name, case in load_unsupported(root):
        # Level 1 (T123): the deterministic detector maps the phrasing onto
        # the exact Go-literal property.
        hit = detect_unsupported_feature(case.text)
        if hit is None:
            results.append(UnsupportedResult(property_name, case, None, ["detector did not match the phrasing"]))
            continue
        if hit.family != property_name:
            results.append(
                UnsupportedResult(
                    property_name,
                    case,
                    None,
                    [f"detector named {hit.family!r}, the file requires {property_name!r}"],
                )
            )
            continue
        # Level 2 (T123): the full graph run — refusal naming the property.
        result = asyncio.run(_run_once(case, None, case.text, []))
        check_case(result)
        if f"unsupported property: {property_name}" not in (result.state.get("refusal_reason") or ""):
            result.violations.append(
                f"refusal_reason does not name the exact unsupported property {property_name!r}"
            )
        refuses = [e for e in result.sink_events if e.event_type == "refuse"]
        if refuses and not any(
            f"unsupported property: {property_name}" in (e.reason or "") for e in refuses
        ):
            result.violations.append(
                "the 'refuse' AuditEvent does not name the exact unsupported property (T105)"
            )
        results.append(UnsupportedResult(property_name, case, result, result.violations))
    return results


# ----------------------------------------------------------------------------
# Positive phrasings runner (Phase 9 T355–T361).
# ----------------------------------------------------------------------------
POS_DIR = Path(__file__).resolve().parent
POS_FILES = (
    # legacy alias corpora (US4): the request names an alias; the mapper folds
    # it and records source_service_type provenance.
    "vpls.yaml",
    "vpws.yaml",
    "l3vpn.yaml",
    "irb.yaml",
    # construct corpora (US1/T057): the request names the construct itself.
    "vlan.yaml",
    "macvrf.yaml",
    "ipvrf.yaml",
    "acl.yaml",
    "macvrf_gateway.yaml",
)

# The fold the mapper's model performs (contracts/interpretation.schema.json):
# an operator-named alias maps to the construct it folds to.
_FOLD_TO_CONSTRUCT = {
    "VPLS": "mac-vrf",
    "VPWS": "mac-vrf",
    "ELINE": "mac-vrf",
    "IRB": "mac-vrf",
    "L2L3-IRB": "mac-vrf",
    "L3VPN": "ip-vrf",
}


@dataclass(frozen=True)
class PositiveCase:
    id: str
    service_type: str  # the construct the request folds to, e.g. mac-vrf
    source_service_type: str | None  # the legacy alias the operator named, if any
    text: str
    first_pass: bool


@dataclass
class PositiveResult:
    case: PositiveCase
    state: dict | None
    violations: list[str] = field(default_factory=list)


def _load_positive_file(path: Path) -> Iterable[PositiveCase]:
    data = yaml.safe_load(path.read_text(encoding="utf-8"))
    declared = str(data.get("service_type") or "").strip()
    construct = _FOLD_TO_CONSTRUCT.get(declared.upper(), declared.lower())
    assert construct in ("vlan", "mac-vrf", "ip-vrf", "acl"), f"{path.name}: unsupported service_type {declared!r}"
    # US4/T066: allow an explicit provenance in the corpus; fall back to inference.
    explicit_src = data.get("source_service_type")
    explicit_src_s = str(explicit_src).strip().upper() if isinstance(explicit_src, str) and str(explicit_src).strip() else None
    inferred_src = declared.upper() if construct != declared.lower() else None
    expected_src = explicit_src_s or inferred_src
    for raw in data.get("cases", []):
        yield PositiveCase(
            id=raw["id"],
            service_type=construct,
            source_service_type=expected_src,
            text=raw["text"],
            first_pass=bool(raw.get("first_pass", True)),
        )


def load_positive(root: Path = POS_DIR) -> list[PositiveCase]:
    cases: list[PositiveCase] = []
    for fname in POS_FILES:
        p = root / fname
        if p.exists():
            cases.extend(list(_load_positive_file(p)))
    return cases


async def _run_first_pass(text: str) -> dict:
    """Run exactly one pass of the real graph with the deterministic harness.

    Returns the final state of that pass (MAPPED with confirm_1 or clarify).
    """
    llm = StubClassifierLLM()
    transport = StubTransport()
    graph = ProvisioningGraph(
        llm_factory=lambda streaming=None: RunnableLambda(llm.ainvoke),
        transport=transport,
    )
    try:
        config = {"configurable": {"thread_id": f"phr-{hash(text) & 0xffff:04x}"}}
        seed = {
            "messages": [{"type": "human", "content": text}],
            "correlation_id": "0" * 32,
            "principal": "phrasing-runner",
            "workflow_status": NetworkProvisioningStatus.RECEIVED_REQUEST.value,
            "deadline": default_deadline(),
        }
        return await graph.ainvoke(seed, config=config)
    finally:
        await graph.close()


def run_positive(root: Path = POS_DIR) -> list[PositiveResult]:
    results: list[PositiveResult] = []
    cases = load_positive(root)
    for case in cases:
        state = asyncio.run(_run_first_pass(case.text))
        v: list[str] = []
        status = state.get("workflow_status")
        pending = state.get("pending_action")
        last_msg = ""
        for msg in reversed(state.get("messages", [])):
            if isinstance(msg, AIMessage):
                last_msg = msg.content
                break
        mapped_json = state.get("mapped_parameters") or ""
        # T360 — first-pass correctness scoring
        if case.first_pass:
            if status != NetworkProvisioningStatus.MAPPED.value:
                v.append(f"expected MAPPED on first pass, got status={status!r}")
            if pending != "confirm_1":
                v.append(f"expected confirm_1 pending_action on first pass, got {pending!r}")
            try:
                if mapped_json:
                    interp = json.loads(mapped_json)
                    st = interp.get("service_type") or interp.get("serviceType")
                    if str(st or "").lower() != case.service_type:
                        v.append(
                            f"mapped service_type {st!r} does not match expected construct {case.service_type!r}"
                        )
                    # Provenance (US4/T066): a legacy alias is recorded as the
                    # source of the fold; a construct-named request records none.
                    src = interp.get("source_service_type")
                    if src != case.source_service_type:
                        v.append(
                            f"source_service_type {src!r} does not match expected {case.source_service_type!r}"
                        )
                else:
                    v.append("missing mapped_parameters JSON on first pass")
            except Exception as exc:  # noqa: BLE001
                v.append(f"invalid mapped_parameters JSON: {exc}")
        # T361 — clarifying-question assertion for non-first-pass cases
        else:
            if status != NetworkProvisioningStatus.MAPPED.value:
                v.append(f"expected MAPPED on clarification cases, got status={status!r}")
            if pending != "clarify":
                v.append(f"expected pending_action=clarify, got {pending!r}")
            missing_fields = state.get("missing_fields") or []
            if not missing_fields:
                v.append("missing_fields not recorded on clarification case")
            if "Before I can map this service I need" not in (last_msg or ""):
                v.append("clarifying prompt not emitted in operator-facing message")
        results.append(PositiveResult(case, state, v))
    return results


# ----------------------------------------------------------------------------
# CLI entrypoint — run both suites and print a concise summary.
# ----------------------------------------------------------------------------

def _print_summary(title: str, failures: list[str]) -> None:
    print(title)
    if failures:
        for line in failures:
            print(f"  - {line}")
    else:
        print("  OK")


def main(argv: list[str] | None = None) -> int:
    failed = 0

    # Unsupported phrasing suite
    u_results = run_unsupported()
    u_failed = [f"{r.property_name}/{r.case.id}: {', '.join(r.violations)}" for r in u_results if r.violations]
    _print_summary("Unsupported phrasings (T119–T123)", u_failed)
    failed += len(u_failed)

    # Positive phrasing suite
    p_results = run_positive()
    p_failed = [
        f"{r.case.service_type}/{r.case.id}: {', '.join(r.violations)}" for r in p_results if r.violations
    ]
    _print_summary("Positive phrasings (T355–T361)", p_failed)
    failed += len(p_failed)

    total_cases = len(u_results) + len(p_results)
    total_passed = total_cases - failed
    print(f"\n{total_passed}/{total_cases} phrasing cases passed")
    return 0 if failed == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
