# Curation report — 004-srv6-service-requests (Worker B: agent-glm53)

Failure-history curation of the 004-srv6-service-requests specstride run, per
`evals/prompts/curate-failures-to-evals.md`. All outputs in this directory
(`evals/incidents/004-srv6-service-requests/agent-glm53/`); all analysis read from the
snapshot `raw/` (cut 2026-10-13 21:05:50 +04). The run was LIVE during curation
(chain7 pid 3538140, keeper pid 3195923 — both verified alive); nothing outside `evals/`
was modified.

## Deliverables

| File | Content | Count |
| --- | --- | --- |
| `dataset-inventory.md` | every proof group + chain logs + run-level datasets, classified clean/differ/garbage/in-progress/missing-receipt/honest-negative | 24 replay groups, 87+5 pairs, 1 phantom |
| `incidents.md` | narrative, chronological, artifact-cited | 33 incidents |
| `incidents.jsonl` | curated records (schema-complete, JSONL-validated) | 33 records |
| `anomaly-report.md` | checks A–J all run, measured, with artifacts + harness-gap list | 10 checks, 7 harness gaps |
| `cases.jsonl` + `EVAL-004-NNN.md` | eval cases with self-contained fixtures | 17 cases (11 agent-behavior, 6 harness-regression), 17 md files |

JSONL validation: both files pass `python3 -c 'import json;[json.loads(l) for l in open(...)]'`;
schema keys, enums, id uniqueness, and class coverage verified programmatically.

## Counts by class (incidents.jsonl)

script-bug 12 · run-incident 5 · design-gap 5 · poisoned-record 4 · orchagent-wedge 1 ·
false-clean-receipt 1 · preflight-refusal 1 · keeper-intervention 1 · provenance-gap 1 ·
yield-incident 1 · other 1 — total 33 (critical 7, major 16, minor 10).
`honest-negative` intentionally absent from incidents (correct negative results —
evpn2/evpn3 `not-achievable`, steering SC-007 5 s bound miss, `p1-image-by-digest` exit 1 —
are classified honest-negative in the inventory, per rule: a correct not-achievable proof is
not an incident).
Eval class coverage: all 11 incident classes have ≥1 eval (agent or harness).

## Top-5 anomalies

1. **False-clean steering receipt (08:39)** — chain2's D-phase overwrote 5 good steering
   records with PREFLIGHT-FAILED garbage on a wedged lab, then the receipt replayed garbage
   over garbage and printed `verdict=clean`. The single most dangerous failure in the run:
   byte-compare receipts prove determinism, not validity, and a gate consumer would have
   passed "steering proven" on it. (INC-004-022; EVAL-004-002/012)
2. **Orchagent wedge ×6 + cure evolution** — CONFIG rows present / APPL_DB empty / kernel
   never programmed; remedies escalated fresh-provision → in-guest restart (~3 min) →
   in-script `vrf_wedge_cure`; the remove+add dance on present rows is the re-wedge trigger
   and `docker restart swss` is destructive (start-limit + veth kill). (INC-004-020,
   INC-004-016; EVAL-004-001)
3. **Temporal invalidation of receipts** — `spike-rerun-evpn3` invalidated inside the
   snapshot itself (5/6 members re-recorded after it; fallback in flight at cut, R3-6.log
   still 0 bytes) and `spike-rerun-baseline` judged records replaced 4 h later. Receipts
   carry no member binding. (INC-004-030; EVAL-004-009/013)
4. **Poisoned-record machines** — vrf-apply recording half-programmed state with exit 0
   (04:1x) and chain4's WARN-continue re-recording baselines on a half-removed lab with a
   meaningless "no difference" dry: two designs that convert failure into green. (INC-004-021,
   INC-004-018; EVAL-004-003)
5. **Converge-only retry garbage loop** — `steer_step()` retried a wedge with converge;
   `D-1.log`≡`D-1-r2.log` and `D-2.log`≡`D-2-r2.log` byte-identical (md5-verified): the same
   failure re-recorded 4× across chains, each pass overwriting the previous garbage.
   (INC-004-024; EVAL-004-004/017)

