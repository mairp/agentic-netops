"""T067 [P] [US5] Vocabulary guard.

Asserts no retired service name (vpls, vpws, e-line, l3vpn, l2l3-irb) appears
on operator-facing surfaces: README.md, TUTORIAL.md, docs/, agents/supervisors/,
agents/provisioning/mapper/ or ui/src, except when explicitly marked as
historical provenance.

Exclusions (grep-evaluable, per spec quickstart Scenario 7):
- Skip a file entirely when its first ten lines contain '<!-- vocabulary: historical -->'.
- Skip a line that carries the trailing marker '(migration alias)' (trailing
  sentence punctuation after the marker is still trailing).

Only text-like sources are scanned. Compiled bytecode under __pycache__ embeds
the very docstrings being checked, so scanning it reported the same line twice —
once from the source and once, unreadably, from the .pyc.

This test reads files as text and enforces those rules.
"""
from __future__ import annotations

import re
from pathlib import Path

RETIRED = re.compile(r"\b(vpls|vpws|e-line|l3vpn|l2l3-irb)\b", re.IGNORECASE)

ROOT = Path(__file__).resolve().parents[3]
CHECK_PATHS = [
    ROOT / "README.md",
    ROOT / "TUTORIAL.md",
    ROOT / "docs",
    ROOT / "agents" / "supervisors",
    ROOT / "agents" / "provisioning" / "mapper",
    ROOT / "ui" / "src",
]

# Suffixes that carry operator-facing prose. Anything else (bytecode, images,
# archives) is not a surface an operator reads.
TEXT_SUFFIXES = {
    ".md", ".txt", ".rst", ".py", ".ts", ".tsx", ".js", ".jsx",
    ".json", ".yaml", ".yml", ".sh", ".html", ".css",
}
SKIP_DIRS = {"__pycache__", "node_modules", ".pytest_cache", "dist", "build"}


def _is_scannable(p: Path) -> bool:
    if any(part in SKIP_DIRS for part in p.parts):
        return False
    return p.suffix.lower() in TEXT_SUFFIXES


def _is_marked(line: str) -> bool:
    """True when the line carries the trailing '(migration alias)' marker.

    Trailing sentence punctuation is tolerated: a prose line legitimately ends
    '... (migration alias).' and that is still the trailing marker.
    """
    return line.strip().rstrip(".;:,").endswith("(migration alias)")


def _skip_file(p: Path) -> bool:
    try:
        head = p.read_text(encoding="utf-8", errors="ignore").splitlines()[:10]
    except (UnicodeDecodeError, OSError):
        return False
    return any("<!-- vocabulary: historical -->" in line for line in head)


def test_no_retired_vocabulary_on_operator_surfaces():
    offenders: list[str] = []
    for base in CHECK_PATHS:
        if base.is_file():
            paths = [base]
        else:
            paths = [p for p in base.rglob("*") if p.is_file() and _is_scannable(p)]
        for p in paths:
            # consider only text-like files
            try:
                text = p.read_text(encoding="utf-8", errors="ignore")
            except (UnicodeDecodeError, OSError):
                continue
            if _skip_file(p):
                continue
            for i, line in enumerate(text.splitlines(), start=1):
                if _is_marked(line):
                    continue
                if RETIRED.search(line):
                    offenders.append(f"{p.relative_to(ROOT)}:{i}:{line.strip()}")
    assert not offenders, (
        "Retired vocabulary found on operator-facing surfaces — only migration "
        "alias/provenance contexts are permitted.\n"
        + "\n".join(offenders)
    )


# ---------------------------------------------------------------------------
# US4 — the SRv6 restatement forms (FR-013) and the one gloss refusal R2
# allows ("(bridged EVPN over SRv6)", spec KL-001) must be allowed by the
# guard as-is; the retired words must still be refused.
# ---------------------------------------------------------------------------

def test_fr013_restatement_forms_contain_no_retired_token():
    """The only forms shown on operator surfaces pass the guard untouched."""
    from supervisors.provisioning.prompts.system import (
        CLASSIFIER_PROMPT,
        PROVISIONABLE_CLASSIFICATION_PROMPT,
        UNSUPPORTED_CLASSIFICATION_PROMPT,
    )

    allowed = [
        "ip-vrf over srv6",
        "ip-vrf over srv6 with evpn signalling",
        "mac-vrf over srv6",
        "`mac-vrf over srv6` (bridged EVPN over SRv6) is not supported on this image.",
        # classifier prompts gained the qualifier and must stay clean
        PROVISIONABLE_CLASSIFICATION_PROMPT,
        UNSUPPORTED_CLASSIFICATION_PROMPT,
        CLASSIFIER_PROMPT,
    ]
    for text in allowed:
        assert not RETIRED.search(text), f"retired token in restated form: {text!r}"


def test_retired_vocabulary_is_still_refused():
    for word in ("VPLS", "VPWS", "e-line", "L3VPN", "L2L3-IRB", "vpls"):
        assert RETIRED.search(f"provision a {word} service"), word


def test_srv6_l3vpn_alias_still_trips_the_guard():
    '"SRv6 L3VPN" is an input alias (migration alias): scanned operator '
    "surfaces must still red unless the line carries the migration marker."
    line = "SRv6 L3VPN is accepted on input"
    assert RETIRED.search(line)
    assert not _is_marked(line)
    assert _is_marked("SRv6 L3VPN is accepted on input (migration alias).")
