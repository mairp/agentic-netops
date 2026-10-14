# Incident catalog — 004-srv6-service-requests (Worker B: agent-glm53)

31 reconstructed incidents from the snapshot at `evals/incidents/004-srv6-service-requests/raw/`
(= `RAW`; shorthands as in `dataset-inventory.md`: `G3`, `WG`, `MOL`, `PROOF`).
Every incident cites ≥1 artifact in the snapshot or the read-only repo. Classes follow the
prompt's schema; `inferred:` marks reasoning beyond direct artifact text. Correct, properly
proved negative results (e.g. evpn2/evpn3 `not-achievable`, `p1-image-by-digest` exit 1) are
**not** incidents — they are classified `honest-negative` in the inventory.

Severity scale: `critical` (invalid/dangerous state reached or recorded), `major` (wrong or
misleading evidence produced; significant rework), `minor` (friction, recovered locally).

---

## Phase-1/2 (harness + qualification era, 2026-10-11 → 2026-10-12 morning)

### INC-004-001 — Launcher SIGINT killed the whole run (exit 130)
- **Class:** run-incident · **Severity:** critical · **When:** 2026-10-12 00:30:26
- Launcher pid 898228 (pgid 898228) died with exit 130 = SIGINT; state.json
  `exit_reason: interrupted`; no auto-restart (correct per contract: interrupted ≠ crash).
  §8 of the incident report supersedes two wrong earlier hypotheses (idle reaping / nohup
  invasiveness): the real cause was a `dsh-web.service` crash → systemd killed the whole
  cgroup → SIGINT delivered to the launcher. A critic verdict was lost mid-flight.
- **Artifacts:** `MOL/INCIDENT-20261012-launcher-sigint.md` (§1–§8);
  `MOL/.mixture-of-loops/runs/004-srv6-service-requests.stopped-exit130-20261012/harness-run.json`
  (contract_digest fe05f794…, pgid 898228); `MOL/relaunch-20261012.log`.
- **Detectable gap:** no watcher fired for 4h45m until a human relaunched at 05:15 — a
  hang detection/milestone alert regression (`MOL/milestones-archive-20261012-13.log`).

### INC-004-002 — Diagnostician CONTEXT_WINDOW_EXCEEDED (twice, self-recovered)
- **Class:** run-incident · **Severity:** minor · **When:** 2026-10-12 00:16–00:18
- `gpt-5` diagnostician overflowed twice on the staged run log; each retry self-recovered.
  Indicates verdict-critical subagents run without a context budget guard.
- **Artifacts:** `MOL/INCIDENT-20261012-launcher-sigint.md` timeline (00:16:41, 00:17:52,
  00:18:0x entries); `WG/verdicts/` per-attempt verdict records.
- `inferred:` the root-cause call made after recovery was kept without re-verification
  against the earlier partial verdict (no artifact states a re-check happened).

### INC-004-003 — GATE2 attempt 1: argv defect (`bash -c` declared as script file) → exit 126
- **Class:** script-bug · **Severity:** major · **When:** 2026-10-12 (GATE2 attempt 1)
- The staged verification plan declared a multi-line shell string verbatim as the command
  file; run.log 110 shows the resulting `…: line 1: …: No such file or directory` /
  permission-style failure (`exit code: 126`).
- **Artifacts:** `WG/runs/20261011-214658-898303/run.log` line 110; `MOL/verification-commands.json`.

### INC-004-004 — Verification-plan staleness: accelerator edits staled the pre-built plan
- **Class:** design-gap · **Severity:** major · **When:** 2026-10-12 (GATE2 attempt 2)
- Attempt 2 failed the source-hash guard: plan built before the accelerator loop contained
  hash `9b670c75…`, the shipped accelerator was `8bc285c6…`. Mid-run gate edits cannot be
  reflected because plans are only created before the loop starts — plan refresh required a
  run restart, and the fixed plan then passed GATE2 in 15 min.
