# Phase 6 — Migration translation (US1): Evidence

This evidence demonstrates that every Phase 6 acceptance criterion (T052–T061) is implemented, validated, and grounded in repository files. For each task we cite file paths and provide line-numbered proof slices under .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/ that show the exact symbols and behaviors the critic verifies.

- T052 Define a strict normalized input schema for service ID, type, tenant, endpoints, address families, RD/RTs, and allow-listed policies; explicitly forbid raw CLI
  - Schema: pkg/migration/input.go defines the normalized schema and policy/unsupported fields.
    - File: pkg/migration/input.go
    - Proofs:
      - Version constants and identity: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/pkg.migration.input.go.constants.proof.txt (contains TranslatorName, TranslatorVersion, MappingVersion)
      - Types including ServiceInput, AddressFamilies, RdRt, Endpoint, IRBGateway, Policies (allow-listed vpwsLimitedEquivalence), UnsupportedClaims (includes RawCLI): .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/pkg.migration.input.go.types.proof.txt
  - Strict parsing forbids unknown fields and raw CLI leakage: pkg/migration/parse.go uses DisallowUnknownFields and returns errors that are rendered as structured JSON.
    - File: pkg/migration/parse.go
    - Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/pkg.migration.parse.go.strict.proof.txt (contains ParseStrictBatch and strictUnmarshal with dec.DisallowUnknownFields)
  - Tests: unknown fields are rejected before translation and reported structurally.
    - File: tests/unit/migration_parse_strict_test.go
    - Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/tests.unit.migration_parse_strict_test.go.proof.txt (expects error for unknown field)
    - File: tests/unit/migration_cli_test.go
    - Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/tests.unit.migration_cli_test.go.structured_unknown.proof.txt (validates structured JSON with "error":"validation" and unknown-field cause)

- T053 [P] [US1] Implement VPLS/multipoint-L2VPN to bridge/L2VNI translation
  - Implementation: VPLS (and VPWS) map to a bridge domain with L2VNI and EVPN RTs; attachments rendered with VLANs.
    - File: pkg/migration/translate.go
    - Proofs:
      - VPLS/VPWS case mapping: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/pkg.migration.translate.go.vpls_vpws.proof.txt (shows case ServiceVPLS/ServiceVPWS building BridgeDomain { L2VNI, EVPN.routeTargets })
      - Stable annotations block exists (translator name/version/mapping/input-hash/tenant/service-type) used for provenance: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/pkg.migration.translate.go.annotations_block.proof.txt
  - Golden test fixture and comparison prove deterministic spec output:
    - Input: tests/unit/testdata/migration/supported_vpls.json — Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/testdata.migration.supported_vpls.spec.golden.yaml.proof.txt (expected spec)
    - Test: tests/unit/migration_golden_test.go — Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/tests.unit.migration_golden_test.go.vpls_l3vpn.proof.txt (TestGolden_VPLS uses ParseStrictBatch + RenderBatch and compares only spec subtree)

- T054 [P] [US1] Implement L3VPN to VRF/L3VNI/RD/RT/Type-5 translation
  - Implementation: L3VPN maps to a router (VRF) with RD, import/export RTs, L3VNI, and prefixes (driving EVPN Type-5).
    - File: pkg/migration/translate.go
    - Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/pkg.migration.translate.go.l3vpn.proof.txt (Router { Name, RD, RouteTargets { import/export }, L3VNI, Prefixes })
  - Golden fixture and test:
    - Input: tests/unit/testdata/migration/supported_l3vpn.json — Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/testdata.migration.supported_l3vpn.spec.golden.yaml.proof.txt
    - Test: tests/unit/migration_golden_test.go — Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/tests.unit.migration_golden_test.go.vpls_l3vpn.proof.txt (TestGolden_L3VPN)

- T055 [P] [US1] Implement VPWS/E-Line to two-attachment L2VNI with explicit limited-equivalence opt-in
  - Validation requires exactly two endpoints and an explicit policy opt-in; mapping adds a stable annotation documenting limited equivalence.
    - File: pkg/migration/input.go (validation rules)
      - Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/pkg.migration.input.go.ValidateAllOrNothing.proof.txt (case ServiceVPWS: exactly 2 endpoints + policies.vpwsLimitedEquivalence requirement)
    - File: pkg/migration/translate.go (annotation emission)
      - Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/pkg.migration.translate.go.vpls_vpws.proof.txt (annotation key set when ServiceVPWS)
      - Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/pkg.migration.translate.go.annotations_order.proof.txt (stable annotation ordering includes ainetops.io/limited-equivalence)
  - Golden/test proof:
    - Input: tests/unit/testdata/migration/supported_vpws_optin.json; Expected spec: tests/unit/testdata/migration/supported_vpws.spec.golden.yaml
      - Proofs: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/testdata.migration.supported_vpws.spec.golden.yaml.proof.txt and .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/tests.unit.migration_golden_test.go.vpws_irb.proof.txt (TestGolden_VPWS_OptIn)
    - Additional assertion that limited-equivalence annotation is present: tests/unit/migration_translator_test.go — covered in TestVPWSLimitedEquivalenceRequired

