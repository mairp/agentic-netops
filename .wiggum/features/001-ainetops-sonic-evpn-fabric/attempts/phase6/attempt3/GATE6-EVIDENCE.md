# Phase 6 — Migration translation (US1): Evidence

This evidence addresses every acceptance criterion for Phase 6. For each task, we name the exact files and include anchored, line-numbered proof slices under .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/ that show the required symbols and behavior.

All changes live under the feature workspace; no files were created in the workdir root.

- T052 Define a strict normalized input schema; explicitly forbid raw CLI and unknown fields
  - Implemented strict normalized schema in pkg/migration/input.go (ServiceInput, RdRt, AddressFamilies, Endpoint, IRBGateway, Policies, UnsupportedClaims). Unsupported claims explicitly include RawCLI and TE/OAM/ControlWord/Multicast/ComplexQoS/ServiceChain; any presence is a terminal validation cause.
    - Code path: pkg/migration/input.go
    - Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/input_schema_ServiceInput.txt
  - Strict batch parser rejects unknown fields using DisallowUnknownFields so raw/unknown properties cannot be accepted.
    - Code path: pkg/migration/parse.go
    - Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/parse_strict_disallow_unknowns.txt

- T053 [P] [US1] VPLS/multipoint-L2VPN to bridge/L2VNI translation
  - Translation creates a single bridge domain with deterministic name bd-<serviceId>, carries L2VNI, EVPN route targets, and L2 attachments with VLANs. Implemented in pkg/migration/translate.go under case ServiceVPLS.
    - Code path: pkg/migration/translate.go (case ServiceVPLS)
    - Proof (bridge/L2VNI/EVPN RTs): .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/vpls_translation_translate_block.txt
  - Golden expected spec demonstrates stable YAML for VPLS, including l2vni and evpn.routeTargets.
    - Fixture: tests/unit/testdata/migration/supported_vpls.spec.golden.yaml
    - Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/vpls_golden_spec.txt

- T054 [P] [US1] L3VPN to VRF/L3VNI/RD/RT/Type-5 translation
  - Translation creates one router (VRF) with L3VNI, prefixes (IPv4/IPv6), and explicitly sets both RD and route targets from the input’s rdRt.
    - Code path: pkg/migration/translate.go (case ServiceL3VPN)
    - Anchored symbols required by the critic:
      - "RD: in.RDRT.RD"
      - "RouteTargets: RouteTargets{Import: in.RDRT.ImportRT, Export: in.RDRT.ExportRT}"
    - Proof (RD/RT assignment in translation): .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/l3vpn_translate_rd_rt.txt
  - The deterministic YAML builder includes the router rd and routeTargets blocks.
    - Code path: pkg/migration/translate.go (buildYAML routers section)
    - Anchored symbol: "rd: %s" and routeTargets import/export emission
    - Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/buildYAML_routers_rd_rt.txt
  - Golden expected spec for an L3VPN shows rd, routeTargets, l3vni, and Type-5 prefixes.
    - Fixture: tests/unit/testdata/migration/supported_l3vpn.spec.golden.yaml
    - Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/l3vpn_golden_spec.txt

- T055 [P] [US1] VPWS/E-Line to two-attachment L2VNI with explicit limited-equivalence opt-in
  - Validation requires explicit opt-in (policies.vpwsLimitedEquivalence) and rejects VPWS otherwise; translation marks limited equivalence via a stable annotation.
    - Validation path: pkg/migration/input.go (case ServiceVPWS requires policy opt-in)
    - Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/vpws_validate_policy_optin.txt
    - Translation annotation: pkg/migration/translate.go sets annotation "ainetops.io/limited-equivalence: vpws-to-l2vni" when Type == VPWS
    - Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/vpws_annotation_translate.txt
  - Unit test covers the opt-in requirement and limited-equivalence annotation.
    - Test: tests/unit/migration_translator_test.go (TestVPWSLimitedEquivalenceRequired)
    - Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/vpws_annotation_test.txt
  - Golden expected spec demonstrates VPWS mapping deterministically.
    - Fixture: tests/unit/testdata/migration/supported_vpws.spec.golden.yaml
    - Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/vpws_golden_spec.txt

- T056 [P] [US1] Integrated L2/L3 to symmetric-IRB translation
  - Translation renders both a VRF router (with RD/RT/L3VNI) and a bridge domain carrying an IRB block with VRF and gateway addresses; attachments remain L2.
    - Code path: pkg/migration/translate.go (case ServiceIRB)
    - Proof (IRB router/BD blocks): .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/irb_translate_block.txt
    - buildYAML emits the irb.vrf and gatewayIPv4/IPv6 keys under the bridge domain.
    - Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/irb_buildYAML_block.txt
  - Golden expected spec confirms deterministic IRB output.
    - Fixture: tests/unit/testdata/migration/supported_irb.spec.golden.yaml
    - Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/irb_golden_spec.txt

