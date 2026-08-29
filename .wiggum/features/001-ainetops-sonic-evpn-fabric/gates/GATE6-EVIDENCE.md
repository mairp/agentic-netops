# Phase 6 — Migration translation (US1)

This evidence demonstrates that every Phase 6 acceptance criterion (T052–T061) is implemented and verified. For each task, we cite exact file paths and line‑numbered proof slices staged under .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/ per the evidence contract. Golden tests and fixtures are present on disk and referenced explicitly.

## T052 Define a strict normalized input schema; explicitly forbid raw CLI

What we implemented:
- Strict normalized input schema in pkg/migration/input.go with required identity (serviceId, type, tenant), endpoints, address families, RD/RTs, explicit VNI fields, allow‑listed policies, and an UnsupportedClaims block that explicitly rejects raw CLI and other unsupported features.
- Strict JSON parsing with DisallowUnknownFields so unknown properties are rejected before any translation/allocation.

Proofs:
- ServiceInput, Policies, and UnsupportedClaims (includes RawCLI) in pkg/migration/input.go:
  - Proof slice: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/T052-input-schema.proof.txt (shows "ServiceInput", policy field "vpwsLimitedEquivalence", and UnsupportedClaims including "RawCLI").
- Strict parse rejecting unknown fields via json.Decoder.DisallowUnknownFields in pkg/migration/parse.go:
  - Proof slice: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/T052-parse-strict.proof.txt (names "ParseStrictBatch" and shows "DisallowUnknownFields").

## T053 [P][US1] VPLS/multipoint‑L2VPN → bridge/L2VNI translation

What we implemented:
- translate.go case ServiceVPLS renders a bridgeDomain with deterministic name, VLAN from endpoints, L2VNI, and EVPN RouteTargets (import/export) with attachments on leaves.
- Golden test validates expected spec YAML.

Proofs:
- VPLS translation in pkg/migration/translate.go (case ServiceVPLS; BridgeDomain, L2VNI, EVPN RTs, attachments):
  - Proof slice: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/T053-translate-vpls.translate.go.proof.txt
- Golden output present and anchored: tests/unit/testdata/migration/supported_vpls.spec.golden.yaml
  - Proof slice: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/T053-golden-vpls.spec.golden.proof.txt
- Golden test using this fixture and comparing only spec subtree: tests/unit/migration_golden_test.go
  - Proof slice: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/golden_vpls_test.txt

## T054 [P][US1] L3VPN → VRF/L3VNI/RD/RT/Type‑5 translation

What we implemented:
- translate.go case ServiceL3VPN renders a router (VRF) with deterministic name, RD, routeTargets (import/export), L3VNI, prefixes (for Type‑5 routing), and attachments on leaves.
- Golden test validates expected spec YAML.

Proofs:
- L3VPN translation in pkg/migration/translate.go (case ServiceL3VPN; RD/RT/L3VNI/prefixes):
  - Proof slice: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/T054-translate-l3vpn.translate.go.proof.txt
- Golden output present and anchored: tests/unit/testdata/migration/supported_l3vpn.spec.golden.yaml
  - Proof slice: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/T054-golden-l3vpn.spec.golden.proof.txt
- Golden test using this fixture: tests/unit/migration_golden_test.go
  - Proof slice: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/golden_l3vpn_test.txt

## T055 [P][US1] VPWS/E‑Line → two‑attachment L2VNI with explicit limited‑equivalence opt‑in

What we implemented:
- Validation enforces exactly two endpoints and requires Policies.vpwsLimitedEquivalence=true to proceed; otherwise the entire batch is rejected with a structured cause.
- translate.go sets deterministic bridgeDomain and adds a provenance annotation ainetops.io/limited-equivalence=vpws-to-l2vni to mark limited equivalence.
- Golden test validates expected spec YAML; tests validate the annotation is present only with explicit opt‑in.

Proofs:
- Validation and opt‑in requirement in pkg/migration/input.go (ValidateAllOrNothing for ServiceVPWS):
  - Proof slice: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/T055-vpws-validation-and-annotation.proof.txt (shows "exactly 2 endpoints" and policy cause text)
- Limited‑equivalence annotation in pkg/migration/translate.go:
  - Proof slice: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/vpws_annotation_translate.txt (shows key "ainetops.io/limited-equivalence")
- Golden output present and anchored: tests/unit/testdata/migration/supported_vpws.spec.golden.yaml
  - Proof slice: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/T055-golden-vpws.spec.golden.proof.txt
- Tests for policy opt‑in and annotation: tests/unit/migration_translator_test.go
  - Proof slice: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/vpws_annotation_test.txt
  - Opt‑in enforcement: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/vpws_validate_policy_optin.txt

## T056 [P][US1] Integrated L2/L3 → symmetric‑IRB translation

