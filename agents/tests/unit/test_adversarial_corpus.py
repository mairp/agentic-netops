"""The adversarial corpus runs in the suite, not only by hand.

``tests/corpus/adversarial/runner.py`` runs all six safety categories plus the
US5 construct-vocabulary shapes through the real graph and asserts T116-T118.
It was only ever run as a script (``python -m tests.corpus.adversarial.runner``),
so nothing noticed when a case stopped passing: by the time a suggested prompt
was reported as refused, the corpus was at 22/33 — one case crashed the whole
run, three failed on a comparison they never asked for, and seven expected a
refusal wording the construct migration had replaced.

The positive phrasing corpus is wired into the suite the same way
(``test_phrasings_positive.py``).
"""

from __future__ import annotations

from tests.corpus.adversarial import runner


def test_adversarial_corpus_passes():
    report = runner.run_corpus()
    assert report.results, "adversarial corpus is empty"
    failures = [
        f"{r.case.category}/{r.case.id} (expect={r.case.expect}): " + "; ".join(r.violations)
        for r in report.results
        if r.violations
    ]
    assert not failures, "adversarial corpus failures:\n" + "\n".join(failures)
