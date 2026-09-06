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
