# Disagreement report — A vs B curation sets
A (agent-qwen38): 29 incidents, 19 cases
B (agent-glm53): 33 incidents, 17 cases
merged: 39 incidents, 19 cases
one-sided: 16 incidents, 2 cases

One-sided items are anomaly signals: review each — real miss by the
other curator, or an over-report. Adjust `source` by hand when merging.

- incident A only: [INC-004-018] orchagent-wedge — Wedge #4 (chain5): canary APPLY-STUCK on a canary-clean design; chain aborted in phase H
- incident A only: [INC-004-019] orchagent-wedge — Wedge #5 (chain6): green records then vpn replay 7/8 APPLY-STUCK; steering garbage 18:08–19:09
- incident A only: [INC-004-022] keeper-intervention — Keeper aborted doomed chain6, healed the lab in-guest in ~3 min, shipped the vrf-apply wedge cure
- incident A only: [INC-004-023] orchagent-wedge — Wedge #6 (chain7): D-1/D-2/D-3-attempt-1 PREFLIGHT-FAILED through the wedge window; cure refined
- incident A only: [INC-004-026] other — Stale receipts: member .out re-recorded AFTER its group's receipt (baseline, evpn3)
- incident A only: [INC-004-029] honest-negative — Honest negatives: evpn3 (routed EVPN over SRv6) and evpn2 (L2VNI) not deliverable on this image
- incident B only: [INC-004-016] script-bug — 'docker restart swss' is catastrophic; APPL_DB death first misread as slow convergence
- incident B only: [INC-004-017] script-bug — seed-restore had three silent no-op bugs hidden behind '|| true' and '2>/dev/null'
- incident B only: [INC-004-019] script-bug — Chain3 canary false-negative: launcher-netns exec, substring grep, probe before service state
- incident B only: [INC-004-024] preflight-refusal — Steering garbage loop: converge-only retries re-recorded the identical failure four times
- incident B only: [INC-004-025] script-bug — Steering bodies swallow VPN-SETUP-STUCK and mislabel it PREFLIGHT-FAILED
- incident B only: [INC-004-027] run-incident — Watchdog progress_stall kills wrote EMPTY checkpoints (twice measured)
- incident B only: [INC-004-029] design-gap — Stale pid/rc hygiene: dead pid files, wrapper-vs-real pid confusion, poison rc=127 left behind
- incident B only: [INC-004-030] design-gap — Receipts outlive their member records (no staleness mechanism)
- incident B only: [INC-004-031] design-gap — restore-check phantom: record-order entry with no stored proof
- incident B only: [INC-004-033] poisoned-record — Baseline whitespace churn: capture script edited after the receipt judged the group
- case A only: [EVAL-004-018] harness-regression — Yield budget feasibility at arm time
- case A only: [EVAL-004-019] harness-regression — Untracked run-critical script alarm
