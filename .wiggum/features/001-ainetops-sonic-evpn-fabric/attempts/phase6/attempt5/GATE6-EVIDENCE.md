# Phase 6 — Migration translation (US1): Evidence

This evidence demonstrates that every acceptance criterion for Phase 6 is implemented in code and verified by deterministic tests. Each task cites exact paths and includes anchored, line-numbered proof slices under gates/proofs/ as required.

## T052 Define a strict normalized input schema and forbid raw CLI
- Implemented in pkg/migration/input.go:
  - Required identity fields: "serviceId", "type", "tenant"; endpoints list; explicit RD/RT via "rdRt"; VNIs via "l2vni"/"l3vni"; L3 address families via "addressFamilies"; per-endpoint VLAN/VRF; IRB gateway block; explicit allow-listed Policies including "vpwsLimitedEquivalence"; and an UnsupportedClaims block enumerating disallowed features including "rawCLI".
  - Proof: .wiggum/.../proofs/T052-input-schema.input.go.proof.txt shows the schema symbols and json tags including "serviceId", "type", "tenant", "endpoints", "addressFamilies", "rdRt", "l2vni", "l3vni", Policies.VPWSLimitedEquivalence, and UnsupportedClaims.RawCLI.
- Strict parsing rejects unknown fields and thus raw CLI leakage: pkg/migration/parse.go uses DisallowUnknownFields.
  - Proof: .wiggum/.../proofs/T052-parse-strict.parse.go.proof.txt anchors ParseStrictBatch and strictUnmarshal with DisallowUnknownFields.

## T053 [P] Implement VPLS/multipoint-L2VPN to bridge/L2VNI translation
- Implemented in pkg/migration/translate.go: case ServiceVPLS produces a BridgeDomain with L2VNI and EVPN routeTargets, plus attachments.
  - Proof: .wiggum/.../proofs/T053-translate-vpls.translate.go.proof.txt greps BridgeDomain/EVPN/RouteTargets/case ServiceVPLS.
- Golden spec fixture matches expected output: tests/unit/testdata/migration/supported_vpls.spec.golden.yaml.
  - Proof: .wiggum/.../proofs/T053-golden-vpls.spec.golden.proof.txt contains the expected bridge domain, l2vni, and RTs.

## T054 [P] Implement L3VPN to VRF/L3VNI/RD/RT/Type-5 translation
- Implemented in pkg/migration/translate.go: case ServiceL3VPN creates Router with RD, routeTargets, L3VNI, prefixes, and L3 attachments (VRF-bound). Type-5 routing is represented by routed VRF/L3VNI and exported prefixes.
  - Proof: .wiggum/.../proofs/T054-translate-l3vpn.translate.go.proof.txt anchors Router, L3VNI, Prefixes, attachmentsForL3.
- Golden fixture: tests/unit/testdata/migration/supported_l3vpn.spec.golden.yaml.
  - Proof: .wiggum/.../proofs/T054-golden-l3vpn.spec.golden.proof.txt shows rd, import/export RTs, l3vni, prefixes, and VRF attachments.

## T055 [P] Implement VPWS/E-Line to two-attachment L2VNI with explicit limited-equivalence opt-in
- Validation requires exactly two endpoints and policy.VPWSLimitedEquivalence=true; otherwise rejected.
  - Proof: .wiggum/.../proofs/T055-vpws-validation-and-annotation.proof.txt shows validations and the "vpwsLimitedEquivalence" policy requirement.
- Translation adds deterministic limited equivalence annotation "ainetops.io/limited-equivalence: vpws-to-l2vni" and produces a dedicated bridge domain and L2VNI.
  - Proof: same proof file anchors the annotation path in translate.go; golden spec exists at tests/unit/testdata/migration/supported_vpws.spec.golden.yaml with two attachments.

## T056 [P] Implement integrated L2/L3 to symmetric-IRB translation
- Implemented in pkg/migration/translate.go: case ServiceIRB renders both Router (VRF/L3VNI/RD/RT) and BridgeDomain with IRB block (vrf, gatewayIPv4, gatewayIPv6) plus L2 attachments.
  - Proof: .wiggum/.../proofs/T056-translate-irb.translate.go.proof.txt anchors IRB and ServiceIRB path; golden spec at tests/unit/testdata/migration/supported_irb.spec.golden.yaml.

## T057 Implement all-or-nothing validation and structured unsupported-feature results (FR-011)
- All-or-nothing batch validation with aggregated causes and zero outputs on failure in pkg/migration/batch.go: RenderBatch collects causes, returns ValidationError; MarshalError returns deterministic JSON with HTML escaping disabled so messages like ">=1" are preserved verbatim.
  - Proof: .wiggum/.../proofs/T057-validation-rejection.proof.txt anchors RenderBatch, ValidationError aggregation, and MarshalError with SetEscapeHTML(false).
- Strict unknown-field rejection: pkg/migration/parse.go DisallowUnknownFields; unsupported claims cause explicit causes including "tePolicy", "pseudowireOAM", "controlWord", "multicastVPN", "complexQoS", "serviceChain", and "rawCLI"; absent endpoints and type-specific endpoint count checks are enforced.
  - Proof: same T057 proof anchors these causes in input.go and parse.go.
- Tests verify collisions, unsupported features, malformed/unknown inputs, and absent endpoints produce structured errors and no outputs: tests under tests/unit/* including migration_batch_test.go, migration_golden_test.go (unsupported/malformed cases), migration_missing_endpoints_test.go, and migration_cli_test.go.
  - Proof: same T057 proof lists the test functions and expectations.

## T058 Add deterministic CLI/library output with stable provenance annotations
- The translator produces deterministic Network YAML with stable annotation order and keys: ainetops.io/translator, translator-version, mapping-version, migration-input-hash, tenant, and service-type.
  - Proof: .wiggum/.../proofs/T058-determinism-annotations.proof.txt shows stable annotation order and constants.
- CLI packaged at cmd/migration-translator emits structured JSON errors to stderr and no YAML on failure; no cluster mutations occur in this phase.
  - Proof: .wiggum/.../proofs/T058a-cli.proof.txt anchors the CLI entrypoint and error emission.

## T058a Package the migration translator as a deterministic library plus CLI binary
- Library: pkg/migration/* provides strict parsing, validation, translation, and deterministic error marshaling.
- CLI: cmd/migration-translator/ main.go consumes JSON, emits YAML or structured error, and is used by tests via "go run".
  - Proof: .wiggum/.../proofs/T058a-cli.proof.txt confirms the packaged CLI.

## T059 Add table/golden tests for supported, limited, unsupported, collision, and malformed fixtures; rejected fixtures cause no downstream resources
- Golden fixtures and tests exist under tests/unit/testdata/migration/*.json and *.spec.golden.yaml; unit tests assert zero outputs on failure and presence of structured causes.
  - Proof: .wiggum/.../proofs/T059-tests-and-fixtures.proof.txt lists tests and fixtures.

## T060 Decide on MigrationPlan CRD
- Decision: Not enabled in this phase; annotations and Git review meet audit needs for MVP. No MigrationPlan CRD or controller exists in api/v1alpha1 or controllers/.
  - Proof: .wiggum/.../proofs/T060-no-crd-decision.proof.txt and T061-no-crd-controller.proof.txt show absence of MigrationPlan types/controllers.

## T061 If T060 enables the CRD…
- Not applicable because T060 did not enable the CRD; no CRD, status, RBAC, or controller added.

## Deterministic verification command
- All Go tests pass with the fixed argv used by the critic: `/usr/lib/go-1.24/bin/go test ./...`.

