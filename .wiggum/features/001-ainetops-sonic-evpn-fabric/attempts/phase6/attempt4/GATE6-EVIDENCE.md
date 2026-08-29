# Phase 6 — Migration translation (US1) — Evidence

This evidence demonstrates that every Phase 6 acceptance criterion (T052–T061) is implemented and grounded in the cited repository files. For each task, we cite the exact file paths and provide line-numbered proof slices under gates/proofs/.

Note: Per plan.md section 7 and Decision T060, no in-cluster MigrationPlan CRD is created in this phase; the translator is a deterministic library plus CLI with stable provenance annotations.

## T052 Define a strict normalized input schema; forbid raw CLI

Implemented in pkg/migration/input.go and pkg/migration/parse.go.
- Schema types and explicit fields: pkg/migration/input.go lines around ServiceType, ServiceInput, UnsupportedClaims.
  - Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/migration.input.schema.part1.txt (ServiceType)
  - Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/migration.input.schema.part2.txt (ServiceInput, UnsupportedClaims with RawCLI)
- Strict parsing rejects unknown fields via DisallowUnknownFields: pkg/migration/parse.go.
  - Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/migration.parse.txt
- Unknown-field rejection test: tests/unit/migration_parse_strict_test.go.
  - Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/tests.migration_parse.txt

## T053 Implement VPLS/multipoint-L2VPN to bridge/L2VNI translation

- Translation maps VPLS to a bridgeDomain with l2vni, VLAN, and EVPN RTs; attachments rendered with VLANs: pkg/migration/translate.go.
  - Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/migration.translate.core.txt (ServiceVPLS branch)
- Golden fixture and expected spec:
  - Input: tests/unit/testdata/migration/supported_vpls.json
  - Expected spec: tests/unit/testdata/migration/supported_vpls.spec.golden.yaml
  - Test: tests/unit/migration_golden_test.go TestGolden_VPLS
  - Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/tests.migration_golden.txt

## T054 Implement L3VPN to VRF/L3VNI/RD/RT/Type-5 translation

- Translation maps L3VPN to routers[] with rd, routeTargets import/export, l3vni, prefixes; attachments with vrf: pkg/migration/translate.go.
  - Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/migration.translate.core.txt (ServiceL3VPN branch)
- Golden fixture and expected spec:
  - Input: tests/unit/testdata/migration/supported_l3vpn.json
  - Expected spec: tests/unit/testdata/migration/supported_l3vpn.spec.golden.yaml
  - Test: tests/unit/migration_golden_test.go TestGolden_L3VPN
  - Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/tests.migration_golden.txt

## T055 Implement VPWS/E-Line to two-attachment L2VNI with explicit limited-equivalence opt-in

- Translation maps VPWS to a single bridgeDomain/l2vni with limited-equivalence annotation when Policies.vpwsLimitedEquivalence is true: pkg/migration/translate.go and pkg/migration/input.go.
  - Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/migration.translate.core.txt (ServiceVPWS and annotations)
  - Policy opt-in field: pkg/migration/input.go Policies.VPWSLimitedEquivalence
    - Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/migration.input.schema.part2.txt
- Golden fixture and expected spec:
  - Input: tests/unit/testdata/migration/supported_vpws_optin.json
  - Expected spec: tests/unit/testdata/migration/supported_vpws.spec.golden.yaml
  - Test: tests/unit/migration_golden_test.go TestGolden_VPWS_OptIn
  - Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/tests.migration_golden.txt

## T056 Implement integrated L2/L3 to symmetric-IRB translation

- Translation maps IRB to a bridgeDomain with irb { vrf, gatewayIPv4/IPv6 } and a router with rd/rt/l3vni; attachments rendered with VLAN: pkg/migration/translate.go.
  - Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/migration.translate.core.txt (ServiceIRB branch)
- Golden fixture and expected spec:
  - Input: tests/unit/testdata/migration/supported_irb.json
  - Expected spec: tests/unit/testdata/migration/supported_irb.spec.golden.yaml
  - Test: tests/unit/migration_golden_test.go TestIRB_Golden
  - Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/tests.migration_golden.txt

## T057 Implement all-or-nothing validation and structured unsupported-feature results (FR-011)

- All-or-nothing validation on batch with duplicate-ID collision detection: pkg/migration/batch.go RenderBatch and pkg/migration/input.go ValidateAllOrNothing; unsupported claims include TE, pseudowire OAM, control-word, multicast VPN, complex QoS, service chain, and rawCLI.
  - Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/migration.batch.txt
  - Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/migration.input.validate.txt