- **Artifacts:** `WG/runs/20261011-214658-898303/run.log` (hash-guard lines ~104–119);
  `WG/runs/20261011-214658-898303/accelerator-gate2.json` before/after pair.

### INC-004-005 — Replay determinism lie: telemetry race broke byte-compare receipts
- **Class:** script-bug · **Severity:** major · **When:** 2026-10-12 (phase 1)
- `OBSERVE_TELEMETRY` was read by nothing; the background OTLP exporter shut down mid-write,
  so `p1-agents` receipts differed on replay. First fix attempt (`OTEL_SDK_DISABLED=true`)
  broke **85** unit tests in `tests/test_llm_probe_integration.py` — rejected; real fix =
  local OTLP sink (test logger). Replay since no-difference.
- **Artifacts:** WG/PROGRESS.md:233-244, 255-259; `PROOF/p1-agents.out`; `G3/gate-*.log` (none — p1 era).

### INC-004-006 — T024 live ConfigMap drift + capability.sh mode-600 dead block
- **Class:** script-bug · **Severity:** minor · **When:** 2026-10-12 (phase 2)
- Live cluster ConfigMap diverged from the pinned local copy (stale `runner.image`+digest,
  5 drifted keys → live patched to pin). Also `scripts/capability.sh` embeds the guard
  inside `if [ -r /root/.profile ]; then` — on mode-600 unreadable profiles the whole
  guard silently doesn't exist; the mode-600 fix landed but a real root cause (non-root
  writer of the mode) was never found. Second unrelated T024 failure (Go proxy) was
  self-healed by root-cause patching.
- **Artifacts:** WG/PROGRESS.md:318-341; `PROOF/p2-configmap-sonic-image.out`,
  `PROOF/p2-pin-assert-live.out`, `PROOF/p2-t005-guard.out`.

## Phase-3, era 1 (2026-10-12 afternoon → 2026-10-13 05:15)

### INC-004-007 — T104 provision attempt 1: qualify gate failure after persistence-witness reload
- **Class:** run-incident · **Severity:** major · **When:** 2026-10-12 19:2x (pass 10)
- Fresh provision rc=0 but the qualify gate failed ("bgpd did not come up", EVPN-Type2
  duration >15 min) — the persistence-witness config reload left 31 template BGP peers in
  Connect; rc=1. A **second** kind cluster (`agentflow-005`) was found still loading on the
  host (known interference list). Attempt 2 with both conditions addressed → rc=0.
- **Artifacts:** WG/PROGRESS.md:746-777; `PROOF/p3-t104-fresh-redeploy.txt`; `PROOF/spike-persistence.out`.

### INC-004-008 — provision3/provision4 rc=1 false LAB-SICK; root cause measured later
- **Class:** script-bug · **Severity:** major · **When:** 2026-10-13 02:52–03:10 (pass 16)
- Provision appeared broken twice (rc=1), nearly triggering a full stop. Real cause:
  the qualify gate races VM bring-up and `config reload` loads the **generic image config**
  (hostname "sonic", empty state) because bootstrap never pushes the fabric config —
  the gate flaps depending on timing. Manual wire test 2/2 green on the same lab.
  Additionally the supervisor was invoked with a doubled path
  (`.mixture-of-loops/.../.mixture-of-loops/scripts/supervise.py`) → python `can't open file`,
  Errno 2 — the launcher commands in the pass journal were path-bugged.
- **Artifacts:** WG/PROGRESS.md:937-956, 978-984; G3/provision3.log, provision4.log;
  MOL/relaunch-20261013.log lines 1–2 (11:40:38 path error).

