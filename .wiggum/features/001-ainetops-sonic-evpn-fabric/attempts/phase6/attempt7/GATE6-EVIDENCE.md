# Phase 6 — Migration translation (US1): Evidence

This evidence demonstrates that every acceptance criterion (T052–T061) is implemented, with concrete file paths and anchored, line-numbered proof slices under .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/.

New and changed artifacts in this phase (not exhaustive, highlights for this gate):
- Library: pkg/migration/{input.go,parse.go,batch.go,translate.go,yaml.go}
- CLI: cmd/migration-translator/main.go
- Tests (golden/table/CLI):
  - tests/unit/migration_golden_test.go
  - tests/unit/migration_missing_endpoints_test.go
  - tests/unit/migration_batch_test.go
  - tests/unit/migration_annotations_test.go
  - tests/unit/migration_cli_test.go
  - tests/unit/migration_cli_te_test.go
  - tests/unit/migration_collision_fixture_test.go (added to satisfy critic)
  - tests/unit/migration_cli_collision_test.go (added to satisfy critic)
- Test fixtures (golden and negative):
  - tests/unit/testdata/migration/supported_vpls.json
  - tests/unit/testdata/migration/supported_l3vpn.json
  - tests/unit/testdata/migration/supported_vpws_optin.json
  - tests/unit/testdata/migration/supported_irb.json
  - tests/unit/testdata/migration/unsupported_te.json
  - tests/unit/testdata/migration/malformed_unknown_field.json
  - tests/unit/testdata/migration/collision_duplicate.json (added to satisfy critic)
  - Golden outputs: tests/unit/testdata/migration/*.{spec.golden.yaml}
- Decision record: docs/migration/DECISION-T060.md

Acceptance criteria evidence

- T052 Define a strict normalized input schema for service ID, type, tenant, endpoints, address families, RD/RTs, and allow-listed policies; explicitly forbid raw CLI
  - Implemented in pkg/migration/input.go with strict typed schema, explicit Policies, and UnsupportedClaims (including RawCLI) enforced by validation; strict JSON decoding via ParseStrictBatch DisallowUnknownFields in pkg/migration/parse.go forbids unknown properties.
  - Files:
    - pkg/migration/input.go
    - pkg/migration/parse.go
  - Proofs:
    - .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/T052-input-schema.proof.txt
    - .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/T052-parse-strict.proof.txt

- T053 [P] [US1] Implement VPLS/multipoint-L2VPN to bridge/L2VNI translation
  - Implemented in pkg/migration/translate.go: VPLS maps to a single BridgeDomain with L2VNI and EVPN route-targets; attachments render VLANs per endpoint.
  - Files:
    - pkg/migration/translate.go
    - Golden: tests/unit/testdata/migration/supported_vpls.json and supported_vpls.spec.golden.yaml
  - Proof:
    - .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/T053-vpls-translation.proof.txt

- T054 [P] [US1] Implement L3VPN to VRF/L3VNI/RD/RT/Type-5 translation
  - Implemented in pkg/migration/translate.go: Router (VRF) with RD, import/export routeTargets, L3VNI, and Prefixes (Type-5 semantics); attachments bind nodes to the VRF.
  - Files:
    - pkg/migration/translate.go
    - Golden: tests/unit/testdata/migration/supported_l3vpn.json and supported_l3vpn.spec.golden.yaml
  - Proof:
    - .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/T054-l3vpn-translation.proof.txt

- T055 [P] [US1] Implement VPWS/E-Line to two-attachment L2VNI with explicit limited-equivalence opt-in
  - Validation in pkg/migration/input.go requires exactly two endpoints and Policies.VPWSLimitedEquivalence=true; translation annotates limited equivalence ainetops.io/limited-equivalence: vpws-to-l2vni; golden fixture exercises opt-in.
  - Files:
    - pkg/migration/input.go
    - pkg/migration/translate.go
    - Golden: tests/unit/testdata/migration/supported_vpws_optin.json and supported_vpws.spec.golden.yaml
  - Proof:
    - .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/T055-vpws-equivalence.proof.txt

- T056 [P] [US1] Implement integrated L2/L3 to symmetric-IRB translation
  - Implemented in pkg/migration/translate.go: IRB struct and IRB case that renders both a BridgeDomain (with IRB gateway) and a Router (VRF) with RD/RT/L3VNI; golden IRB fixture and output.
  - Files:
    - pkg/migration/translate.go
    - Golden: tests/unit/testdata/migration/supported_irb.json and supported_irb.spec.golden.yaml
  - Proof:
    - .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/T056-irb-translation.proof.txt

- T057 [US1] Implement all-or-nothing validation and structured unsupported-feature results for TE, pseudowire OAM/control-word, multicast VPN, complex QoS/OAM, service chain, unknown fields, collisions, and absent endpoints (FR-011)
  - All-or-nothing RenderBatch returns a ValidationError with aggregated causes and zero outputs; MarshalError emits deterministic structured JSON. Validation covers TE, pseudowire OAM, controlWord, multicastVPN, complexQoS, serviceChain, rawCLI; missing endpoints per type; batch duplicate serviceId collision detection. CLI prints structured JSON to stderr and no YAML on failure.
  - Files:
    - pkg/migration/batch.go
    - pkg/migration/input.go
    - cmd/migration-translator/main.go
    - Tests: tests/unit/migration_golden_test.go (unsupported TE, unknown field), tests/unit/migration_missing_endpoints_test.go (absent endpoints), tests/unit/migration_batch_test.go (programmatic duplicate), tests/unit/migration_cli_te_test.go (CLI no YAML on TE)
  - Proof:
    - .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/T057-validation.proof.txt

- T058 Add deterministic CLI/library output with stable provenance annotations on generated Kubenet Networks
  - Translate() produces deterministic YAML with stable key order and embedded provenance annotations: ainetops.io/translator, ainetops.io/translator-version, ainetops.io/mapping-version, ainetops.io/migration-input-hash, ainetops.io/tenant, ainetops.io/service-type, and optional ainetops.io/limited-equivalence. CLI deterministically reads JSON and emits YAML or structured errors.
  - Files:
    - pkg/migration/translate.go
    - cmd/migration-translator/main.go
    - tests/unit/migration_annotations_test.go
  - Proof:
    - .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/T058-deterministic-cli.proof.txt

- T058a Package the migration translator as a deterministic library plus CLI binary (cmd/migration-translator/) with reproducible output
  - CLI entrypoint present, uses the library; no in-cluster workload in this phase per plan.md; binary path: cmd/migration-translator/main.go.
  - Files:
    - cmd/migration-translator/main.go
  - Proof:
    - .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/T058a-cli-binary.proof.txt

- T059 Add table/golden tests for every supported, limited, unsupported, collision, and malformed fixture; prove rejected fixtures cause no downstream resources
  - Golden tests cover supported VPLS, L3VPN, VPWS (limited-equivalence opt-in), IRB; unsupported TE and malformed unknown-field fixtures are rejected pre-render; collision batch fixture added as requested by critic and verified via library and CLI tests; all rejected cases assert len(outputs)==0 and CLI emits structured JSON with no YAML (“spec:”) on stdout.
  - Files:
    - tests/unit/migration_golden_test.go
    - tests/unit/migration_missing_endpoints_test.go
    - tests/unit/migration_batch_test.go
    - tests/unit/migration_collision_fixture_test.go (NEW)
    - tests/unit/migration_cli_collision_test.go (NEW)
    - tests/unit/testdata/migration/collision_duplicate.json (NEW)
  - Proof:
    - .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/T059-tests-and-fixtures.proof.txt

- T060 Decide from workflow evidence whether annotations/Git review meet audit needs; only if not, implement MigrationPlan.ainetops.io/v1alpha1 per contracts/crd-api.md
  - Decision captured: do not enable or implement MigrationPlan CRD in Phase 6; deterministic annotations + Git review meet audit needs (per plan.md section 7). No in-cluster MigrationPlan added.
  - File:
    - docs/migration/DECISION-T060.md
  - Proof:
    - .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/T060-decision.proof.txt

- T061 If T060 enables the CRD, add structural/CEL validation, status subresource, RBAC, controller, conversion strategy, examples, and server-side dry-run/envtest coverage
  - Not applicable because T060 explicitly did not enable the CRD; no duplicate service/fabric CRD exists.
  - Proof:
    - .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/T061-na.proof.txt

Checkpoint summary
- Supported intent maps predictably (golden tests for VPLS, L3VPN, IRB; VPWS with explicit limited-equivalence opt-in), stable provenance annotations present.
- Unsupported and malformed intent (TE policy, unknown field) is rejected before any mutation; batch collisions and absent endpoints are rejected all-or-nothing; CLI produces structured errors and no YAML on failure.
- No duplicate service/fabric CRD exists; optional MigrationPlan CRD not enabled per decision.
