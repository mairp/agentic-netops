# Phase 6 — Migration translation (US1): Evidence

This evidence demonstrates that every Phase 6 acceptance criterion (T052–T061 scope for US1) is implemented and independently evidenced. For each checkbox, I cite exact file paths and stage line-numbered proof slices under .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/ that include the named symbols.

- T052 Define a strict normalized input schema; explicitly forbid raw CLI
  - Implemented in pkg/migration/input.go: type definitions for "ServiceInput", "ServiceType", "RdRt", "Endpoint", "AddressFamilies", "Policies", and explicit UnsupportedClaims fields ("RawCLI", "TEPolicy", "PseudowireOAM", "ControlWord", "MulticastVPN", "ComplexQoS", "ServiceChain"). All-or-nothing validation is implemented in ServiceInput.ValidateAllOrNothing, which enumerates these unsupported causes and rejects absent endpoints and collisions. Strict unknown-field rejection is enforced by ParseStrictBatch using json.Decoder.DisallowUnknownFields.
  - Proofs:
    - pkg/migration/input.go with anchors: ServiceInput, UnsupportedClaims, "unsupported: rawCLI", and ValidateAllOrNothing causes
      - .wiggum/.../proofs/pkg.migration.input.go.full.txt
      - .wiggum/.../proofs/anchor.ServiceInput.txt
      - .wiggum/.../proofs/anchor.unsupported_rawCLI.txt
      - .wiggum/.../proofs/anchor.unsupported_tePolicy.txt (and other unsupported anchors)
      - .wiggum/.../proofs/anchor.endpoints_required.txt
    - pkg/migration/parse.go showing DisallowUnknownFields
      - .wiggum/.../proofs/pkg.migration.parse.go.full.txt
      - .wiggum/.../proofs/anchor.DisallowUnknownFields.txt

- T053 [P] [US1] VPLS/multipoint-L2VPN to bridge/L2VNI translation
  - Implemented in pkg/migration/translate.go case ServiceVPLS: emits spec.bridgeDomains with "l2vni" and EVPN routeTargets, and attachments with VLANs.
  - Unit + golden tests cover expected output for a supported VPLS fixture.
  - Proofs:
    - .wiggum/.../proofs/pkg.migration.translate.go.full.txt (see "case ServiceVPLS")
    - .wiggum/.../proofs/anchor.case_VPLS_VPWS.txt
    - .wiggum/.../proofs/anchor.bridgeDomains.txt
    - Golden spec: tests/unit/testdata/migration/supported_vpls.spec.golden.yaml → .wiggum/.../proofs/supported_vpls.spec.golden.yaml.txt
    - Test: tests/unit/migration_golden_test.go → .wiggum/.../proofs/tests.unit.migration_golden_test.go.full.txt

- T054 [P] [US1] L3VPN to VRF/L3VNI/RD/RT/Type-5 translation
  - Implemented in pkg/migration/translate.go case ServiceL3VPN: emits spec.routers with name "vrf-<id>", "rd", routeTargets, "l3vni", and "prefixes" (this models Type-5 reachability intent at the Kubenet layer; Type-5 rendering to device is covered in Phase 4 renderers).
  - Proofs:
    - .wiggum/.../proofs/pkg.migration.translate.go.full.txt (see "case ServiceL3VPN")
    - .wiggum/.../proofs/anchor.case_L3VPN.txt
    - .wiggum/.../proofs/anchor.l3vni.txt and .wiggum/.../proofs/anchor.prefixes.txt
    - Unit test: tests/unit/migration_translator_test.go → asserts routers and l3vni
      (.wiggum/.../proofs/tests.unit.migration_translator_test.go.full.txt)

- T055 [P] [US1] VPWS/E-Line to two-attachment L2VNI with explicit limited-equivalence opt-in
  - Implemented in input schema + validation: ServiceType "VPWS" requires exactly two endpoints and fails without Policies.VPWSLimitedEquivalence=true. Translation reuses the bridgeDomain/L2VNI shape and adds annotation ainetops.io/limited-equivalence=vpws-to-l2vni on the generated Kubenet Network for durable provenance.
  - Proofs:
    - Validation: .wiggum/.../proofs/pkg.migration.input.go.full.txt ("policy: vpwsLimitedEquivalence...")
    - Translation annotation: .wiggum/.../proofs/anchor.limited_equivalence_annotation.txt
    - Unit test: tests/unit/migration_translator_test.go (VPWSLimitedEquivalenceRequired)
      → .wiggum/.../proofs/tests.unit.migration_translator_test.go.full.txt