### INC-004-009 — Pass-4 factory incident: DEVICE_METADATA loss → bgpcfgd rendered NO neighbors
- **Class:** script-bug · **Severity:** major · **When:** 2026-10-12 ~07:35 (pass 4)
- An interrupted underlay-apply left BGP dead; first fix attempt (write only
  BGP_NEIGHBOR + LOOPBACK_INTERFACE) failed invisibly because the DEVICE_METADATA factory
  fields (bgp_asn, router_id) had been deleted — bgpcfgd then renders zero neighbors while
  exit codes stay 0. Fixed by restoring the full factory field set. Also locked in the
  GCU chunk-per-op rule (one table per patch; whole-patch abort semantics).
- **Artifacts:** WG/PROGRESS.md:517-527; `PROOF/spike-factory-*.out`; `PROOF/spike-underlay-apply-*.out`.

### INC-004-010 — Pass-5: bgpcfgd restart race + swallowed assertions; ECMP self-loop captured
- **Class:** script-bug · **Severity:** major · **When:** 2026-10-12 (pass 5)
- Restarting bgpcfgd left the apply script exiting 0 while its vtysh assertions were
  silently swallowed (`|| true` style) → `spine02` apply proof recorded **0 assertions
  executed**. Spine-spine underlay needed update-source (missing in the sonic template);
  an early route-map skewed ECMP into a **self-loop (packet looping to itself, captured)**;
  allowas-in was first applied on the wrong side (spines) before moving it to leaves.
- **Artifacts:** WG/PROGRESS.md:535-562; `PROOF/spike-underlay-apply-spine02.out`.

### INC-004-011 — Pass-6/7 false diagnosis: "silent v4 encap" blamed capture timing; real cause was nexthop encoding + SID placement
- **Class:** other (agent misdiagnosis) · **Severity:** minor · **When:** 2026-10-12 (passes 6–7)
- The agent first diagnosed the v4 dataplane failure as a capture-timing flake (two
  attempts with the same signature); the real root cause: FRR builds v4-mapped nexthops
  (`::ffff:10.1.0.1`) that no seg6 action accepts, and End.DT46's SID must live on a
  local /128 **not** on Loopback0, or decap breaks. Only re-derivation from evidence
  (not the earlier hypothesis) found it; the fix is exactly the documented recipe.
- **Artifacts:** WG/PROGRESS.md:573-631; `PROOF/spike-vpn-capture.out`; G3/evidence-final.md (recipe section).
- `inferred:` classifying this as an agent-discipline failure (accepted a comfortable
  explanation over a discriminating test) — the artifacts record the flip but not the
  reasoning at flip time.

### INC-004-012 — Export-knob default-table leak (tenant subnets leaked via default eBGP)
- **Class:** design-gap · **Severity:** minor · **When:** 2026-10-12 (pass 8)
- The documented export knob leaves rd/rt/sid exports leaking tenant subnets via the
  default eBGP session (default-table import); removal needs exact vtysh args
  (`no bgp vpn export …` line-precise). Recorded as a recipe hazard; later recipes carry it.
- **Artifacts:** WG/PROGRESS.md:633-655; G3/evidence-final.md; docs/SRV6_SERVICE_RECIPE.md (verdict tables).

### INC-004-013 — evpn3-setup builder bug: spine01's RR neighbors applied to BOTH spines
- **Class:** script-bug · **Severity:** minor · **When:** 2026-10-12 (pass 8 era)
- First evpn3 bring-up aborted with rc=1: the builder emitted one spine RR leg and applied
  spine01's neighbor list to both spines; the spine02 vtysh batch died on the foreign
  local-address. Regenerated per-node → green.
- **Artifacts:** WG/PROGRESS.md:685-689; `PROOF/spike-evpn3-kl006.out` (green after fix).

### INC-004-014 — vpn-rollback restore broken: python SyntaxError hidden behind 2>/dev/null; bare addresses fail YANG; node_run_i truncation
- **Class:** script-bug · **Severity:** critical · **When:** 2026-10-12 ~21:15 (pass 12)
- `vpn-rollback.sh` restore had a python snippet with an extra `}` → SyntaxError, invisible
  behind `2>/dev/null`; both leaves then lost fabric rows. Separate discover chains:
  writing GCU JSON with bare (`non-|`) addresses fails sonic_yang with a misleading error,
  and `node_run_i`'s ssh heredoc **silently truncates** long payloads — root-caused and
  replaced with `push_file` base64 pushes (lossless).