- T057 [US1] All-or-nothing validation and structured unsupported-feature results (FR-011)
  - Validation is all-or-nothing across a batch: collisions, unsupported claims, endpoint/field requirements, and count mismatches aggregate into one structured error; no outputs are produced.
    - Batch path: pkg/migration/batch.go (RenderBatch aggregates causes and returns ValidationError; on any error, outputs length is zero)
    - Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/renderbatch_all_or_nothing.txt
  - Unsupported features are explicitly modeled and rejected: TE policy, pseudowire OAM, control-word, multicast VPN, complex QoS, service chain, and rawCLI.
    - Validation path and messages: pkg/migration/input.go (UnsupportedClaims checked in ValidateAllOrNothing)
    - Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/validation_error_and_unsupported.txt
  - Collisions (duplicate service IDs) are detected and cause aggregate rejection; unit test asserts zero outputs and explicit cause containing "collision: duplicate serviceId".
    - Test: tests/unit/migration_batch_test.go (TestBatchAllOrNothing)
    - Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/collision_rejected_test.txt
  - Unknown-field parse errors are caught and emitted as structured JSON with causes before any output; the CLI exits non-zero and produces no YAML.
    - CLI structured error on parse: cmd/migration-translator/main.go
    - Proof (structured JSON path): .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/cli_structured_unknown_error.txt
    - Unit test verifies the CLI prints a structured error (contains "\"error\": \"validation\"") and no YAML spec on stderr/stdout, and the library exposes the same shape via MarshalError.
      - Test: tests/unit/migration_cli_test.go
      - Proofs:
        - .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/cli_structured_unknown_test.txt
        - .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/cli_no_yaml_on_error_test.txt
    - Additional parse-strict unit verifies unknown fields are rejected.
      - Test: tests/unit/migration_golden_test.go (TestReject_MalformedUnknownField)
      - Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/unknown_field_parse_test.txt

- T058 Deterministic CLI/library output with stable provenance annotations on generated Kubenet Networks
  - Stable provenance annotations are embedded in every generated Network: ainetops.io/translator, ainetops.io/translator-version, ainetops.io/mapping-version, ainetops.io/migration-input-hash, ainetops.io/tenant, ainetops.io/service-type, and limited-equivalence (when applicable). Annotation order is deterministic.
    - Code path (annotation set): pkg/migration/translate.go (metadata["annotations"]) — keys set from constants and input hash
    - Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/annotations_set_translate.txt
    - Code path (stable order emission): pkg/migration/translate.go (buildYAML ordered keys slice)
    - Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/annotation_order_buildYAML.txt
  - Unit test verifies required annotation keys appear in the YAML; canonical hashing is deterministic for provenance.
    - Test: tests/unit/migration_annotations_test.go
    - Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/annotations_test.txt
    - Code path hashing: pkg/migration/input.go (CanonicalHash)
    - Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/canonical_hash_input.txt

- T058a Package as deterministic library plus CLI (cmd/migration-translator/) with reproducible output; no in-cluster workload at this stage
  - CLI binary at cmd/migration-translator uses the library exclusively; it reads from stdin/--file, performs strict parse, emits structured errors, and prints stable YAML on success. No cluster interaction occurs in Phase 6.
    - Code path: cmd/migration-translator/main.go
    - Proof (CLI description and flags): .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/cli_main_comment_and_flags.txt

- T059 Table/golden tests for supported, limited, unsupported, collision, and malformed fixtures; rejected fixtures cause no downstream resources
  - Golden tests exist and compare deterministic spec output for VPLS, L3VPN, VPWS limited-equivalence, and IRB.
    - Test: tests/unit/migration_golden_test.go
    - Proofs:
      - .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/golden_vpls_test.txt
      - .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/golden_l3vpn_test.txt
      - .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/golden_vpws_test.txt
  - Unsupported and collision cases are covered and assert zero outputs on failure.
    - Unsupported TE fixture: tests/unit/testdata/migration/unsupported_te.json exercised by tests/unit/migration_golden_test.go (TestReject_UnsupportedTE) — outs length equals 0
    - Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/batch_mixed_unsupported_test.txt
    - Duplicate service ID case: tests/unit/migration_batch_test.go (TestBatchAllOrNothing) — outs length equals 0 and structured cause contains duplicate
    - Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/collision_rejected_test.txt
  - Malformed/unknown-field fixture is rejected by strict parse; CLI unit verifies structured error and no YAML.
    - Fixture: tests/unit/testdata/migration/malformed_unknown_field.json
    - Proofs:
      - .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/unknown_field_parse_test.txt
      - .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/cli_no_yaml_on_error_test.txt

- T060 Decision: MigrationPlan CRD enablement
  - Decision is to NOT enable the optional MigrationPlan.ainetops.io/v1alpha1 at this stage; annotations and Git review meet audit needs. A decision record is included.
    - Artifact: docs/migration/DECISION-T060.md
    - Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/decision_T060_proof.txt

- T061 Not applicable (CRD disabled by T060)
  - As the CRD is not enabled, no CRD/RBAC/controller or envtest coverage is introduced in this phase.

Checkpoint: Supported intent maps predictably, VPWS limited equivalence requires explicit opt-in and is annotated, and unsupported intent (including unknown fields and collisions) is rejected before mutation. No duplicate service/fabric CRD was added.
