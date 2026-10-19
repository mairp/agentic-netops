# Provenance — incident snapshot, feature 004 (SRv6 service requests)

Snapshot taken: **2026-10-13 21:05:50 +04:00** (host `root@agentic-netops`)
Git HEAD at snapshot: `e56e0b40d8597a30911f15c889429f45b1282830`
("specstride: phase 2 approved — Foundational (Blocking Prerequisites)")

## What was copied

| Snapshot dir | Source | Notes |
| --- | --- | --- |
| `raw/tmp-g3-20261013T210550/` | `/tmp/g3` (live, volatile) | chain2–chain7 scripts/logs/summaries/done-markers, per-step `.log`+`.rc`, canary/provision logs, verdicts, `evidence-final.md` (GATE3 draft), gate-*.log. **Only durable copy of this evidence.** |
| `raw/wiggum-004-20261013T210550/` | `.wiggum/features/004-srv6-service-requests/` | PROGRESS.md (pass journal), `gates/proofs/` (recorded `.cmd`/`.out` pairs + replay receipts), pass-checkpoints, yield contracts, failure-ledger, verdicts, attempts, runs |
| `raw/mol-004-20261013T210550/` | `.mixture-of-loops/004-srv6-service-requests/` | launch contract (900 KB), INCIDENT-20261012-launcher-sigint.md, relaunch logs, watcher/milestone logs, verification-commands.json, runs/ (incl. stopped-exit130 run dir) |

## Live context at snapshot time

- Pipeline: MOL `runtime.py` pid 4145226 → `orchestrator.sh` pid 4145257 →
  `proposer.sh` pid 4145722 (yield-waiting since 19:34 on `/tmp/g3/chain7.done`).
- **chain7 running** (launched ~19:33 after keeper abort of chain6 at 19:17):
  Phase C vpn receipt CLEAN (19:37); Phase D steering recorded with D-1/D-2
  PREFLIGHT-FAILED (lab wedged 19:37–20:37, healed by the new `vrf-apply.sh`
  wedge cure — D-3-r2/D-4/D-5 passed 20:38–20:40); steering receipt differ on
  exactly those two members (20:44); Phase E evpn3 fallback re-record in flight
  (R3-1..R3-6 green through 21:02).
- Keeper: `claude --dangerously-skip-permissions --settings
  /root/.claude/settings-mixture-of-loops-only.json` pid 3195923 (since Oct 12).
- `scripts/spike/` **untracked in git** at snapshot time (`?? scripts/spike/`)
  — provenance gap incident (seed S14).

## Hash manifest (sha256, key artifacts)

```
/tmp/manifest.txt captured at snapshot time; regenerate with:
  cd evals/incidents/004-srv6-service-requests/raw
  sha256sum tmp-g3-*/chain*.sh tmp-g3-*/chain*.{summary,done,log} \
            wiggum-004-*/PROGRESS.md wiggum-004-*/failure-ledger.jsonl \
            mol-004-*/launch-contract.json
```

## Re-intake (rerunning this snapshot later)

1. `TS=$(date +%Y%m%dT%H%M%S)`
2. `cp -a /tmp/g3 raw/tmp-g3-$TS && cp -a ../../../.wiggum/features/004-srv6-service-requests raw/wiggum-004-$TS && cp -a ../../../.mixture-of-loops/004-srv6-service-requests raw/mol-004-$TS`
3. Diff against the previous snapshot to extract new incidents; update the live-context section.
(Use the absolute sources — `/root/agentic-netops/.wiggum/...` — not the relative paths above.)