- **Artifacts:** WG/PROGRESS.md:788-824; G3/chain6.sh header (stage ordering notes);
  `PROOF/spike-vpn-rollback.out`.

### INC-004-015 — Pass-14: leaf02 bgp OOM (Exited 137) + receipt recorded against a still-converging lab
- **Class:** poisoned-record · **Severity:** major · **When:** 2026-10-13 00:10–23:04 era (pass 14)
- leaf02 bgp container OOM-died mid-capture (Exited 137, recovery via in-guest restart +
  memory-watcher). The 23:04 vpn replay differ (4/8) was recorded against a lab that was
  still converging — declared invalid later. The vicious cycle: container restart → peers
  flap → churn → another wedge; only a full in-guest stack restart + settle broke it.
- **Artifacts:** WG/PROGRESS.md:857-873, 875-891; `PROOF/spike-rerun-vpn.out` (superseded eras).

### INC-004-016 — `docker restart swss` is catastrophic; APPL_DB death misread as "slow converge"
- **Class:** script-bug · **Severity:** critical · **When:** 2026-10-13 01:25–02:52 (passes 15–16)
- leaf02 swss/APPL_DB died at 21:26 (orchagent stopped consuming); first interpretation was
  "slow convergence", then `docker restart swss` made it **worse**: the SIGKILL'd exit trips
  Docker's start-limit (unit needs `reset-failed`), and restarting the swss container kills
  containerlab's veths → the sonic VM never boots again (netns reduced to `lo`+`eth0`).
  Cure measured: in-guest `systemctl reset-failed + restart swss + start syncd bgp`.
- **Artifacts:** WG/PROGRESS.md:892-936, 951-963; `PROOF/spike-rerun-vpn.out` (differ eras);
  `G3/chain6.sh` (recovery function comments); `scripts/spike/vrf-apply.sh` (`vrf_wedge_cure`).

### INC-004-017 — seed-restore had THREE silent no-op bugs, all hidden by `|| true` / `2>/dev/null`
- **Class:** script-bug · **Severity:** critical · **When:** 2026-10-13 ~04:0x (pass 18)
- "Successful" seed-restore runs that patched nothing: (a) `config gcu` is not a real sonic
  command; (b) `docker cp` landed the patch inside the **launcher container's** filesystem,
  not the guest's; (c) the rollback helper name was `vrf-rollback.sh` while the script
  called `srv6-rollback.sh`. Every failure exited 0 → seed "passed" while leaving leftovers
  (spine01 converged rows) → later replays differed on exactly those rows.
- **Artifacts:** WG/PROGRESS.md:1023-1044; G3/chain6.sh header comment; G3/A-seed.log (15:24 = first truly green seed).

## Phase-3, era 2 (chain2 → chain7, 2026-10-13 05:23 → snapshot)

