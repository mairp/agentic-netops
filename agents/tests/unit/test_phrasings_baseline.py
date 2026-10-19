"""T004/T005 — phrasing-corpus baseline snapshot (plan 1-01, 1-02).

Every case of the existing corpus files under
``agents/tests/corpus/phrasings/`` — the construct/alias corpora and the
``unsupported/`` corpora alike — is replayed through the deterministic mapper
(``MappingAgent``) and compared against
``agents/tests/corpus/phrasings/baseline_snapshot.json``.

The snapshot is the SC-016 instrument: feature 004 must not change how the
existing corpus maps. It is generated ONCE, before any mapper change
(T005: ``UPDATE_BASELINE=1 python -m pytest tests/unit/test_phrasings_baseline.py``
with ``git diff --quiet -- agents/provisioning/mapper`` clean), and from then
on this test fails on any drift — including the SRv6 recognition added later
in this phase (T008), which is why ``srv6_*`` corpus files are never replayed
into the snapshot (T006 adds one only after the snapshot exists).

``service_id`` is dropped from the comparison: the mapper generates it as a
random uuid4 hex prefix (T198), so it is not part of the mapping contract.
"""
from __future__ import annotations

import asyncio
import json
import os
import tempfile
from pathlib import Path

import yaml

from provisioning.mapper.agent import MappingAgent

CORPUS_DIR = Path(__file__).resolve().parents[1] / "corpus" / "phrasings"
SNAPSHOT_PATH = CORPUS_DIR / "baseline_snapshot.json"


def _corpus_files() -> list[Path]:
    """Every existing corpus file, positive and unsupported, never srv6_*."""
    files = sorted(CORPUS_DIR.glob("*.yaml")) + sorted(
        (CORPUS_DIR / "unsupported").glob("*.yaml")
    )
    # T006 adds unsupported/srv6_transport.yaml only AFTER the snapshot exists;
    # it is exercised by test_phrasings_srv6.py, not by this replay.
    return [p for p in files if not p.name.startswith("srv6_")]


def _cases_in(path: Path) -> list[dict]:
    data = yaml.safe_load(path.read_text(encoding="utf-8"))
    kind = "unsupported" if path.parent.name == "unsupported" else "positive"
    return [
        {"file": str(path.relative_to(CORPUS_DIR)), "kind": kind, "id": raw["id"], "text": raw["text"]}
        for raw in data.get("cases", [])
    ]


def _load_cases() -> list[dict]:
    cases: list[dict] = []
    for path in _corpus_files():
        cases.extend(_cases_in(path))
    return cases


def _normalize(interp) -> dict:
    dump = interp.model_dump(mode="json")
    dump.pop("service_id", None)  # random uuid4 hex prefix — not mapping contract
    return dump


def _replay(agent: MappingAgent) -> list[dict]:
    observed = []
    for case in _load_cases():
        _msg, interp = asyncio.run(agent.ainvoke(case["text"]))
        observed.append(
            {
                "file": case["file"],
                "id": case["id"],
                "interpretation": _normalize(interp),
            }
        )
    return observed


def _load_snapshot() -> list[dict]:
    data = json.loads(SNAPSHOT_PATH.read_text(encoding="utf-8"))
    return data["cases"]


def _write_snapshot(cases: list[dict]) -> None:
    payload = {
        "comment": (
            "T005 baseline: mapper output for every pre-existing phrasing corpus "
            "case, service_id dropped (random). Regenerate only with "
            "UPDATE_BASELINE=1 on an unmodified mapper "
            "(git diff --quiet -- agents/provisioning/mapper)."
        ),
        "cases": cases,
    }
    fd, tmp = tempfile.mkstemp(dir=str(SNAPSHOT_PATH.parent), suffix=".tmp")
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        json.dump(payload, fh, indent=1, sort_keys=False)
        fh.write("\n")
    os.replace(tmp, SNAPSHOT_PATH)


def _diff(baseline: list[dict], observed: list[dict]) -> list[str]:
    by_key = {(c["file"], c["id"]): c["interpretation"] for c in baseline}
    problems: list[str] = []
    for case in observed:
        key = (case["file"], case["id"])
        if key not in by_key:
            problems.append(f"{key[0]}/{key[1]}: missing from snapshot")
            continue
        base = by_key.pop(key)
        if base != case["interpretation"]:
            changed = [
                k
                for k in sorted(set(base) | set(case["interpretation"]))
                if base.get(k) != case["interpretation"].get(k)
            ]
            detail = "; ".join(
                f"{k}: {json.dumps(base.get(k), sort_keys=True)} -> "
                f"{json.dumps(case['interpretation'].get(k), sort_keys=True)}"
                for k in changed
            )
            problems.append(f"{key[0]}/{key[1]}: {detail}")
    for key in sorted(by_key):
        problems.append(f"{key[0]}/{key[1]}: in snapshot but not replayed")
    return problems


def test_phrasings_corpus_replays_to_baseline():
    agent = MappingAgent()
    observed = _replay(agent)
    assert observed, "no corpus cases found — loader is broken"
    if os.environ.get("UPDATE_BASELINE") == "1":
        _write_snapshot(observed)
    assert SNAPSHOT_PATH.exists(), (
        "baseline_snapshot.json missing — generate it first with "
        "UPDATE_BASELINE=1 pytest tests/unit/test_phrasings_baseline.py"
    )
    problems = _diff(_load_snapshot(), observed)
    assert not problems, (
        "corpus replay drifted from baseline_snapshot.json (SC-016):\n  "
        + "\n  ".join(problems[:20])
    )
