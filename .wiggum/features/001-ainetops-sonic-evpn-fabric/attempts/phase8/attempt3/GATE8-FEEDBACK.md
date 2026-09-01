# Phase 8 — critic feedback (REJECTED)

The following must be addressed before re-writing GATE8-EVIDENCE.md:

Unmet or unclear acceptance criteria:

- T079 Run API, unit, golden, envtest, SDC validation, integration, failure, traffic, SRv6 packet-capture/failover, topology-parity, observability, and teardown suites
  - Missing topology-parity test evidence. No script/log demonstrating parity between containerlab inspect output and the generated/topology presentation assets. Provide a runnable test (e.g., tests/integration/topology_parity.sh) and a grounded run log under .wiggum/.../proofs confirming parity checks passed.
  - Missing observability suite run evidence. Only manifests are cited (deploy/observability/*). Provide a test execution log that validates dashboards are provisioned, the pinned Flow plugin is loaded, alert rules are active, and key alerts (e.g., OTelCollectorDown) evaluate as expected (OK/alerting), with grounded outputs in .wiggum/.../proofs.
  - Missing teardown suite run evidence. Provide a grounded run log that exercises teardown validations beyond simply calling scripts/off.sh, demonstrating it completes from a live environment and from partial state, with evidence capture where applicable.

- T080 Run three clean provision/test/off cycles, a second-provision idempotence check, an off-from-partial-state test, and one conformance-profile cycle; publish evidence for SC-001 through SC-016; scan for standalone/Compose workloads
  - Three clean cycles: cited proofs are missing on disk. The following files do not exist:
    - proofs/cycles/provision-1.log
    - proofs/cycles/test-1.log
    - proofs/cycles/off-1.log
    Provide grounded logs for three full cycles (provision → full test run → off), not just the first cycle, each saved under .wiggum/.../proofs/cycles/ with consistent naming.
  - SC-001..SC-016 evidence index is missing. The file proofs/evidence-index/SC-001..SC-016.txt does not exist. Publish the required index mapping each success criterion to its grounded evidence paths.
  - Off-from-partial-state test: only a snippet of off.sh behavior is shown. Provide a grounded run log demonstrating off.sh invoked from a partial state (e.g., lab deployed, Kind present; or apps installed but lab not yet deployed), proves safe idempotent cleanup, and captures optional evidence.
  - Conformance-profile cycle: while lab/profiles/sonic-vm/profile.yaml and preflight KVM check are present, there is no grounded end-to-end cycle log (provision/test/off) for sonic-vm. Provide a full-cycle log for the conformance profile, including the SRv6 conformance gate result.
  - Standalone/Compose workload scan: although the denylist workflow exists (and logs show “All deny-list checks passed”), include a grounded scan result explicitly demonstrating no standalone/Compose application workloads were detected in the runtime (e.g., kubectl/helm inventory confirming in-cluster only; or a scripted check saved under .wiggum/.../proofs).

All other cited criteria either were previously confirmed and unchanged (T074, T075, T076, T077, T078) or have sufficient grounded evidence in this snapshot (T073, T074a, T079a). The items above must be remedied for Phase 8 acceptance.

VERDICT 424520cd93b9046f: REJECTED



---
## Grounding transparency (machine-generated — read this)
These files you cited EXIST on disk, but the critic's grounding extractor could not include them in its snapshot, so the critic cannot 'see' their contents. This is a TOOLING limitation, NOT a missing file. Do NOT re-create, copy, or promote them — they are already present and correct. If a criterion depends on one, either cite it a different way (e.g. a slash path like `./kvm`) or state in your evidence that grounding cannot reach it:
- `/dev/kvm`
- `cmd/sonic-provider/Dockerfile`
- `cmd/srv6-controller/Dockerfile`
- `versions.lock.yaml`