What we implemented:
- translate.go case ServiceIRB renders both a router (VRF with L3VNI/RD/RT) and a bridgeDomain (L2VNI, VLAN) with an irb block containing VRF and per‑BD IPv4/IPv6 gateways; attachments bind the bridge domain to leaf endpoints.
- Golden test validates expected spec YAML including both routers and bridgeDomains sections and the irb block.

Proofs:
- IRB translation in pkg/migration/translate.go (case ServiceIRB; IRB block and VRF/L3VNI):
  - Proof slice: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/T056-translate-irb.translate.go.proof.txt
- buildYAML emits irb block with gatewayIPv4/gatewayIPv6:
  - Proof slice: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/irb_buildYAML_block.txt
- Golden output present and anchored: tests/unit/testdata/migration/supported_irb.spec.golden.yaml
  - Proof slice: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/T056-golden-irb.spec.golden.proof.txt
- Golden test for IRB: tests/unit/migration_golden_test.go
  - Proof slice: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/irb_golden_spec.txt

## T057 [US1] All‑or‑nothing validation and structured unsupported‑feature results (FR‑011)

What we implemented:
- All‑or‑nothing batch validation: pkg/migration/batch.go detects duplicate serviceIds, calls ValidateAllOrNothing on each item, aggregates causes in stable order, and returns zero outputs on any failure.
- Strict parsing rejects unknown fields up front (DisallowUnknownFields).
- Unsupported features explicitly modeled and rejected: TE policy, pseudowire OAM, control‑word, multicast VPN, complex QoS/OAM, service chain, raw CLI.
- Absent endpoints and count mismatches are validated type‑specifically; errors are included in structured causes.
- CLI emits a deterministic JSON error shape {"error":"validation","causes":[...]} to stderr and no YAML on failure.

Proofs:
- Batch all‑or‑nothing behavior and zero outputs on error: pkg/migration/batch.go
  - Proof slices: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/renderbatch_all_or_nothing.txt and collision_rejected_test.txt
- Unsupported claim causes in ValidateAllOrNothing and policy checks: pkg/migration/input.go
  - Proof slice: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/T057-validation.proof.txt
- Unknown field rejection via parse.go DisallowUnknownFields:
  - Proof slice: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/parse_strict_disallow_unknowns.txt
- Tests proving rejection and no downstream outputs:
  - Unsupported TE fixture: tests/unit/testdata/migration/unsupported_te.json with tests/unit/migration_golden_test.go (TestReject_UnsupportedTE) and CLI test tests/unit/migration_cli_te_test.go
    - Proof slices: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/tests.unit.migration_golden_test.go.unsupported_te.proof.txt, tests.unit.migration_cli_te_test.go.reject_no_output.proof.txt
  - Malformed unknown field: tests/unit/testdata/migration/malformed_unknown_field.json and tests/unit/migration_golden_test.go (TestReject_MalformedUnknownField)
    - Proof slice: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/tests.unit.migration_golden_test.go.unknown_field.proof.txt
  - Missing endpoints tests (VPLS and L3VPN) assert zero outputs on failure: tests/unit/migration_missing_endpoints_test.go
    - Proof slices: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/tests.unit.migration_missing_endpoints_test.go.vpls.proof.txt and tests.unit.migration_missing_endpoints_test.go.l3vpn.proof.txt
  - Collision duplicate serviceId fixture: tests/unit/testdata/migration/collision_duplicate.json and test tests/unit/migration_collision_fixture_test.go
    - Proof slice: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/tests.unit.migration_collision_fixture_test.go.proof.txt
- CLI emits structured JSON and no YAML on error: cmd/migration-translator/main.go and tests/unit/migration_cli_test.go
  - Proof slices: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/cli_main_comment_and_flags.txt, cli_structured_unknown_test.txt, cli_no_yaml_on_error_test.txt

## T058 Deterministic CLI/library output with stable provenance annotations on generated Kubenet Networks

What we implemented:
- Deterministic library translation: pkg/migration/translate.go assembles a Kubenet Network struct and builds YAML with stable ordering. It adds stable provenance annotations: ainetops.io/translator, ainetops.io/translator-version, ainetops.io/mapping-version, ainetops.io/migration-input-hash, ainetops.io/tenant, ainetops.io/service-type, and limited-equivalence when applicable.
- CLI: cmd/migration-translator/main.go reads JSON from stdin or --file and prints YAML with deterministic separators; no cluster interaction occurs.

Proofs:
- Annotation keys and stable order in buildYAML: pkg/migration/translate.go
  - Proof slices: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/annotations_set_translate.txt and annotation_order_buildYAML.txt
- Annotations present in output: tests/unit/migration_annotations_test.go
  - Proof slice: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/annotations_test.txt
- Deterministic CLI behavior and flags: cmd/migration-translator/main.go
  - Proof slices: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/cli_main_comment_and_flags.txt and migration.cli.txt

## T058a Package the migration translator as a deterministic library plus CLI binary

