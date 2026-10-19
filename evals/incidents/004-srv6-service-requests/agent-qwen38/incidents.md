# Incident reconstruction — feature 004 (SRv6 service requests)

Chronological narrative. All times +04. Structured records: `incidents.jsonl` (29 incidents).
Snapshot root: `evals/incidents/004-srv6-service-requests/raw/` (taken 2026-10-13 21:05:50).

## Phase A — 2026-10-12 evening → 2026-10-13 dawn (runs 3104859)

**2026-10-12 00:30:26 — INC-012 (run-incident, critical).** The mixture-of-loops launcher
(pid 898228) was killed by SIGINT (exit 130) during phase-2 attempt-4 `critic_start`; the
critic verdict was lost; run dir archived `*.stopped-exit130-20261012`. Nothing ran for
~4h45 — correct per contract (auto-relaunch only on `wall_budget` exit 4). Post-mortem
(`mol-004-20261013T210550/INCIDENT-20261012-launcher-sigint.md`) superseded its own first
theory: the host journal shows a `dsh-web.service` crash followed by a systemd cgroup kill.

**2026-10-12 21:26 → 10-13 02:10 — INC-001 (orchagent-wedge #1, critical).** leaf02 swss
silently stopped writing APPL_DB (`PROGRESS.md` pass 15 continued). The 00:55 vpn receipt
recorded 4 differs against the dead dataplane. Recovery attempt `docker restart swss` KILLED
the containerlab veth bindings (netns recreated, VM never rebooted — "lo+eth0 only") —
measured, never repeat. Remedy: fresh provision (`provision3.log`).

**01:30–02:52 — INC-002 (script-bug, minor).** provision3 and provision4 both rc=1 on the
EVPN-Type2 capability gate; measured root cause: the suite's persistence stage runs
`config reload` loading a GENERIC image config and the gate races post-reload VM bring-up;
wire manually verified healthy (`PROGRESS.md` pass 15/16). Documented remedy: plain retry.

**03:20–03:50 — INC-003 (script-bug, major).** receipts3 post-mortem (`PROGRESS.md` pass 17):
MAC/EUI-64 bytes regenerate on every redeploy and `spike-vpn-clients.out` held a failing
dataplane capture from pass-14 drift; byte-replay across redeploys could never pass.
Normalizers extended in spike-env.sh, baseline-capture.sh, vrf-apply.sh,
steering-failover.sh.

## Phase B — the poisoned morning (chain2, run 3104859)

**03:55–04:10 — INC-004 (script-bug, critical).** seed-restore.sh had three silent no-op
bugs: `config gcu` (no such subcommand — entrypoint is top-level `config apply-patch`),
`docker cp` into the launcher fs (guest never sees it), `vrf-rollback.sh` (wrong name) — all
hidden by `|| true` + `2>/dev/null` (`PROGRESS.md` pass 18). Consequence: spine01 kept
converged BGP rows; locators present on all 4 nodes ("expect none").

**04:10–05:15 — INC-005 (poisoned-record, critical; wedge #3).** On the sick lab the
04:28 `spike-vpn-clients.out` recorded "Cannot find device Vrf1" with **exit 0**; all five
vpn receipt differs share the wedge signature (CONFIG_DB rows present, APPL_DB empty,
kernel dead). Steering D-2/D-3 also garbage. Pass-17 chain + repair watcher killed 05:15
(INC-006); scripts hardened fail-loud (`PROGRESS.md` pass 18 addendum 3).

**05:51 — INC-007 (design-gap, major).** chain2 `RC A-seed=1` at 05:51:28 yet phase A
continued and re-recorded 4 baselines + "PHASE A done (dry=0)" (`chain2.log` lines 10–21).
WARN-continue on a non-seeded lab.

**07:12–07:50 — INC-008 (poisoned-record, critical).** chain2 D-1..D-5 all rc=1
(PREFLIGHT-FAILED) — the five steering re-records **overwrote the last good stored .out
copies** with garbage (`chain2.log` lines 45–54).

**08:39 — INC-009 (false-clean-receipt, critical).** `spike-rerun-steering verdict=clean`
(rc=0) — garbage replayed byte-identically over itself (`chain2.log` lines 56–57,
`chain2.summary` `spike-rerun-steering=clean`, `gates/proofs/spike-rerun-steering.out`).
The receipt mechanism compares bytes only and has no member-health notion.

**09:43–10:42 — INC-010 (other, major).** Remaining chain2 receipts differ: evpn3 09:43,
evpn2 10:40 (2/5), baseline 10:42 (spine02 jitter); `G-seed rc=1` at 10:42:15 with the
baseline receipt run 18 s later anyway (`chain2.log` lines 60–71).

**10:41–12:50 — INC-011 (script-bug, major).** G-seed kernel cleanup deleted kernel Vrf1
while CONFIG_DB kept rows → 12:50 canary APPLY-STUCK (`PROGRESS.md` pass 20); leafref-aware
stage-1 ordering fixed (SRV6_MY_SIDS first).

## Phase C — relaunch under run 4145257

**11:40 — INC-013 (run-incident, major).** Relaunch failed: `runtime.py: error:
unrecognized arguments: --mode auto`, `state=failed exit=23` (`mol-004-*/relaunch-20261013.log`).

**11:42–11:56 — INC-014 (run-incident, minor, control case).** stop.flag detected
mid-proposer-pass → clean halt exit 6; rerun resumed 12:02 (same log).

**12:35 — INC-015 (run-incident, minor).** Watchdog killed pass 1 (progress_stall, 1924 s,
empty checkpoint) — `pass-checkpoints/20261013-120241-4145257-…-123553.md`.

**13:03–14:00 — INC-016 (script-bug, critical).** chain3 declared LAB-SICK on a healthy lab:
its canary (1) `docker exec <launcher> ip link show Vrf1` read the launcher netns, not the
guest; (2) `grep -q '0% packet loss'` also matches "100% packet loss"; (3) probed the
dataplane before vpn-setup (`PROGRESS.md` pass 22, `chain3.log` 13:52:42 CANN=1).
chain4 written with the fixed canary.

**14:08–14:12 — INC-017 (poisoned-record, critical).** chain4 phase A poisoned:
seed-restore removed /VRF before /INTERFACE; sonic_yang rejected the removal (live leafref
`vrf_name=Vrf1`); stage 3 never ran; WARN-continue re-recorded all four baselines on the
half-removed lab; A-dry "no difference" was meaningless. Killed 14:12; ordering fixed and
validated 14:14 (`PROGRESS.md` pass 23).

**14:30 — INC-018 (orchagent-wedge #4, critical).** chain5 aborted in phase H: canary
APPLY-STUCK on the genuine wedge signature; guest diagnosis with swss.rec SET→DEL 1 s
evidence (`chain5.log`, `chain5.summary`, `failure-ledger.jsonl`). chain6 launched 14:42
with an H-gate recovery ladder.

## Phase D — chain6, the keeper, chain7 (live)

**15:31–19:09 — INC-019 (orchagent-wedge #5, critical).** chain6 recorded vpn green
(RV1..RV8 16:57–17:06) then its replay hit wedge #5: 7/8 APPLY-STUCK (17:59). Steering
D-1..D-4 recorded PREFLIGHT-FAILED garbage 18:08–19:09; recovery ladder exhausted
(`chain6.log`, `chain6.summary`).

**throughout D — INC-020 (design-gap, major).** `steer_step`'s bounded retry only
`converge`s (BGP), which survives a dataplane wedge → every D retry guaranteed to fail;
chain7 repeated the pattern (D-1/D-2 rc=1 twice each, 19:46–20:25) (`chain6.log`,
`chain7.log`).

**14:44→19:42 — INC-021 (yield-incident, major).** chain6's 18000 s yield from ~14:44 could
not cover ~2h15 of remaining D/E/F/G; proposer.sh exit-9 would have halted the whole run at
~19:42 (`yield/phase3-attempt1-20261013-120241-4145257.json`, `chain6.summary`).

**19:17–19:22 — INC-022 (keeper-intervention, major).** Keeper aborted doomed chain6, healed
both leaves in-guest in ~3 min (`systemctl reset-failed` + start swss/syncd/bgp — NOT
`docker restart swss`, start-limit-hit), shipped the `vrf_wedge_cure` into
`scripts/spike/vrf-apply.sh` (`chain6.done`, `chain6.summary`).

**19:33–19:37 — recovery.** chain7 (chain6 minus completed phases) launched; **first clean
vpn receipt at 19:37:15** (`chain7.log` lines 8–10) after the cure.

**19:46–20:37 — INC-023 (orchagent-wedge #6, critical).** Steering preflights died through
the wedge window; keeper refined the cure at 20:34: `systemctl start` is a no-op on
active-but-wedged units — RESTART swss (then syncd/bgp separately); SKIP the GCU dance when
rows are present-but-unprogrammed (measured re-wedge trigger). D-3-r2 green 20:38:50;
lab re-healed 20:35–20:45 (`PROGRESS.md` keeper entry 20:34, `chain7.log`).

**19:46–20:25 — INC-024 (script-bug, major).** `steering-path.sh:12` /
`steering-failover.sh:15`: `vpn-setup.sh >/dev/null 2>&1 || true` hides VPN-SETUP-STUCK, so
wedge failures are stored as misleading PREFLIGHT-FAILED markers.

**Standing — INC-025 (provenance-gap, major).** `git status --porcelain scripts/spike/` =
`?? scripts/spike/`; untracked during the entire live run.

**Standing at snapshot — INC-026 (other, major).** Stale receipts: `spike-rerun-baseline.out`
(11:32) predates the 15:24 baseline re-records; `spike-rerun-evpn3.out` (20:57) predates the
20:58–21:02 R3 re-records — no freshness binding exists.

**Standing — INC-027 (script-bug, minor).** `chain6.pid` initially caught the exiting setsid
wrapper (1226865 vs real 1226866); no `chain7.pid` exists at snapshot while chain7 runs
(pid 3538140 per the yield file).

**02:54 — INC-028 (script-bug, minor).** First receipts.sh launch died on mode-600
("Permission denied"), wrote stale `receipts3.rc=127`, manually deleted (`PROGRESS.md` pass 16).

**Control — INC-029 (honest-negative, info).** evpn3/evpn2 "not-achievable" verdicts are
correct measured results (pass 8 / 8b), recorded in `srv6-supported.yaml` — never to be
"fixed" by normalization.

## Responsibility tally
environment: INC-001, 002, 010, 018, 019, 023, 029 · script: INC-003, 004, 011, 013, 016,
017, 024, 027, 028 · design: INC-007, 014, 015, 020, 026 · agent: INC-006, 022, 025 ·
both: INC-005, 008, 021 · (INC-009, 012 are design/environment per record; INC-012
environment, INC-009 design).