- T056 [P] [US1] Implement integrated L2/L3 to symmetric-IRB translation
  - Implementation: IRB maps to a bridge domain with IRB { vrf, gatewayIPv4, gatewayIPv6 } plus a router with RD/RT/L3VNI; attachments are L2.
    - File: pkg/migration/translate.go
    - Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/pkg.migration.translate.go.irb.proof.txt
  - Golden/test proof:
    - Input: tests/unit/testdata/migration/supported_irb.json; Expected spec: tests/unit/testdata/migration/supported_irb.spec.golden.yaml
      - Proofs: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/testdata.migration.supported_irb.spec.golden.yaml.proof.txt and .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/tests.unit.migration_golden_test.go.vpws_irb.proof.txt (TestIRB_Golden)

- T057 [US1] Implement all-or-nothing validation and structured unsupported-feature results (FR-011) for TE, pseudowire OAM/control-word, multicast VPN, complex QoS/OAM, service chain, unknown fields, collisions, and absent endpoints (FR-011)
  - All-or-nothing batch composition and error aggregation (no partial outputs):
    - File: pkg/migration/batch.go
    - Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/pkg.migration.batch.go.dup_and_marshal.proof.txt (RenderBatch detects duplicates, aggregates causes across inputs, returns ValidationError with Causes; also shows MarshalError for deterministic structured JSON)
  - Collision handling: ValidateAllOrNothing uses dupServiceID to emit a structured cause.
    - File: pkg/migration/input.go
    - Proofs:
      - Collision cause with exact symbol: "collision: duplicate serviceId" — .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/pkg.migration.input.go.collision.proof.txt
      - Full ValidateAllOrNothing rules covering required fields, unsupported claims, endpoint counts, and type-specific checks — .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/pkg.migration.input.go.ValidateAllOrNothing.proof.txt
  - Unsupported-feature causes (TE, pseudowire OAM, control-word, multicast VPN, complex QoS, service chain, rawCLI) are explicit:
    - File: pkg/migration/input.go
    - Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/pkg.migration.input.go.ValidateAllOrNothing.proof.txt (contains causes like "unsupported: tePolicy", "unsupported: pseudowireOAM", "unsupported: controlWord", "unsupported: multicastVPN", "unsupported: complexQoS", "unsupported: serviceChain", "unsupported: rawCLI")
  - Unknown fields rejected before translation via strict JSON parsing:
    - File: pkg/migration/parse.go — Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/pkg.migration.parse.go.strict.proof.txt
  - Tests proving duplicate collision is rejected with aggregated causes and zero outputs:
    - File: tests/unit/migration_batch_test.go (TestBatchAllOrNothing)
    - Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/tests.unit.migration_batch_test.go.collision.proof.txt (asserts len(outs)==0; error contains "duplicate serviceId")
  - Tests proving unsupported TE and unknown fields are rejected with zero outputs and structured causes:
    - Files: tests/unit/migration_golden_test.go (TestReject_UnsupportedTE), tests/unit/migration_cli_te_test.go, tests/unit/migration_cli_test.go
    - Proofs: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/tests.unit.migration_golden_test.go.unsupported_te.proof.txt; .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/tests.unit.migration_cli_te_test.go.reject_no_output.proof.txt; .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/tests.unit.migration_cli_test.go.structured_unknown.proof.txt
  - Tests proving absent endpoints are rejected and produce no output:
    - File: tests/unit/migration_missing_endpoints_test.go
    - Proofs: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/tests.unit.migration_missing_endpoints_test.go.vpls.proof.txt and ...l3vpn.proof.txt

- T058 Add deterministic CLI/library output with stable provenance annotations on generated Kubenet Networks
  - Deterministic library output: manual YAML builder with stable ordering for metadata, annotations (explicit ordered key list), spec subtrees, and item iteration preserves input order.
    - File: pkg/migration/translate.go
    - Proofs:
      - Translate function header: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/pkg.migration.translate.go.Translate.header.proof.txt
      - Stable annotations ordering (explicit keys array including ainetops.io/translator, ainetops.io/translator-version, ainetops.io/mapping-version, ainetops.io/migration-input-hash, ainetops.io/tenant, ainetops.io/service-type, ainetops.io/limited-equivalence): .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/pkg.migration.translate.go.annotations_order.proof.txt
  - Stable provenance annotations present in generated Network YAML:
    - File: tests/unit/migration_annotations_test.go — Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/tests.unit.migration_annotations_test.go.proof.txt (verifies all provenance annotations exist in output)
  - Deterministic hashing of normalized inputs included via ainetops.io/migration-input-hash:
    - File: pkg/migration/input.go (CanonicalHash) — covered by constants/types proof and used in Translate metadata; determinism tested in tests/unit/migration_translator_test.go (TestDeterministicHash)

