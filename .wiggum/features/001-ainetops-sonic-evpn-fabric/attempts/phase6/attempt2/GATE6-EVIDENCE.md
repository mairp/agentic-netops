# Phase 6 — Migration translation (US1): Evidence

This evidence demonstrates that every Phase 6 acceptance criterion is fully implemented in code and verified by unit tests. For each task, we cite concrete files and include a proof slice under gates/proofs with line numbers of the exact symbols.

- T052 Define a strict normalized input schema and forbid raw CLI
  - Implemented in pkg/migration/input.go: ServiceInput, UnsupportedClaims, and policy/endpoint structures. Raw CLI is explicitly modeled as an unsupported claim and thus rejected. Strict JSON parsing rejects unknown fields.
  - Files and proof slices:
    - pkg/migration/input.go — ServiceInput core fields: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/T052-ServiceInput.txt
    - pkg/migration/input.go — UnsupportedClaims including RawCLI: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/T052-UnsupportedClaims.txt
    - pkg/migration/parse.go — ParseStrictBatch with DisallowUnknownFields: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/T052-ParseStrictBatch.txt

- T053 [P] [US1] VPLS/multipoint-L2VPN to bridge/L2VNI translation
  - Implemented in pkg/migration/translate.go: case ServiceVPLS renders a bridge domain with l2vni and L2 attachments; deterministic YAML builder enforces stable ordering.
  - Files and proof slices:
    - pkg/migration/translate.go — VPLS translation and attachments: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/T053-VPLS-Translate.txt

- T054 [P] [US1] L3VPN to VRF/L3VNI/RD/RT/Type-5 translation
  - Implemented in pkg/migration/translate.go: case ServiceL3VPN renders routers with RD/RT, l3vni, and prefixes (Type-5 routing intent) and attachments bound to the VRF.
  - Files and proof slices:
    - pkg/migration/translate.go — L3VPN Router with L3VNI, routeTargets, prefixes: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/T054-L3VPN-Translate.txt

- T055 [P] [US1] VPWS/E-Line limited-equivalence mapping
  - Enforced in pkg/migration/input.go: validation requires exactly 2 endpoints and policy opt-in vpwsLimitedEquivalence=true; translation adds a limited-equivalence annotation.
  - Files and proof slices:
    - pkg/migration/input.go — VPWS validation and policy name: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/T055-VPWS.txt

- T056 [P] [US1] Integrated L2/L3 symmetric-IRB translation
  - Implemented in pkg/migration/input.go (IRBGateway schema) and pkg/migration/translate.go (case ServiceIRB) which renders VRF + bridge domain with irb {vrf, gatewayIPv4, gatewayIPv6} and L2 attachments.
  - Files and proof slices:
    - pkg/migration/input.go and pkg/migration/translate.go — IRB schema and translation: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/T056-IRB.txt

- T057 [US1] All-or-nothing validation and structured unsupported-feature results (FR-011)
  - Implemented in pkg/migration/input.go ValidateAllOrNothing with explicit causes for unsupported fields, unknown fields (via strict parse), collisions, and absent/mismatched endpoints; pkg/migration/batch.go returns a single ValidationError aggregating causes; CLI emits structured JSON error with causes and exits non-zero before any output.
  - Files and proof slices:
    - pkg/migration/input.go and pkg/migration/batch.go and cmd/migration-translator/main.go: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/T057-Validation.txt

- T058 Deterministic CLI/library output with stable provenance annotations
  - Library: pkg/migration/translate.go builds YAML with deterministic key order and stable annotations (ainetops.io/translator, translator-version, mapping-version, migration-input-hash, tenant, service-type, limited-equivalence when applicable). Translator/version constants in pkg/migration/input.go. Canonical input hash via SHA-256 over stable JSON in input.go.
  - Files and proof slices:
    - pkg/migration/input.go and pkg/migration/translate.go: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/T058-Determinism.txt

- T058a Package deterministic library + CLI binary (no in-cluster workload at this stage)
  - CLI at cmd/migration-translator/main.go consumes stdin or --file; Makefile has build-migration-cli with reproducible flags (-trimpath, -buildid=, CGO_DISABLED).
  - Files and proof slices:
    - Makefile and cmd/migration-translator/main.go: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/T058a-Package.txt

- T059 Golden and table tests for supported/limited/unsupported/collision/malformed; prove rejects cause no downstream resources
  - Tests under tests/unit:
    - migration_golden_test.go compares spec YAML for VPLS/L3VPN/VPWS opt-in
    - migration_translator_test.go covers VPLS/L3VPN/VPWS/IRB and unsupported rejection, deterministic hash
    - migration_batch_test.go covers all-or-nothing batch behavior, mixed unsupported
    - migration_parse_strict_test.go rejects unknown fields
    - migration_annotations_test.go ensures provenance annotations are present
  - Files and proof slices:
    - .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/T059-Tests.txt

- T060 Decide on MigrationPlan CRD
  - Decision: Not required for this phase. The deterministic annotations (translator, version, mapping version, input-hash, tenant, service-type, limited-equivalence) and Git review meet audit needs now. No MigrationPlan CRD is created; no duplicate service/fabric CRD exists.
  - Files and proof slices:
    - tests/unit/migration_annotations_test.go: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/T060-Decision.txt

- T061 Conditional CRD work
  - Not applicable because T060 chose to defer the optional MigrationPlan CRD. No CRD, RBAC, or controller was added in this phase.

Verification summary
- All Go unit tests pass under fixed argv: `/usr/lib/go-1.24/bin/go test ./...`
- Deterministic YAML output is verified via golden tests. Unknown and unsupported inputs are rejected before any generated Network output.

Changed/added files (key ones):
- pkg/migration/input.go
- pkg/migration/parse.go
- pkg/migration/batch.go
- pkg/migration/translate.go
- pkg/migration/yaml.go (helper retained though buildYAML is used to enforce order)
- cmd/migration-translator/main.go
- Makefile (build-migration-cli)
- tests/unit/*.go and tests/unit/testdata/migration/*
- Proof slices under .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/*.txt