### INC-004-018 — Chain4 poisoned phase A: seed-restore removed /VRF before /INTERFACE; WARN-continue re-recorded baselines on a half-removed lab
- **Class:** poisoned-record · **Severity:** major · **When:** 2026-10-13 14:05–14:12
- Stage-1 of seed-restore removed `/VRF` before `/INTERFACE`; live leafref
  `decap_vrf → VRF_LIST` made sonic_yang reject the removal ("points to a non-existing
  leaf") → stage 1 exit 1 → stage 3 (re-add) never ran. chain4's design said "A-seed rc=1 —
  continuing, receipt will judge", so it recorded 4 baselines on a half-removed lab and the
  `A-dry` replay reported **no difference** — against comparands recorded in the same
  broken state, i.e. meaningless. Baselines overwritten 15:24 by chain6 (real records).
- **Artifacts:** G3/chain4.log (A-seed rc=1, A-b-*=0 14:08, A-dry=0, kill 14:12); G3/chain6.sh
  header comment (root cause + fix order: SRV6_MY_SIDS → SRV6_MY_LOCATORS → INTERFACE → VRF →
  BGP_NEIGHBOR → LOOPBACK_INTERFACE); WG/PROGRESS.md:1227-1240; `PROOF/spike-baseline-*.out` mtimes.

### INC-004-019 — Chain3 canary false-negative: launcher-netns exec + substring grep + probe before service state
- **Class:** script-bug · **Severity:** major · **When:** 2026-10-13 13:03–13:52
- Chain3 judged a healthy lab LAB-SICK and recorded nothing: its canary exec'd the
  **launcher container** (`docker exec <launcher> ip link show Vrf1` reads the launcher
  netns, never the guest — the exact known anti-pattern), grepped with
  `grep -q '0% packet loss'` (also matches "100% packet loss"), and probed the dataplane
  before service state existed. `Q1-recover provision` then failed the same way → LAB-SICK,
  done-marker `CHAIN3-DONE(lab-sick)`. Later canary logs (chain5/chain6 `canary*.log`) show
  the real signature was APPLY-STUCK, not "kernel Vrf1 missing".
- **Artifacts:** G3/chain3.log (Q1-canary=1 13:52, Q1-recover=1, done marker); G3/CANN.log;
  WG/PROGRESS.md:1195-1212 (pass 22 diagnosis); `scripts/spike/spike-env.sh` (node_run rule).

### INC-004-020 — The orchagent wedge itself (6 occurrences; cure evolved over the run)
- **Class:** orchagent-wedge · **Severity:** critical · **When:** passes 15/18/20 (wedges 1–3),
  chain5 14:2x (4th), chain6 17:06–19:17 (5th), chain7 ~19:46–20:37 (6th)
- After CONFIG_DB→APPL_DB churn (remove+re-add), orchagent's consumer skips the SETs:
  CONFIG_DB rows present, APPL_DB `VRF_TABLE`/`INTF_TABLE` empty, kernel never programmed,
  dataplane 100% loss while BGP still converges. Remedies measured: fresh provision (~25 min),
  in-guest `reset-failed + restart swss + start syncd bgp` (~3 min, keeper), and the
  in-script cure `vrf_wedge_cure` in vrf-apply.sh ("refined after the 6th wedge": RESTART —
  `systemctl start` is a no-op on active-but-wedged units; a remove+add dance on
  present-but-unprogrammed rows is the measured re-wedge trigger; joint restarts fail on
  dependency order).
- **Artifacts:** G3/chain5.log/.summary (4th); G3/chain6.log (5th; keeper abort 19:17);
  G3/chain7.log (6th; D-1/D-2 preflight fails, D-3-r2 green 20:38 after cure);
  `scripts/spike/vrf-apply.sh` (vrf_wedged/vrf_wedge_cure + wedge comments); WG/PROGRESS.md:1252-1284, 1286-1323.

### INC-004-021 — Poisoned records: half-programmed VRF recorded with exit 0 → every downstream receipt differed
- **Class:** poisoned-record · **Severity:** critical · **When:** 2026-10-13 04:1x–05:15
- vrf-apply.sh (pre-cure) recorded a half-programmed VRF (CONFIG row in, kernel absent) with
  **exit 0**; the sick-lab C-phase then recorded 5 vpn proofs where `spike-vpn-clients`
  literally shows `Cannot find device Vrf1` / `Invalid VRF` with exit 0. The 04:55 receipt
  differed 5/8 and every diagnosis chase (normalizers, whitespace) was wasted until the
  wedge was diagnosed as THE root cause; the pass-17 chain was killed at 05:15.
- **Artifacts:** `scripts/spike/vrf-apply.sh` lines ~123-128 (poison note); WG/PROGRESS.md:1058-1076,
  1093-1113; G3/runner.log (04:55 `spike-rerun-vpn verdict=differ`, C-7 04:28:40 rc=0).

### INC-004-022 — FALSE-CLEAN steering receipt: garbage replayed over garbage read as "clean"
- **Class:** false-clean-receipt · **Severity:** critical · **When:** 2026-10-13 07:12–08:39
- Chain2's D-phase (07:12–07:50) re-recorded all five steering proofs on a sick lab — every
  `.out` became `PREFLIGHT-FAILED … [exit code: 1]` garbage, **overwriting** the good
  2026-10-12 18:12 records. The 08:39 receipt then replayed the identical garbage over the
  identical garbage and printed `verdict=clean` — a byte-identical match of failures.
  The steering group thereby lost its only valid records for ~12 h and downstream consumers
  (evidence draft) kept saying "steering proven".
- **Artifacts:** G3/chain2.log (D-1..D-5 rc=1 07:12–07:50; spike-rerun-steering verdict=clean 08:39);
  `PROOF/spike-rerun-steering.out` (current era differ); WG/PROGRESS.md:1160-1168 (audit);
  MOL/relaunch-20261013.log ("Pass 1 replayed all 5 receipts: 4 differ + 1 false clean … then halting (stop.flag)").

### INC-004-023 — Keeper intervention: chain6 aborted (5th wedge; per-group recoveries exhausted)
- **Class:** keeper-intervention · **Severity:** major · **When:** 2026-10-13 19:17–19:22
- The keeper killed doomed chain6 (pid 1226866; summary written; A/B/C done, vpn replay
  differ 7/8), healed both leaves in-guest in ~3 min (`reset-failed`+`restart swss`,
  NOT `docker restart swss`), verified APPL_DB repopulated + kernel Vrf1 back, and shipped
  the `vrf_wedge_cure` into vrf-apply.sh. Healed lab, no re-provision.
- **Artifacts:** G3/chain6.done, chain6.summary; WG/PROGRESS.md:1286-1287;
  `scripts/spike/vrf-apply.sh`; G3/chain7.log (H2-clean 19:34 green post-heal).

### INC-004-024 — Steering D-phase garbage loop: converge-only retry can never heal a wedge; identical failure re-recorded 4×
- **Class:** preflight-refusal · **Severity:** major · **When:** 2026-10-13 07:12–07:50,
  18:08–19:09 (chain6), 19:46–20:25 (chain7)
- Each chain's steering retry is `steer_step()` = one bounded converge+retry — but the
  failure was a dataplane wedge, which converge cannot heal, so every retry re-recorded the
  SAME failure: chain6 D-1..D-5 all rc=1 with `-r2` retries also rc=1, chain7 D-1/D-2 failed
  twice each. `D-1.log` ≡ `D-1-r2.log` and `D-2.log` ≡ `D-2-r2.log` byte-for-byte (md5
  3520ea1e… / 85e56758…) — proof the loop re-recorded failure garbage without remediation,
  and each pass overwrote the previous garbage with new garbage.
- **Artifacts:** G3/D-1.log, D-1-r2.log, D-2.log, D-2-r2.log (md5 pairs); G3/chain7.sh
  (`steer_step` = converge+retry); G3/chain6.log 18:08–19:09; WG/PROGRESS.md:1168, 1256-1262.

### INC-004-025 — Steering bodies swallow VPN-SETUP-STUCK: misleading PREFLIGHT-FAILED label
- **Class:** script-bug · **Severity:** major · **When:** observed in the 19:59–20:25 garbage
- `steering-path.sh`/`steering-failover.sh` run `vpn-setup.sh || true`-style (the setup
  failure is swallowed) and then fail at the preflight ping — so the stored marker says
  `PREFLIGHT-FAILED` while the actual root cause one layer down is `VPN-SETUP-STUCK`
  (wedge). Misleading triage label on every steering failure of the day.
- **Artifacts:** `scripts/spike/steering-path.sh` (line 18 preflight guard + setup call);
  `PROOF/spike-steering-path.out`, `PROOF/spike-steering-failover-launcher.out` (both
  PREFLIGHT-FAILED); `scripts/spike/vpn-setup.sh` line 46 (VPN-SETUP-STUCK fail-loud).
- `inferred:` the `|| true`-shape is inferred from the marker mismatch (VPN-SETUP-STUCK
  never appears in the steering .out while vpn-setup provably failed in the window).

### INC-004-026 — stop.flag halt mid-proposer-pass + relaunch budget exhausted on launcher bugs
- **Class:** run-incident · **Severity:** minor · **When:** 2026-10-13 11:40–11:56
- Sequence: first relaunch died on the supervise.py doubled path (Errno 2); specstride start
  11:40:54 ran 3982362; the launch contract's stop.flag then halted it cleanly after pass 1
  (`propose.sh: stop.flag detected — stopping after pass 1`, exit 6 = contract-correct);
  the next relaunch attempt failed on `runtime.py: error: unrecognized arguments: --mode
  auto` (DIGEST state=failed exit 23, then exit 22, 11:41:43 TERMINAL) — relaunch budget
  2/2 consumed by launcher-side bugs before any model work; final relaunch 12:02 (4145257).
- **Artifacts:** MOL/relaunch-20261013.log (all of the above, timestamped);
  MOL/milestones.log (11:41:43 TERMINAL, 11:56:35 ORCH-3982362-EXIT);
  `WG/runs/20261013-114053-3982362/events.jsonl` (event `run_stop`, `reason: stop_flag`, phase 3).

### INC-004-027 — Watchdog progress_stall kills with EMPTY checkpoints
- **Class:** run-incident · **Severity:** minor · **When:** 2026-10-13 05:09 and 12:35 (+ earlier instances)
- The watchdog killed two long passes (`progress_stall`, elapsed 5832 s / 1924 s) and both
  checkpoints contain only the termination header — no state to resume from, so each
  successor pass re-derived context from PROGRESS.md alone. Pass-15's kill interrupted the
  receipts sweep mid-flight; pass-20's predecessor (10:45–12:35) was killed at 12:35.
- **Artifacts:** WG/pass-checkpoints/ (both files: "terminated by the specstride watchdog",
  `progress_stall`, no content); WG/PROGRESS.md:505 (pass 3 resume), 788, 826, 892 (pass 15), 1160-1161 (pass 20).

### INC-004-028 — `scripts/spike/` (all proof bodies) untracked in git
- **Class:** provenance-gap · **Severity:** major · **When:** present at snapshot
- The entire spike runner library — every proof body behind the GATE3 evidence — is
  untracked (`?? scripts/spike/`, not ignored). Any checkout/repro of the receipts depends
  on un-versioned files; a crash or clean would invalidate the whole recorded-proof corpus.
- **Artifacts:** `git status --porcelain scripts/spike/` → `?? scripts/spike/`;
  `git check-ignore -v scripts/spike/` → no rule (rc=1); last commit e56e0b40 (2026-10-12 06:15).

### INC-004-029 — Stale pid/rc hygiene: dead pid files, wrapper-vs-real pid confusion, poison rc
- **Class:** design-gap · **Severity:** minor · **When:** across 2026-10-13
- `chain2.pid` (1024502), `chain4.pid` (935362) and `chain6.pid` (1226866) outlive their
  processes; chain4's kill targeted **935363** while the stored pid was the wrapper
  935362; chain6's pid was 1226865/1226866 depending on file vs kill record;
  `chain7.pid` doesn't exist at all (pid only inside the yield JSON). `receipts3.rc=127`
  sat in /tmp/g3 from a permission-denied launch attempt until manually noticed/deleted.
- **Artifacts:** G3/chain{2,4,6}.pid (dead at snapshot), chain6.log (kill line), chain7.sh
  (writes no pid); WG/PROGRESS.md:1227-1234 (kill 935363), 1277-1279 (receipts3.rc=127), 1286-1287 (kill 1226866).

### INC-004-030 — Stale/invalid receipts: receipts outlive their member records (twice measured)
- **Class:** design-gap · **Severity:** major · **When:** at snapshot
- `spike-rerun-baseline.out` (11:32) compares against baselines that were re-recorded at
  15:24 — its `differ: spike-baseline-spine02` verdict refers to records that no longer
  exist. `spike-rerun-evpn3.out` (20:57:22) is invalidated *within the snapshot*: R3-1..R3-5
  were re-recorded 20:58:59–21:02:16 after it. No mechanism marks a receipt stale when a
  member changes; consumers must re-derive ordering by hand (the yield protocol's
  "then judge" relies on it).
- **Artifacts:** `PROOF/spike-rerun-baseline.out`, `PROOF/spike-baseline-*.out` (mtimes
  11:32 vs 15:24); `PROOF/spike-rerun-evpn3.out` vs `PROOF/spike-evpn3-*.out` (20:57 vs
  20:58–21:02); G3/chain7.log 20:57–21:02.

### INC-004-031 — restore-check phantom: record-order entry without stored proof
- **Class:** design-gap · **Severity:** minor · **When:** at snapshot
- `.record-order` lists `restore-check` but no `restore-check.cmd`/`.out` exists anywhere in
  the proofs dir — a replay that trusts `.record-order` for evidence coverage will count a
  proof that cannot be reproduced; also cmd/out counts balance at 87/87, so the phantom was
  never a deleted pair, only an order entry.
- **Artifacts:** `PROOF/.record-order` (entry `restore-check`); `ls PROOF | grep restore-check` → empty.

### INC-004-032 — Yield-deadline budgeting: chain6 armed 18000 s it could not spend
- **Class:** yield-incident · **Severity:** major · **When:** 2026-10-13 (chain6 era)
- The chain6-era yield rewrote deadline 16200→14400→18000→14400 (4 rewrites same day) while
  chain6 needed ~2h15 more than the remaining budget at abort time (19:17) — the keeper had
  to abort and re-yield as chain7 with a fresh 14400 s. A yield whose deadline cannot cover
  the remaining plan is detectable at arm time, not at expiry.
- **Artifacts:** WG/yield/*.json (both contracts + mtimes), WG/yield-jobs/*.rc;
  WG/PROGRESS.md:1286-1287 ("could not finish before the phase-3 yield deadline"); G3/chain6.done.

### INC-004-033 — Baseline capture nondeterminism: whitespace churn + normalizer edited AFTER the receipt
- **Class:** poisoned-record · **Severity:** minor · **When:** 2026-10-13 11:31–11:47
- Baselines re-recorded at 11:31 with the pre-squeeze script; the whitespace squeeze edit to
  baseline-capture.sh landed at 11:47 — after `spike-rerun-baseline.out` (11:32) had judged
  the group differ on spine02 (`never      DOWN` column jitter). The receipt therefore
  judged comparands that were already obsolete for the next replay. (Fix: FR-039
  normalization discipline; the 15:24 re-records are the current clean era.)
- **Artifacts:** WG/PROGRESS.md:1160-1164; `PROOF/spike-rerun-baseline.out` (differ spine02);
  `PROOF/spike-baseline-*.out` mtimes; G3/repair.summary.

---

**Counts:** 33 incidents, INC-004-001 … INC-004-033 (≥15 required).
Classes present: run-incident, script-bug, design-gap, other, poisoned-record,
orchagent-wedge, false-clean-receipt, preflight-refusal, keeper-intervention,
provenance-gap, yield-incident (11 classes; `honest-negative` is intentionally absent —
correct negative results are not incidents, see inventory §1).
Severity: critical ×7 (001, 014, 016, 017, 020, 021, 022), major ×16, minor ×10.