What we implemented:
- Library: pkg/migration/* provides ParseStrictBatch, RenderBatch, Translate, and helpers.
- CLI binary at cmd/migration-translator/. Makefile target build-migration-cli produces a reproducible static build; no in‑cluster workload is created at this stage.

Proofs:
- Makefile target for CLI: Makefile
  - Proof slice: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/Makefile.full.txt (shows build-migration-cli target and go build command)
- CLI main implementation: cmd/migration-translator/main.go
  - Proof slices: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/cmd.migration-translator.main.go.full.txt and cmd.migration-translator.main.go.processBatch.proof.txt
- Built binary present during build step: proof of ls output
  - Proof slice: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/cmd.migration-translator.binary.ls.txt
- No in‑cluster workload added for Migration translator in this phase; decision recorded under T060 (below).

## T059 Add table/golden tests for supported, limited, unsupported, collision, and malformed fixtures; prove rejected fixtures cause no downstream resources

What we implemented:
- Golden tests and fixtures for supported mappings:
  - VPLS: tests/unit/migration_golden_test.go and tests/unit/testdata/migration/supported_vpls.json + supported_vpls.spec.golden.yaml
  - L3VPN: tests/unit/migration_golden_test.go and tests/unit/testdata/migration/supported_l3vpn.json + supported_l3vpn.spec.golden.yaml
  - VPWS (limited equivalence opt‑in): tests/unit/migration_golden_test.go and tests/unit/testdata/migration/supported_vpws_optin.json + supported_vpws.spec.golden.yaml
  - IRB: tests/unit/migration_golden_test.go and tests/unit/testdata/migration/supported_irb.json + supported_irb.spec.golden.yaml
- Negative and collision coverage proving zero outputs:
  - Unsupported TE: tests/unit/testdata/migration/unsupported_te.json with tests in migration_golden_test.go and CLI test migration_cli_te_test.go
  - Malformed/unknown field: tests/unit/testdata/migration/malformed_unknown_field.json
  - Missing endpoints (VPLS/L3): tests/unit/migration_missing_endpoints_test.go
  - Collision duplicate serviceId: tests/unit/testdata/migration/collision_duplicate.json with tests/unit/migration_collision_fixture_test.go

Proofs (golden fixtures exist and are used; negative tests assert zero outputs):
- Presence of all golden spec files:
  - tests/unit/testdata/migration/supported_vpls.spec.golden.yaml — proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/testdata.migration.supported_vpls.spec.golden.yaml.proof.txt
  - tests/unit/testdata/migration/supported_l3vpn.spec.golden.yaml — proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/testdata.migration.supported_l3vpn.spec.golden.yaml.proof.txt
  - tests/unit/testdata/migration/supported_vpws.spec.golden.yaml — proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/testdata.migration.supported_vpws.spec.golden.yaml.proof.txt
  - tests/unit/testdata/migration/supported_irb.spec.golden.yaml — proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/testdata.migration.supported_irb.spec.golden.yaml.proof.txt
- Golden test invocations and comparisons: tests/unit/migration_golden_test.go
  - Proof slices: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/tests.migration_golden.txt (includes calls to ParseStrictBatch, RenderBatch, and spec comparison)
- Negative fixture tests proving zero outputs:
  - Unsupported TE: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/tests.unit.migration_golden_test.go.unsupported_te.proof.txt and tests.unit.migration_cli_te_test.go.reject_no_output.proof.txt
  - Unknown field rejection: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/tests.unit.migration_golden_test.go.unknown_field.proof.txt
  - Missing endpoints (VPLS/L3): .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/tests.unit.migration_missing_endpoints_test.go.vpls.proof.txt and ...l3vpn.proof.txt
  - Collision duplicate serviceId: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/tests.unit.migration_collision_fixture_test.go.proof.txt

## T060 Decide from workflow evidence whether annotations/Git review meet audit needs; only if not, implement MigrationPlan.ainetops.io/v1alpha1

Decision: Do not enable the optional MigrationPlan CRD in Phase 6. Deterministic provenance annotations and Git review meet audit needs.

Proofs:
- Decision record: docs/migration/DECISION-T060.md
  - Proof slice: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/docs.migration.DECISION-T060.md.proof.txt (lists the exact annotation keys and decision rationale)
- No MigrationPlan CRD or controller present in repo (grep scan and absence proof):
  - Proof slice: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/no-migrationplan-crd.proof.txt

## T061 If T060 enables the CRD, add structural/CEL validation, status, RBAC, controller, conversion strategy, examples, and server‑side dry‑run/envtest coverage

Not applicable in Phase 6 because T060 did not enable the CRD.

Proof:
- NA proof and explicit statement: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/T061-no-crd-controller.proof.txt and T061-na.proof.txt

---

Checkpoint: Supported intent maps predictably (VPLS→bridge/L2VNI, L3VPN→VRF/L3VNI/RD/RT/Type‑5, IRB symmetric‑IRB). Limited equivalence (VPWS) requires explicit opt‑in and is annotated. Unsupported intent is rejected before mutation with structured causes. No duplicate service/fabric CRD exists and no optional MigrationPlan was introduced.