- T056 [P] [US1] Integrated L2/L3 to symmetric-IRB translation
  - Implemented in pkg/migration/translate.go case ServiceIRB: emits spec.routers with L3VNI/RD/RT and spec.bridgeDomains with l2vni and an irb block containing vrf/gatewayIPv4/gatewayIPv6; attachments are VLAN-based.
  - Proofs:
    - .wiggum/.../proofs/pkg.migration.translate.go.full.txt ("case ServiceIRB" and "\"irb\"")
    - .wiggum/.../proofs/anchor.case_IRB.txt and .wiggum/.../proofs/anchor.irb_block.txt
    - Unit test: tests/unit/migration_translator_test.go (IRBTranslation)

- T057 [US1] All-or-nothing validation and structured unsupported-feature results (FR-011)
  - Implemented in ServiceInput.ValidateAllOrNothing and batch-level RenderBatch. Unsupported fields (TE, pseudowire OAM/control-word, multicast VPN, complex QoS/OAM, service chain, rawCLI), unknown fields (ParseStrictBatch DisallowUnknownFields), collisions (duplicate serviceId), and absent endpoints cause a terminal ValidationError with causes. RenderBatch aggregates causes and returns no outputs on any failure. CLI emits deterministic JSON on stderr (see cmd/migration-translator/main.go processBatch).
  - Proofs:
    - .wiggum/.../proofs/pkg.migration.input.go.full.txt and anchors for each unsupported cause
    - .wiggum/.../proofs/pkg.migration.parse.go.full.txt (DisallowUnknownFields)
    - .wiggum/.../proofs/pkg.migration.batch.go.full.txt (RenderBatch and MarshalError)
    - Tests: tests/unit/migration_parse_strict_test.go, tests/unit/migration_batch_test.go

- T058 Deterministic CLI/library output with stable provenance annotations
  - Library: Translate builds deterministic maps then marshals to JSON and converts with vendor-pinned sigs.k8s.io/yaml. Annotations include: "ainetops.io/translator", "ainetops.io/translator-version", "ainetops.io/mapping-version", "ainetops.io/migration-input-hash", "ainetops.io/tenant", and "ainetops.io/service-type". CanonicalHash computes SHA256 over the normalized input JSON for durable provenance.
  - Proofs:
    - .wiggum/.../proofs/pkg.migration.translate.go.full.txt with ainetops.io annotations
    - .wiggum/.../proofs/anchor.annotation_translator.txt
    - .wiggum/.../proofs/pkg.migration.yaml.go.full.txt and .wiggum/.../proofs/anchor.JSONToYAML.txt
    - .wiggum/.../proofs/pkg.migration.input.go.full.txt (CanonicalHash)

- T058a Package as deterministic library + CLI binary; no in-cluster workload created
  - Library is under pkg/migration/. The CLI binary is at cmd/migration-translator/main.go. The Makefile adds build and build-migration-cli targets. Build log is captured.
  - Proofs:
    - .wiggum/.../proofs/cmd.migration-translator.main.go.full.txt
    - .wiggum/.../proofs/Makefile.full.txt (targets build, build-migration-cli)
    - .wiggum/.../proofs/build-migration-cli.run.log

- T059 Table/golden tests for supported, limited, unsupported, collision, malformed; prove rejected fixtures cause no downstream resources
  - Tests:
    - tests/unit/migration_golden_test.go with supported_vpls.json → YAML spec golden
    - tests/unit/migration_translator_test.go covers supported VPLS/L3VPN/IRB and VPWS limited equivalence
    - tests/unit/migration_parse_strict_test.go rejects unknown field
    - tests/unit/migration_batch_test.go enforces all-or-nothing for duplicates and unsupported-in-batch
  - Fixtures staged under tests/unit/testdata/migration/*.json and golden YAML under tests/unit/testdata/migration/*.yaml
  - Proofs:
    - .wiggum/.../proofs/tests.unit.migration_golden_test.go.full.txt and supported_vpls.spec.golden.yaml.txt
    - .wiggum/.../proofs/tests.unit.migration_translator_test.go.full.txt
    - .wiggum/.../proofs/tests.unit.migration_parse_strict_test.go.full.txt
    - .wiggum/.../proofs/tests.unit.migration_batch_test.go.full.txt

- T060 Decide on MigrationPlan CRD
  - Decision: NOT enabled in this phase. Deterministic annotations and Git review suffice for audit per plan.md section 7; no duplicate service/fabric CRD is introduced. Repo-wide grep confirms no MigrationPlan API or controller exists.
  - Proofs:
    - .wiggum/.../proofs/grep_MigrationPlan_repo.txt (empty for project code; vendor references, if any, are unrelated)

- T061 Conditional on T060: not applicable (no CRD introduced). No controller/manifests are added; nothing is deployed in-cluster for migration in this phase.

Checkpoint: Supported intent maps predictably, VPWS limited equivalence requires opt-in, and unsupported intent is rejected before mutation. No duplicate service/fabric CRD exists.