- Absent endpoints are rejected across all service types:
  - Global check: endpoints: at least one endpoint is required (pkg/migration/input.go)
  - VPLS: requires >=2 endpoints and per-endpoint VLAN; L3VPN: requires >=1 endpoint and per-endpoint VRF; VPWS: exactly 2 endpoints and VLANs; IRB: at least one endpoint and VLANs.
  - Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/migration.input.validate.txt
- Structured unsupported-feature result proven by tests:
  - Unsupported TE fixture: tests/unit/testdata/migration/unsupported_te.json with tests/unit/migration_golden_test.go TestReject_UnsupportedTE
  - Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/tests.migration_golden.txt
- Missing-endpoints negative tests (no downstream outputs) for VPLS and L3VPN: tests/unit/migration_missing_endpoints_test.go
  - Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/tests.migration_missing_endpoints.txt
- CLI structured error and zero-output on failure: cmd/migration-translator/main.go and tests/unit/migration_cli_te_test.go
  - Proof (CLI): .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/migration.cli.txt
  - Proof (test): .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/tests.migration_cli_te.txt

## T058 Deterministic CLI/library output with stable provenance annotations

- Deterministic library and YAML builder: pkg/migration/translate.go buildYAML with stable key order, annotations.
  - Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/migration.translate.yaml.txt
- Stable provenance annotations on generated Networks: ainetops.io/translator, translator-version, mapping-version, migration-input-hash, tenant, service-type, and limited-equivalence when applicable.
  - Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/migration.translate.yaml.txt
- Annotation presence test: tests/unit/migration_annotations_test.go
  - Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/tests.migration_annotations.txt

## T058a Package as deterministic library + CLI binary (cmd/migration-translator/)

- CLI implementation: cmd/migration-translator/main.go reads stdin/--file, uses strict parse, validates all-or-nothing, emits concatenated YAML, and on error prints structured JSON to stderr and exits non-zero.
  - Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/migration.cli.txt
- CLI negative test (unsupported TE) ensures no YAML is produced: tests/unit/migration_cli_te_test.go
  - Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/tests.migration_cli_te.txt

## T059 Table/golden tests for supported, limited, unsupported, collision, and malformed; zero outputs on reject

- Golden tests use fixtures under tests/unit/testdata/migration/ and compare spec subtree against .spec.golden.yaml files: tests/unit/migration_golden_test.go
  - Fixtures: 
    - tests/unit/testdata/migration/supported_vpls.json
    - tests/unit/testdata/migration/supported_vpws_optin.json
    - tests/unit/testdata/migration/supported_l3vpn.json
    - tests/unit/testdata/migration/supported_irb.json
  - Golden specs:
    - tests/unit/testdata/migration/supported_vpls.spec.golden.yaml
    - tests/unit/testdata/migration/supported_vpws.spec.golden.yaml
    - tests/unit/testdata/migration/supported_l3vpn.spec.golden.yaml
    - tests/unit/testdata/migration/supported_irb.spec.golden.yaml
  - Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/tests.migration_golden.txt
- Unsupported and malformed fixtures:
  - Unsupported TE: tests/unit/testdata/migration/unsupported_te.json (rejected; zero outputs)
  - Malformed unknown field: tests/unit/testdata/migration/malformed_unknown_field.json (parse rejected)
  - Duplicate/collision and mixed unsupported proven by tests/unit/migration_batch_test.go
  - Proofs: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/tests.migration_golden.txt and tests.migration_batch.txt
- Explicit missing-endpoints negative tests: tests/unit/migration_missing_endpoints_test.go (ensures no outputs and structured causes)
  - Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/tests.migration_missing_endpoints.txt
- CLI negative path proves zero outputs: tests/unit/migration_cli_te_test.go
  - Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/tests.migration_cli_te.txt

## T060 Decision on MigrationPlan CRD

- Decision record declines CRD enablement at Phase 6; annotations/Git review suffice: docs/migration/DECISION-T060.md
  - Proof: docs/migration/DECISION-T060.md (file citation; not excerpted due to size constraints). Key statement appears at line 5–15.

## T061 Not applicable because T060 did not enable the CRD

- No CRD, RBAC, or controller added; nothing to prove in this phase.

## Additional provenance proofs

- Batch renderer and structured error marshalling: pkg/migration/batch.go
  - Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/migration.batch.txt

All cited files are present in the repository. The unit tests and fixtures provide independent, reproducible verification for supported mappings, limited equivalence with opt-in, and rejection of unsupported or malformed inputs with zero downstream outputs.
