# GATE 1 Evidence — Phase 1: Setup (Shared Infrastructure), feature 004

Phase tasks T001, T632, T002, T003 — all complete. No Go code was changed (shell + docs
only); `/usr/lib/go-1.24/bin/go test ./...` (cwd `/root/agentic-netops`) exits 0.

## T001 — `scripts/proof.sh` record mode

**File created**: `scripts/proof.sh` (executable, `bash -n` clean).

- `scripts/proof.sh [--destructive] <name> -- <command...>` creates the directory
  `.wiggum/features/004-srv6-service-requests/gates/proofs/` (`mkdir -p`, line 77 in
  `cmd_record`, lines 59–102) and writes the **exact command** (shell-quoted with `printf %q`, line 74) to
  `<name>.cmd` and the **combined output plus exit code** (`render_out`, lines 50–57: raw
  stdout+stderr, newline-terminated, followed by the literal line `[exit code: N]`) to
  `<name>.out`. Neither file carries a timestamp, so re-running the stored `.cmd` regenerates
  the `.out` (FR-039/SC-015). `proof.sh` exits with the recorded command's exit code.
- Proof slice: `.wiggum/features/004-srv6-service-requests/gates/proofs/p1-scripts-proof-sh.txt`
  (whole file, line-numbered; `cmd_record` at lines 59–102, `render_out` at 50–57,
  `valid_name` at 44–46).

**Done-criterion satisfied**: the gate command `/usr/bin/bash scripts/proof.sh selftest -- true`
(cwd `/root/agentic-netops`) exits 0 and wrote both files:
`.wiggum/features/004-srv6-service-requests/gates/proofs/selftest.cmd` containing exactly `true`
and `.wiggum/features/004-srv6-service-requests/gates/proofs/selftest.out` containing exactly
`[exit code: 0]` — slices `p1-selftest-cmd.txt`, `p1-selftest-out.txt` in the same proofs dir.

## T632 — `scripts/proof.sh replay <prefix>`

**Same file**: `cmd_replay` (lines 137–183) and `ordered_names` (lines 107–135).

- `scripts/proof.sh replay <prefix>` re-runs every stored `<prefix>*.cmd` **in the order it was
  recorded**: the per-proof order is kept in `proofs/.record-order` (`cmd_record` appends at
  lines 93–99; a re-recorded name is moved to its latest position), unindexed files fall back to
  ascending mtime (`ordered_names`). Each output is rendered the same way (`render_out`) and
  compared with the stored `.out` via `cmp`; differing proofs print as `differ: <name>` and the
  command exits 1. Destructive proofs (recorded with `--destructive`, marked by an empty
  `<name>.destructive` file, line 89) are **skipped unless `--all`** (lines 156–161). A prefix
  matching nothing exits 2 with `no stored proofs match`.
- Proof slice: `p1-scripts-proof-sh.txt` (same file as T001; `cmd_replay` at 137–183).

**Done-criterion satisfied**: `/usr/bin/bash scripts/proof.sh replay selftest` (gate command)
prints `ok selftest` and `replay selftest: 1 proof(s) checked, no difference (0 skipped)`, exit 0.
Additional live behaviour checks run this pass (temporary `PROOF_DIR`): a tampered `.out` yields
`differ: <name>` + exit 1; `--destructive` proofs are skipped and reported by plain `replay`
(exit 2 when nothing else remains) and run under `replay --all`; re-record ordering moves the
proof to its latest position (`ord-b` before re-recorded `ord-a`).

## T002 — `docs/SRV6_SERVICE_RECIPE.md` skeleton [P]

**File created**: `docs/SRV6_SERVICE_RECIPE.md` (159 lines).

- One section each for the five recipe areas: `## 1. Underlay and locators`,
  `## 2. ip-vrf / vpn (L3VPN over SRv6)`, `## 3. ip-vrf / evpn (routed EVPN over SRv6)`,
  `## 4. mac-vrf / evpn (bridged EVPN over SRv6)`, `## 5. Steering` (headings at lines 34, 71,
  98, 117, 137; each section's empty table header `| item | verdict | proofs | note |` at
  67, 94, 113, 133, 157).
