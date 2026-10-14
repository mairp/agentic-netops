#!/usr/bin/env bash
# proof.sh — record and replay acceptance proofs for feature 004.
#
# Record:   scripts/proof.sh [--destructive] <name> -- <command...>
#   Runs <command...>, writes the exact command line to <name>.cmd and its
#   combined output plus an exit-code line to <name>.out under
#   .wiggum/features/004-srv6-service-requests/gates/proofs/ (created if
#   missing). Re-running the stored <name>.cmd line must regenerate <name>.out
#   (FR-039, SC-015), so neither file carries a timestamp.
#   --destructive records a proof that changes lab or device state; it also
#   writes an empty <name>.destructive marker. proof.sh exits with the
#   recorded command's exit code.
#
# Replay:   scripts/proof.sh replay <prefix> [--all]
#   Re-runs every stored <prefix>*.cmd in the order it was recorded (the
#   per-proof record order is kept in .record-order), renders output the same
#   way, compares with the stored <name>.out and prints the names that differ.
#   Exits non-zero when any compared proof differs. Destructive proofs (those
#   with a <name>.destructive marker) are skipped unless --all is given.
#
# Both subcommands expect the repo root as the working directory, so the
# recorded commands can use repo-relative paths (tasks.md "Path Conventions").
#
# PROOF_DIR overrides the proof directory (used by tests/unit/proof_sh_test.sh
# to stay out of the real gates tree); the default is the feature 004 path.
set -u
set -o pipefail

