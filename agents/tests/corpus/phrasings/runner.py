"""Unsupported-phrasings corpus runner — US2 (T119-T123).

Loads the natural-language phrasings under
``agents/tests/corpus/phrasings/unsupported/*.yaml`` (T119-T122: transport
engineering, pseudowire OAM, multicast, service chaining) and asserts the
FR-012 / SC-003 property on every case:

* **T123 — unsupported-property naming assertion**: the refusal must NAME
  the exact unsupported property — the Go literal the translator rejects
  with (``tePolicy``, ``pseudowireOAM``, ``multicastVPN``, ``serviceChain``;
  see ``common/schemas/normalized_intent.py::UnsupportedClaims``). The
  assertion is on two levels: the deterministic detector
  (``graph.py::detect_unsupported_feature``) must map the phrasing onto
  the file's ``property``, and the operator-facing ``refusal_reason``
  recorded in graph state (and the ``refuse`` audit event) must contain
  ``unsupported property: <property>``.
* the refusal is terminal (FAILED at END), explained, audited, and
  performs no worker calls and no device sessions (same harness as the
  adversarial runner — the refusal holds before any model call or worker
  transport is touched).

Run:  cd agents && .venv/bin/python -m tests.corpus.phrasings.runner
Exit: 0 iff every phrasing is refused with the exact property named.
"""

from __future__ import annotations

import asyncio
from dataclasses import dataclass, field
from pathlib import Path

import yaml

from supervisors.provisioning.graph.graph import detect_unsupported_feature
from tests.corpus.adversarial.runner import AdversarialCase, _run_once

UNSUPPORTED_DIR = Path(__file__).resolve().parent / "unsupported"
EXPECTED_PROPERTIES = ("tePolicy", "pseudowireOAM", "multicastVPN", "serviceChain")


def load_phrasings(root: Path = UNSUPPORTED_DIR) -> list[tuple[str, AdversarialCase]]:
    """Load every ``unsupported/*.yaml``; returns (property, case) pairs."""
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
class PhrasingResult:
    property_name: str
    case: AdversarialCase
    result: object
    violations: list[str] = field(default_factory=list)


def run_phrasings(root: Path = UNSUPPORTED_DIR) -> list[PhrasingResult]:
    """Run every phrasing; return per-phrasing results with violations."""
    results: list[PhrasingResult] = []
    for property_name, case in load_phrasings(root):
        # Level 1 (T123): the deterministic detector maps the phrasing onto
        # the exact Go-literal property.
        hit = detect_unsupported_feature(case.text)
        if hit is None:
            results.append(PhrasingResult(property_name, case, None, ["detector did not match the phrasing"]))
            continue
        if hit.family != property_name:
            results.append(
                PhrasingResult(
                    property_name, case, None,
                    [f"detector named {hit.family!r}, the file requires {property_name!r}"],
                )
            )
            continue
        # Level 2 (T123): the full graph run — refusal naming the property.
        result = asyncio.run(_run_once(case, None, case.text, []))
        from tests.corpus.adversarial.runner import check_case

        check_case(result)
        if f"unsupported property: {property_name}" not in (result.state.get("refusal_reason") or ""):
            result.violations.append(
                f"refusal_reason does not name the exact unsupported property {property_name!r}"
            )
        refuses = [e for e in result.sink_events if e.event_type == "refuse"]
        if refuses and not any(f"unsupported property: {property_name}" in (e.reason or "") for e in refuses):
            result.violations.append("the 'refuse' AuditEvent does not name the exact unsupported property (T105)")
        results.append(PhrasingResult(property_name, case, result, result.violations))
    return results


def main(argv: list[str] | None = None) -> int:
    results = run_phrasings()
    failed = 0
    for r in results:
        status = "PASS" if not r.violations else "FAIL"
        if r.violations:
            failed += 1
        print(f"{status}  {r.property_name:<14} {r.case.id}")
        for violation in r.violations:
            print(f"      - {violation}")
    print(f"{len(results) - failed}/{len(results)} phrasings refused with the exact property named")
    return 0 if failed == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