- **Every section starts with an "Approaches to try" list filled before the first attempt**
  (the phrase `Approaches to try (written before the first attempt):` appears in all five
  sections) — candidates grounded in `roadmap/srv6-enablement-research.md` (per-node identity
  and underlay BGP, `fcbb:bbbb:<node>::/48` uSID locator owned by bootstrap, GCU-over-SSH write
  path, FRR `segment-routing srv6` locator, `seg6_enabled`/`net.vrf.strict_mode`, kernel-`seg6`
  dataplane on ASIC `vs`, End.DT46 `decap_vrf`, EVPN Type-5 / Type-2-3, ingress-only steering on
  two spines) — explicitly marked as candidates to confirm or refute; no device command invented.
- **Empty verdict table** with columns `item | verdict | proofs | note` closes every section
  (the header row `| item | verdict | proofs | note |` appears 5 times).
- Proof slice: `.wiggum/features/004-srv6-service-requests/gates/proofs/p1-doc-recipe-symbols.txt`
  (whole file, line-numbered).

## T003 — `docs/SRV6_ACCEPTANCE_004.md` skeleton [P]

**File created**: `docs/SRV6_ACCEPTANCE_004.md` (48 lines).

- **One row per SC-001 to SC-018** (18 rows, lines 27–44), each with an empty Proofs cell and an
  empty Verdict cell; outcome column is a one-line restatement of
  `specs/004-srv6-service-requests/spec.md` Success Criteria.
- **Empty "Review records" section** (`## Review records`, line 46, marked "(empty — filled at
  T593, plan 12-25 ...)").
- Header rules record the proof-name discipline: proof via `scripts/proof.sh <name> -- <command>`,
  `.cmd` regenerates `.out` (SC-015), suffixed re-takes (`-default`, `-us4`, `-final`), and the
  `q17-*` proofs for SC-011.
- Proof slice: `.wiggum/features/004-srv6-service-requests/gates/proofs/p1-doc-acceptance-symbols.txt`
  (whole file, line-numbered).

## Automated test for the obligations

**File created**: `tests/unit/proof_sh_test.sh` — 20 assertions over `scripts/proof.sh` in an
isolated `PROOF_DIR`: both files written and directory created, exact-command round-trip (FR-039),
combined output + exit-code capture (including a failing command), quoting round-trip,
`replay` no-difference + record order (including re-record ordering), `differ:` naming + exit 1,
destructive skip and `--all`, no-match exit 2, invalid/escaping name refusals.
Run this pass: `20 passed, 0 failed` — durable replayable proof
`gates/proofs/p1-setup-unittest.{cmd,out}` (`bash scripts/proof.sh p1-setup-unittest -- bash
tests/unit/proof_sh_test.sh`; `replay p1-setup` reports no difference).
Slice: `gates/proofs/p1-tests-proof-sh-test.txt` (whole file, line-numbered).

## Gate commands observed this pass (cwd /root/agentic-netops)

| Command | Result |
| --- | --- |
| `/usr/lib/go-1.24/bin/go test ./...` | exit 0 (ok `tests/unit`, `tests/envtest`, `pkg/...`; no FAIL lines) |
| `/usr/bin/bash scripts/proof.sh selftest -- true` | exit 0; wrote `gates/proofs/selftest.cmd` (`true`) and `selftest.out` (`[exit code: 0]`) |
| `/usr/bin/bash scripts/proof.sh replay selftest` | exit 0; `ok selftest` … `1 proof(s) checked, no difference (0 skipped)` |

## Notes

- Pre-existing workdir changes **not** made by this phase and left untouched (hard rule):
  git shows `.gitignore` modified, `vendor/sonic-buildimage` modified, untracked
  `.mixture-of-loops/`, `tmp_research/`, `versions.lock.yaml.bak` — present before this phase's
  first command; recorded in `.wiggum/features/004-srv6-service-requests/PROGRESS.md`.
- Proof-slice files are named `p1-*.txt` (never `*.cmd`) so `replay <prefix>` cannot mistake them
  for recorded proofs; the only `selftest*` proof is the gate's own.
