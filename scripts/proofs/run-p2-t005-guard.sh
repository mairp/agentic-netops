#!/usr/bin/env bash
# Proof p2-t005-guard (T005, plan 1-01): the baseline-snapshot generation
# guard, demonstrated end to end and recorded as a durable artifact.
#
# T005 requires agents/tests/corpus/phrasings/baseline_snapshot.json to be
# generated with UPDATE_BASELINE=1 ONLY after
# `git diff --quiet -- agents/provisioning/mapper` confirms the mapper is
# unmodified. In the LIVE worktree the mapper now carries the T008 SRv6
# recognition (a deliberate, later phase-2 change), so the guard's clean-diff
# precondition is reconstructed — not faked — in a THROWAWAY checkout of the
# phase-1 approved tree (git archive 89b497c7) plus the live untracked
# test/corpus files: exactly the tree state at the T005 moment (T004 test
# written first, mapper untouched). In order, this proof shows:
#   1. the live worktree's mapper diff is reported honestly (dirty: T008),
#      which is why the regeneration below must NOT run in the live tree;
#   2. in the throwaway tree, `git diff --quiet -- agents/provisioning/mapper`
#      is CLEAN (exit 0) — the guard's precondition, checked immediately
#      before the regeneration;
#   3. the LIVE snapshot replays green against that unmodified mapper with NO
#      flag (the criterion's "Done when"), before anything is regenerated;
#   4. UPDATE_BASELINE=1 regenerates the snapshot in the throwaway tree, and
#      the regenerated file is sha256-BYTE-IDENTICAL to the live snapshot —
#      so the shipped snapshot is exactly the unmodified-mapper capture.
# The live tree is never written: all regeneration happens under a throwaway
# directory that this script removes on exit. Output is deterministic (fixed
# throwaway path, fixed git commit dates) so proof.sh replay can verify it.
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SNAP_REL="agents/tests/corpus/phrasings/baseline_snapshot.json"
SNAP_LIVE="$REPO_ROOT/$SNAP_REL"
PYTEST="$REPO_ROOT/agents/.venv/bin/pytest"
PY="$REPO_ROOT/agents/.venv/bin/python"
BASE_COMMIT="89b497c7"
[[ -x "$PYTEST" ]] || { echo "run-p2-t005-guard.sh: missing $PYTEST" >&2; exit 3; }
[[ -f "$SNAP_LIVE" ]] || { echo "run-p2-t005-guard.sh: missing $SNAP_REL" >&2; exit 3; }
TMP="${TMPDIR:-/tmp}/t005-guard"

echo "== 1. live worktree mapper state (reported honestly) =="
if git -C "$REPO_ROOT" diff --quiet -- agents/provisioning/mapper; then
    echo "live: git diff --quiet -- agents/provisioning/mapper -> clean (exit 0)"
else
    echo "live: git diff --quiet -- agents/provisioning/mapper -> MODIFIED (exit 1)"
    echo "      (T008 SRv6 recognition is a deliberate phase-2 mapper change, so the"
    echo "       guard's clean-diff precondition is reconstructed below, in a"
    echo "       throwaway checkout of the phase-1 approved tree — never in place)"
fi

rm -rf "$TMP"
mkdir -p "$TMP"
trap 'rm -rf "$TMP"' EXIT
echo "== 2. throwaway checkout: git archive $BASE_COMMIT + live test/corpus files =="
git -C "$REPO_ROOT" archive "$BASE_COMMIT" agents | tar -x -C "$TMP"
git -C "$TMP" init -q -b proof
git -C "$TMP" add -A
GIT_AUTHOR_DATE="2026-10-12T00:00:00+00:00" GIT_COMMITTER_DATE="2026-10-12T00:00:00+00:00" \
    git -C "$TMP" -c user.name=t005-guard -c user.email=t005-guard@proof.local \
        -c commit.gpgsign=false -c core.hooksPath=/dev/null \
        commit -q -m "phase-1 approved tree ($BASE_COMMIT) — T005 guard baseline"
echo "throwaway HEAD: $(git -C "$TMP" log --format='%h %s')"
cp -R "$REPO_ROOT/agents/tests/corpus/phrasings/." "$TMP/agents/tests/corpus/phrasings/"
cp "$REPO_ROOT/agents/tests/unit/test_phrasings_baseline.py" "$TMP/agents/tests/unit/"
echo "cases in the live snapshot: $("$PY" -c "import json,sys;print(len(json.load(open(sys.argv[1]))['cases']))" "$SNAP_LIVE")"

echo "== 3. guard precondition, checked immediately before regeneration =="
if git -C "$TMP" diff --quiet -- agents/provisioning/mapper; then
    echo "git diff --quiet -- agents/provisioning/mapper -> clean (exit 0): mapper is the phase-1 approved mapper"
else
    echo "GUARD FAILED: agents/provisioning/mapper modified against $BASE_COMMIT"
    exit 1
fi

echo "== 4. Done-when first: the LIVE snapshot replays green against the unmodified mapper (no flag) =="
(cd "$TMP/agents" && "$PYTEST" tests/unit/test_phrasings_baseline.py)

echo "== 5. regenerate with UPDATE_BASELINE=1 (only now that the diff is proven clean) =="
(cd "$TMP/agents" && UPDATE_BASELINE=1 "$PYTEST" tests/unit/test_phrasings_baseline.py)

echo "== 6. regenerated snapshot vs live snapshot =="
echo "regenerated sha256: $(sha256sum "$TMP/$SNAP_REL" | cut -d' ' -f1)"
echo "live        sha256: $(sha256sum "$SNAP_LIVE" | cut -d' ' -f1)"
if cmp -s "$TMP/$SNAP_REL" "$SNAP_LIVE"; then
    echo "RESULT: byte-IDENTICAL — baseline_snapshot.json is exactly what the unmodified mapper regenerates with UPDATE_BASELINE=1"
else
    echo "RESULT: DIFFERS — the live snapshot is not the unmodified-mapper capture"
    exit 1
fi
