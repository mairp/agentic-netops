# Phase 6 — critic feedback (REJECTED)

The following must be addressed before re-writing GATE6-EVIDENCE.md:

REJECTED criteria and gaps

- T054 [P] [US1] Implement L3VPN to VRF/L3VNI/RD/RT/Type-5 translation
  - The provided proof slice shows L3VNI and Type-5 prefixes are rendered, but does not substantiate that RD and route targets are actually set in the L3VPN translation. In translate.go, the case ServiceL3VPN is truncated at “RD:” and there is no anchored line demonstrating RD is assigned from in.RDRT.RD or that RouteTargets is populated from in.RDRT.{ImportRT,ExportRT}. Likewise, buildYAML evidence does not clearly show “rd:” output for routers. Provide explicit, anchored lines showing:
    - RD: in.RDRT.RD and RouteTargets: RouteTargets{Import: in.RDRT.ImportRT, Export: in.RDRT.ExportRT} are set in case ServiceL3VPN
    - YAML output includes the RD and non-empty routeTargets under routers
  - NEEDS-GROUNDING:pkg/migration/translate.go

- T057 [US1] Implement all-or-nothing validation and structured unsupported-feature results (FR-011)
  - Unknown fields are not producing structured results. The CLI handles parse errors from ParseStrictBatch via fatal(err), which prints an unstructured message and exits with code 1 before processBatch runs. The acceptance requires structured unsupported-feature results for unknown fields (listed alongside TE, pseudowire OAM/control-word, multicast VPN, complex QoS/OAM, service chain, collisions, and absent endpoints). Current structured JSON emission only happens after validation (in processBatch). To meet T057:
    - Catch unknown-field parse errors and emit a structured JSON error (consistent shape with the validation path, including “causes”) before any output.
    - Add unit/CLI tests demonstrating that unknown fields yield a structured error and zero downstream resources.

- T059 Add table/golden tests for every supported, limited, unsupported, collision, and malformed fixture; prove rejected fixtures cause no downstream resources
  - The proof file lists test function names, but the actual contents of the cited tests and their fixtures are not shown. Specifically needed to judge this criterion:
    - Evidence that collision cases (duplicate service IDs) are tested and cause an aggregated rejection with no YAML emitted.
    - Evidence that malformed/unknown-field inputs are tested and cause a structured rejection with no YAML emitted.
    - Golden outputs for supported cases (VPLS, L3VPN) and the limited-equivalence VPWS case, and assertions for deterministic output.
  - Provide the test contents and key fixtures or anchored excerpts proving the above behaviors.
  - NEEDS-GROUNDING:tests/unit/migration_batch_test.go
  - NEEDS-GROUNDING:tests/unit/migration_golden_test.go
  - NEEDS-GROUNDING:tests/unit/migration_translator_test.go
  - NEEDS-GROUNDING:tests/unit/migration_parse_strict_test.go
  - NEEDS-GROUNDING:tests/unit/testdata/migration/

VERDICT 0fe97a50271a4e3a: REJECTED

