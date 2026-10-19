#!/usr/bin/env bash
# Unit tests for scripts/proof.sh (feature 004, tasks T001 and T632).
# Runs entirely in a temporary PROOF_DIR; no lab and no network needed.
#   bash tests/unit/proof_sh_test.sh
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PROOF_SH="$REPO_ROOT/scripts/proof.sh"

PASS=0
FAIL=0
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# run_proof <expected-rc> <args...>: run proof.sh with an isolated PROOF_DIR.
run_proof() {
    local expect="$1"
    shift
    local out rc
    out="$(PROOF_DIR="$WORK/proofs" bash "$PROOF_SH" "$@" 2>&1)"
    rc=$?
    printf '%s' "$out" > "$WORK/last-output"
    LAST_RC="$rc"
    if [[ "$rc" != "$expect" ]]; then
        echo "FAIL: proof.sh $* -> exit $rc (expected $expect)" >&2
        echo "$out" >&2
        FAIL=$((FAIL + 1))
        return 1
    fi
    return 0
}

check() { # check <description> <condition...>
    local desc="$1"
    shift
    if "$@"; then
        PASS=$((PASS + 1))
    else
        echo "FAIL: $desc" >&2
        FAIL=$((FAIL + 1))
    fi
}

# --- T001: record writes .cmd and .out, creating the directory --------------
run_proof 0 selftest -- true
check "record creates the proof directory" test -d "$WORK/proofs"
check "record writes selftest.cmd" test -f "$WORK/proofs/selftest.cmd"
check "record writes selftest.out" test -f "$WORK/proofs/selftest.out"
check ".cmd holds the exact command" grep -qx 'true' "$WORK/proofs/selftest.cmd"
check ".out holds the exit-code line" grep -Fqx '[exit code: 0]' "$WORK/proofs/selftest.out"

# Re-running the stored .cmd line regenerates the .out content (FR-039/SC-015).
cmd="$(cat "$WORK/proofs/selftest.cmd")"
bash -c "$cmd" > "$WORK/regen" 2>&1
rc=$?
{ cat "$WORK/regen"; printf '[exit code: %s]\n' "$rc"; } > "$WORK/regen.out"
check ".cmd re-run regenerates .out" cmp -s "$WORK/regen.out" "$WORK/proofs/selftest.out"

# Output (stdout+stderr) and a non-zero exit code are both captured.
run_proof 3 failing -- bash -c 'echo out; echo err >&2; exit 3'
check "recorded command's exit code is mirrored" test "$LAST_RC" = 3
grep -q '^out$' "$WORK/proofs/failing.out" && grep -q '^err$' "$WORK/proofs/failing.out"
check ".out holds combined output" test $? -eq 0
check ".out holds the failing exit code" grep -Fqx '[exit code: 3]' "$WORK/proofs/failing.out"

# Quoting round-trips: the stored line is re-runnable as written.
run_proof 0 quoted -- bash -c 'printf "a b\tc"'
bash -c "$(cat "$WORK/proofs/quoted.cmd")" > "$WORK/quoted.regen" 2>&1
check "quoted command round-trips" grep -qx 'a b	c' "$WORK/quoted.regen"

# --- T632: replay -------------------------------------------------------------
run_proof 0 echo-one -- echo one
run_proof 0 echo-two -- echo two
run_proof 0 replay echo-
check "replay reports no difference" grep -q 'no difference' "$WORK/last-output"
check "replay runs every stored proof in record order" \
    test "$(grep -c '^ok ' "$WORK/last-output")" = 2
check "replay keeps record order (one before two)" \
    test "$(sed -n 's/^ok //p' "$WORK/last-output" | tr '\n' ',')" = "echo-one,echo-two,"

# A stored .out that no longer matches prints the name and exits non-zero.
cp "$WORK/proofs/echo-one.out" "$WORK/echo-one.bak"
printf 'tampered\n[exit code: 0]\n' > "$WORK/proofs/echo-one.out"
run_proof 1 replay echo-
check "replay names the proof that differs" grep -q '^differ: echo-one$' "$WORK/last-output"
cp "$WORK/echo-one.bak" "$WORK/proofs/echo-one.out"

# Destructive proofs are skipped unless --all is given.
run_proof 0 --destructive destructive-proof -- true
check "record writes the destructive marker" test -f "$WORK/proofs/destructive-proof.destructive"
run_proof 2 replay destructive-proof
check "replay skips destructive proofs" grep -q '^skip destructive-proof' "$WORK/last-output"
run_proof 0 replay destructive-proof --all
check "replay --all runs destructive proofs" grep -q '^ok destructive-proof' "$WORK/last-output"
check "replay --all reports no difference" grep -q 'no difference' "$WORK/last-output"

# Ordering: a re-recorded proof takes its latest recording position.
run_proof 0 ord-a -- echo a
run_proof 0 ord-b -- echo b
run_proof 0 ord-a -- echo a
run_proof 0 replay ord-
check "re-recorded proof replays last" \
    test "$(sed -n 's/^ok //p' "$WORK/last-output" | tr '\n' ',')" = "ord-b,ord-a,"

# Refusals.
run_proof 2 replay no-such-prefix
check "replay with no matching proof fails loudly" \
    grep -q 'no stored proofs match' "$WORK/last-output"
run_proof 2 'bad name' -- true
run_proof 2 ../escape -- true

echo "proof.sh unit tests: $PASS passed, $FAIL failed"
if [[ "$FAIL" -gt 0 ]]; then
    exit 1
fi