- T058a Package the migration translator as a deterministic library plus CLI binary (cmd/migration-translator/) with reproducible output; per plan.md section 7 no in-cluster workload is created at this stage
  - CLI packaging under cmd/migration-translator/ and deterministic batch behavior:
    - File: cmd/migration-translator/main.go
    - Proofs:
      - Parse/strict and all-or-nothing path: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/cmd.migration-translator.main.go.parse.proof.txt (uses migration.ParseStrictBatch)
      - Batch duplicate detection, structured error emission, and YAML separation: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/cmd.migration-translator.main.go.processBatch.proof.txt
  - Binary presence (built in this workspace for reproducibility evidence):
    - Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/cmd.migration-translator.binary.ls.txt
  - No in-cluster workload creation: CLI reads JSON and prints YAML; no Kubernetes clients are used (visible in the cited main.go proofs). Tests exercise CLI with go run and assert no YAML output on validation failure.

- T059 Add table/golden tests for every supported, limited, unsupported, collision, and malformed fixture; prove rejected fixtures cause no downstream resources
  - Supported: VPLS, L3VPN, VPWS (opt-in), IRB golden tests and fixtures.
    - Files: tests/unit/migration_golden_test.go with fixtures under tests/unit/testdata/migration/
    - Proofs: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/tests.unit.migration_golden_test.go.vpls_l3vpn.proof.txt; ...vpws_irb.proof.txt; plus spec goldens at .wiggum/.../testdata.migration.supported_*.spec.golden.yaml.proof.txt
  - Limited equivalence (VPWS) requires explicit opt-in and verifies annotation (see T055 evidence above and TestVPWSLimitedEquivalenceRequired in tests/unit/migration_translator_test.go).
  - Unsupported fixture: tests/unit/testdata/migration/unsupported_te.json with tests rejecting it before output.
    - Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/testdata.migration.unsupported_te.json.proof.txt and .wiggum/.../tests.unit.migration_golden_test.go.unsupported_te.proof.txt
  - Malformed fixture (unknown field): tests/unit/testdata/migration/malformed_unknown_field.json and associated parse test.
    - Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/testdata.migration.malformed_unknown_field.json.proof.txt and .wiggum/.../tests.unit.migration_parse_strict_test.go.proof.txt
  - Collision case (duplicate serviceId in batch): tests/unit/migration_batch_test.go constructs a duplicate-ID batch and asserts a structured cause and zero outputs.
    - Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/tests.unit.migration_batch_test.go.collision.proof.txt
  - Rejected fixtures cause no downstream resources: CLI tests assert no YAML (“spec:”) is printed on validation error.
    - Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/tests.unit.migration_cli_te_test.go.reject_no_output.proof.txt

- T060 Decide from workflow evidence whether annotations/Git review meet audit needs; only if not, implement MigrationPlan.ainetops.io/v1alpha1
  - Decision: Do NOT enable or implement the optional MigrationPlan CRD at Phase 6; deterministic annotations and Git review suffice.
    - File: docs/migration/DECISION-T060.md
    - Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/docs.migration.DECISION-T060.md.proof.txt

- T061 If T060 enables the CRD, add structural/CEL validation, status subresource, RBAC, controller, conversion strategy, examples, and server-side dry-run/envtest coverage
  - T060 did not enable a CRD; therefore T061 is not applicable. To demonstrate no duplicate service/fabric CRD exists:
    - Proof of no MigrationPlan CRD/types/manifests present; only SRv6Service types under api/v1alpha1 and no CRD bases for MigrationPlan under config/crd.
      - Directory listings: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/api.v1alpha1.dirlisting.proof.txt and .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/config.crd.dirlisting.proof.txt
      - Search record: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/no-migrationplan-crd.proof.txt (only a decision doc mentions MigrationPlan; no API/CRD/controller code present)

Checkpoint: Supported intent maps predictably; limited equivalence requires explicit opt-in; unsupported intent (TE, raw CLI/unknown fields, pseudowire OAM/control-word, multicast VPN, complex QoS, service chain), collisions, and absent endpoints are rejected before mutation. No duplicate service/fabric CRD exists.
