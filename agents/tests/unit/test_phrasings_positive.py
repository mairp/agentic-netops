"""US4/T066 — Legacy phrasing corpora acceptance with provenance.

This test exercises the positive phrasing runner over all corpora and asserts
that there are no violations — the runner itself enforces that the mapped
Interpretation JSON carries the construct service_type and, for legacy alias
corpora, the recorded source_service_type provenance.
"""
from __future__ import annotations

from agents.tests.corpus.phrasings import runner


def test_positive_phrasings_map_with_provenance():
    results = runner.run_positive()
    failures = [f"{r.case.id}: {', '.join(r.violations)}" for r in results if r.violations]
    assert not failures, "positive phrasing suite failures (service_type and source_service_type are enforced):\n" + "\n".join(failures)
