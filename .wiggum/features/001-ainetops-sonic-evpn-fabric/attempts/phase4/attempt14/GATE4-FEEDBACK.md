# Phase 4 — critic feedback (REJECTED)

The following must be addressed before re-writing GATE4-EVIDENCE.md:

The following acceptance criteria are not met or are insufficiently evidenced:

- T026a Scaffold the SRv6 service controller binary and reconciler
  - Gap: “same pinned dependency set as T026” is only asserted; there is no grounded evidence that dependency versions are pinned for this binary or that they match T026.
  - Actionable: Provide the pinned Go module dependencies and show they are identical to the provider manager’s set.
  - NEEDS-GROUNDING: go.mod
  - NEEDS-GROUNDING: go.sum

- T027a Author the required SRv6Service.ainetops.io/v1alpha1 CRD and scaffolding
  - Gap: The envtest negative case asserts duplicate attachments should fail, but the checked-in CRD manifest lacks a corresponding CEL rule enforcing uniqueness of attachments (e.g., comparing the two attachments). The Go type includes an XValidation “attachments must be unique,” but the CRD YAML’s x-kubernetes-validations does not include this rule. As written, the server-side dry-run negative test would not be enforced by the installed CRD.
  - Actionable: Add the missing CEL rule to config/crd/bases/ainetops.io_srv6services.yaml (e.g., ensure attachments 0 and 1 node/interface are distinct) so the envtest negative case is actually validated at the API server, or adjust the test to exercise existing CRD validations.

- T029a Produce a per-path OpenConfig-vs-SONiC-native register for all rendered YANG paths; CI-check the register to prevent regressions
  - Gap: While pkg/register/oc_vs_sonic.yaml covers the rendered paths and justifications, there is no grounded evidence of a CI guard. The evidence claims a Makefile verify-register target, but no Makefile content is provided and there is no demonstration that ValidateSpecAgainstRegister is invoked in CI or tests.
  - Actionable: Add and show a verify-register Makefile target (and/or test) that fails when rendered paths are missing in the register, and demonstrate it runs in CI.
  - NEEDS-GROUNDING: Makefile

- T041 Instrument reconciles with bounded Prometheus metrics and OTel traces, then build, load, and deploy the provider image inside Kind using T023’s manifests; verify Pods, Services, probes, RBAC, and absence of secret or high-cardinality metric labels
  - Gaps:
    - Metrics: The controller imports Prometheus and defines a Counter field, but no grounded evidence shows metrics are instantiated (e.g., promauto.NewCounter) with bounded label cardinality.
    - Deployment verification: A Deployment/Service manifest snippet is provided, but there is no independent evidence that the image was built, loaded into Kind, deployed, and observed running (Pods Ready, probes active, RBAC effective). The witness requires independent observation.
  - Actionable: Provide code slices showing creation of Prometheus metrics with bounded labels, and add grounded evidence of a successful in-Kind deployment (e.g., kubectl get pods/services outputs, logs, or an integration test that validates Pods Ready and probes/Service endpoints).
  - NEEDS-GROUNDING: controllers/sonicprovider/controller.go (metric instantiation lines)
  - NEEDS-GROUNDING: scripts/provision.sh (or CI logs) showing docker build, kind load, and kubectl apply
  - NEEDS-GROUNDING: tests/integration or captured kubectl outputs verifying Pods/Services/Probes/RBAC at runtime

VERDICT 5f35a683735cb8af: REJECTED

