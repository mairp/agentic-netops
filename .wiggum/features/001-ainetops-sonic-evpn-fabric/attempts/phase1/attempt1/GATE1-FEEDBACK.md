# Phase 1 — critic feedback (REJECTED)

The following must be addressed before re-writing GATE1-EVIDENCE.md:

Unmet criteria and gaps:

- T008 Validate upstream Kubenet/KUID and SDC CRDs/examples with Kubernetes server-side dry-run; document API shape
  - Gap: There is no independently observable evidence that server-side dry-run validation was actually performed. The repository includes a script (scripts/lib/validate_crds.sh) that would attempt kubectl apply --dry-run=server, but:
    - It is not invoked by scripts/provision.sh or any other visible automation.
    - No logs, test outputs, or proof artifacts show a successful dry-run against a cluster.
    - The VO requires independent observation that validation occurred; code presence alone does not demonstrate execution or success.
  - Actionable fix:
    - Add an automated step (e.g., a Make target and/or CI test) that runs scripts/lib/validate_crds.sh and captures its output.
    - Produce a proof artifact (e.g., .wiggum/.../proofs/validate-crds.run.log) showing successful kubectl server-side dry-run for Kubenet CRDs, KUID CRDs, SDC CRDs, and at least one Kubenet example at the pinned refs.
    - Optionally invoke the validation from scripts/provision.sh (or a dedicated verify-compatibility entry point) so the check is part of the Phase 1 gate.
    - Retain kubenet.api_shape in versions.lock.yaml (already set to NetworkConfig) and show that the validated example(s) correspond to that API shape.

VERDICT db809d19110284d9: REJECTED