usage() {
    cat >&2 <<'EOF'
usage:
  scripts/proof.sh [--destructive] <name> -- <command...>
  scripts/proof.sh replay <prefix> [--all]
EOF
    exit 2
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PROOF_DIR="${PROOF_DIR:-$REPO_ROOT/.wiggum/features/004-srv6-service-requests/gates/proofs}"
ORDER_FILE="$PROOF_DIR/.record-order"

# Proof names are file names; keep them to a safe single-path-component shape.
valid_name() {
    [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]
}

# render_out <exit-code> <combined-output-file>: print the raw output,
# newline-terminated, followed by the exit-code line. The elapsed time a test
# runner prints in its summary line (pytest: "N passed in 2.78s") is
# normalized to ELAPSED at render time — both when recording and when
# replaying — so a re-run regenerates byte-identical output (FR-039, SC-015):
# durations necessarily differ between two live runs; nothing else in the
# summary line may.
render_out() {
    local exit_code="$1" out_file="$2"
    if [[ -s "$out_file" ]]; then
        sed -E 's/in [0-9]+\.[0-9]+s([ =]|$)/in ELAPSED\1/' "$out_file"
        [[ "$(tail -c 1 "$out_file")" == $'\n' ]] || printf '\n'
    fi
    printf '[exit code: %s]\n' "$exit_code"
}

cmd_record() {
    local name="$1"
    shift
    local destructive=0
    if [[ "$name" == "--destructive" ]]; then
        destructive=1
        name="$1"
        shift
    fi
    [[ $# -ge 2 && "$1" == "--" ]] || usage
    shift
    [[ $# -ge 1 ]] || usage
    valid_name "$name" || { echo "proof.sh: invalid proof name '$name'" >&2; exit 2; }

    local cmdline cap_tmp
    printf -v cmdline '%q ' "$@"
    cmdline="${cmdline% }"

    mkdir -p "$PROOF_DIR"
    cap_tmp="$(mktemp "$PROOF_DIR/.tmp.cap.XXXXXX")"

    bash -c "$cmdline" > "$cap_tmp" 2>&1
    local exit_code=$?

    printf '%s\n' "$cmdline" > "$PROOF_DIR/.tmp.$name.cmd"
    render_out "$exit_code" "$cap_tmp" > "$PROOF_DIR/.tmp.$name.out"
    rm -f "$cap_tmp"
    mv -f "$PROOF_DIR/.tmp.$name.cmd" "$PROOF_DIR/$name.cmd"
    mv -f "$PROOF_DIR/.tmp.$name.out" "$PROOF_DIR/$name.out"
    if [[ "$destructive" == 1 ]]; then
        : > "$PROOF_DIR/$name.destructive"
    fi

    # Remember the record order: drop any earlier position, then append, so a
    # re-recorded proof takes its latest recording position.
    if [[ -f "$ORDER_FILE" ]]; then
        grep -Fvx -- "$name" "$ORDER_FILE" > "$ORDER_FILE.next" || true
        mv -f "$ORDER_FILE.next" "$ORDER_FILE"
    fi
    printf '%s\n' "$name" >> "$ORDER_FILE"

    echo "proof recorded: $name (exit $exit_code) -> $PROOF_DIR/$name.out"
    return "$exit_code"
}

# ordered_names <prefix>: proof names whose <name>.cmd exists, in the order
# they were recorded (.record-order, a re-record takes its latest position),
# then any not yet indexed in ascending mtime order.
ordered_names() {
    local prefix="$1" name f base
    local -a indexed=()
    local -A known=()
    if [[ -f "$ORDER_FILE" ]]; then
        while IFS= read -r name; do
            [[ -n "$name" && "$name" == "$prefix"* && -f "$PROOF_DIR/$name.cmd" ]] || continue
            indexed+=("$name")
            known["$name"]=1
        done < "$ORDER_FILE"
    fi
    # Emit each indexed name at its LAST occurrence in the order file.
    local i j dup
    for ((i = 0; i < ${#indexed[@]}; i++)); do
        dup=0
        for ((j = i + 1; j < ${#indexed[@]}; j++)); do
            if [[ "${indexed[i]}" == "${indexed[j]}" ]]; then dup=1; break; fi
        done
        if [[ "$dup" == 0 ]]; then printf '%s\n' "${indexed[i]}"; fi
    done
    # Proofs not in the index: order by mtime, oldest first.
    while IFS= read -r f; do
        [[ -n "$f" ]] || continue
        base="$(basename "$f" .cmd)"
        [[ -n "${known[$base]:-}" ]] && continue
        known["$base"]=1
        printf '%s\n' "$base"
    done < <(ls -tr "$PROOF_DIR/$prefix"*.cmd 2>/dev/null || true)
}

cmd_replay() {
    local prefix="$1" all=0
    shift
    if [[ "${1:-}" == "--all" ]]; then
        all=1
        shift
    fi
    [[ $# -eq 0 ]] || usage

    local -a names=()
    mapfile -t names < <(ordered_names "$prefix")
    if [[ ${#names[@]} -eq 0 ]]; then
        echo "replay $prefix: no stored proofs match" >&2
        exit 2
    fi

    local name exit_code differ=0 compared=0 skipped=0 cap_tmp
    cap_tmp="$(mktemp "${TMPDIR:-/tmp}/proof.replay.XXXXXX")"

    for name in "${names[@]}"; do
        if [[ -f "$PROOF_DIR/$name.destructive" && "$all" != 1 ]]; then
            echo "skip $name (destructive; replay --all to include)"
            skipped=$((skipped + 1))
            continue
        fi
        bash -c "$(cat "$PROOF_DIR/$name.cmd")" > "$cap_tmp" 2>&1
        exit_code=$?
        if render_out "$exit_code" "$cap_tmp" | cmp -s - "$PROOF_DIR/$name.out"; then
            echo "ok $name"
        else
            echo "differ: $name"
            # diagnostic copy for the human; deliberately OUTSIDE the proofs
            # dir so it can never be mistaken for a stored artifact
            cp "$cap_tmp" "/tmp/proof-got-$name.txt" 2>/dev/null || true
            differ=$((differ + 1))
        fi
        compared=$((compared + 1))
    done
    rm -f "$cap_tmp"

    if [[ "$differ" -gt 0 ]]; then
        echo "replay $prefix: $differ of $compared proof(s) differ" >&2
        return 1
    fi
    if [[ "$compared" -eq 0 ]]; then
        echo "replay $prefix: nothing to replay (all $skipped skipped); use --all" >&2
        exit 2
    fi
    echo "replay $prefix: $compared proof(s) checked, no difference ($skipped skipped)"
}

if [[ $# -lt 1 ]]; then
    usage
fi
case "$1" in
    replay)
        [[ $# -ge 2 ]] || usage
        shift
        cmd_replay "$@"
        ;;
    -h|--help)
        usage
        ;;
    *)
        cmd_record "$@"
        ;;
esac
