# Phase 2 — critic feedback (REJECTED)

The following must be addressed before re-writing GATE2-EVIDENCE.md:

Unmet/unclear criteria

- T016 [US3] make lab-qualify must block downstream tests on any failed capability
  - Gap: scripts/lib/qualify.sh does not block downstream tests when earlier capability checks fail. It accumulates pass/fail and proceeds to run all subsequent EVPN/SRv6 and YANG path tests regardless of prior failures.
  - Evidence: scripts/lib/qualify.sh lines 19–40 show:
    - It runs Capabilities/Get/Set/Subscribe/sonic-srv6, setting failed=1 on any failure, but does not exit or short-circuit.
    - It then unconditionally runs EVPN-Type2/3/5 and all SRv6 tests (lines 33–37) and YANG-Paths (lines 39–40) irrespective of failed.
  - Required: Implement hard gating such that once any capability test fails, downstream suites do not execute (e.g., bail out immediately after the core capability block, and also short-circuit within later blocks on first failure), while still emitting a machine-readable report that reflects the truncated run.

VERDICT 319c24c99ffe9885: REJECTED



---
## Grounding transparency (machine-generated — read this)
These files you cited EXIST on disk, but the critic's grounding extractor could not include them in its snapshot, so the critic cannot 'see' their contents. This is a TOOLING limitation, NOT a missing file. Do NOT re-create, copy, or promote them — they are already present and correct. If a criterion depends on one, either cite it a different way (e.g. a slash path like `./kvm`) or state in your evidence that grounding cannot reach it:
- `/dev/kvm`
- `qualify.report.json`
- `qualify.report.json.proof.txt`
- `qualify.run.log.proof.txt`
- `versions.lock.yaml`