## Top-5 evals

1. **EVAL-004-002 / 012** — refuse the false-clean receipt (agent) + deterministic
   false-clean gate (harness): the pairing that would have caught 08:39 at 08:39.
2. **EVAL-004-001** — wedge triage: refuse replay on a dead dataplane, guest read path,
   correct cure, explicit do-not list (distills the run's hardest-won knowledge).
3. **EVAL-004-013** — receipt temporal invalidation: two measured invalid receipts make a
   perfect deterministic fixture; zero-false-positive requirement included.
4. **EVAL-004-004 / 017** — garbage-loop tripwire: byte-identical failure re-records are a
   machine-checkable smell that neither chain nor model ever checked.
5. **EVAL-004-003** — WARN-continue refusal: tests whether a worker can overrule its own
   chain's design when the design poisons evidence ("the receipt will judge" is not a
   precondition check).

## UNVERIFIED (honest disclosure)

- **Post-snapshot chain7 progress**: verified at curation time that live `/tmp/g3/chain7.log`
  mtime (21:02:16) equals the snapshot copy and `chain7.done` is absent in both — no growth
  in that marker — but I did NOT re-analyze live chain state after the cut; R3-6, the evpn3
  receipt re-run, the R2 evpn2 fallback, and the baseline re-check may have completed since.
  The inventory is a point-in-time cut by design.
- **`inferred:` items** are marked inline in `incidents.md` (4 places): the INC-004-011
  agent-discipline classification, the INC-004-025 `|| true`-shape (inferred from the marker
  mismatch, not from reading the swallow site in the live script version at 20:25), the
  INC-004-023 handoff-quality judgment, and the INC-004-032 remaining-work figure (~8100 s is
  the keeper's journal estimate, not a measured queue).
- **PROGRESS.md middle reads**: several long reads were middle-pruned by the reader tool;
  I re-read all pruned ranges (lines 60–1323 covered across 6 passes), but two narrow spans
  (≈1130–1142 and ≈1190–1195) were reconstructed from adjacent context rather than read
  twice; no incident in the catalog rests solely on those spans.
- **Phase-1/2 era details** (INC-004-003/004/005/006) cite run.log/PROGRESS line numbers and
  proof `.out` files that I verified exist and contain the cited markers, but I did not
  re-run the 85-test rejection claim (INC-004-005) — it is quoted from PROGRESS.md:244.
- **Yield rewrite history** (16200→14400→18000→14400) is from yield-file mtimes + the
  journal; the intermediate contents of the superseded versions were not preserved in the
  snapshot (only the final file), so the sequence order of two of the four rewrites is
  inferred.
- **`receipts3.rc=127` deletion** (INC-004-029): PROGRESS.md:1277-1279 records the stale rc
  and its manual cleanup; the deleted file itself is not in the snapshot (expected), so only
  the journal attests the 127 value.

## Open questions for the harness owners

1. Should `proof.sh replay` refuse to print "clean" when member `.out` failure markers exist
   (check A), or is determinism-only semantics intentional and a separate validity layer
   required? The 08:39 event argues the former.
2. Receipts embedding member hashes (INC-004-030) would obsolete check D — is there a
   format-version path to add them without breaking existing `.out` consumers?
3. Should `.record-order` be transactional with pair persistence (INC-004-031), and who owns
   the `.tmp.cap.*` cleanup (5 leaked files found)?
4. Yield arm-time feasibility (check H) needs a cadence model — chain logs already contain
   per-step rc timestamps; is a shared estimator wanted in the launcher?
5. The untracked `scripts/spike/` (INC-004-028): commit target and timing are an owner
   decision, but the 87 recorded `.cmd` files hard-depend on it today.
6. PID hygiene (INC-004-029): record the process-group leader, validate before kill, and
   keep the authoritative pid in exactly one place (yield JSON vs `.pid` file disagree today).
