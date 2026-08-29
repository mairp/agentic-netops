# Phase 6 — critic feedback (REJECTED)

The following must be addressed before re-writing GATE6-EVIDENCE.md:

Unmet or unclear acceptance criteria:

- T057 [US1] Implement all-or-nothing validation and structured unsupported-feature results (FR-011)
  - Collisions: The code in pkg/migration/batch.go detects duplicates and passes a dup flag to ValidateAllOrNothing(i, dup), but there is no grounded evidence that ValidateAllOrNothing in pkg/migration/input.go actually appends a structured cause when dup is true (e.g., “collision: duplicate serviceId …”). The provided T057 proof anchors cover unknown fields, unsupported claims, and endpoint-count checks, but do not show any collision handling logic or messages.
  - REQUIRED: Show the anchored implementation in pkg/migration/input.go for ValidateAllOrNothing that uses the dup flag to emit a structured collision cause, and an anchored test proving duplicate serviceId inputs are rejected with aggregated causes and zero outputs.
  - NEEDS-GROUNDING: pkg/migration/input.go
  - NEEDS-GROUNDING: tests/unit/migration_batch_test.go

- T059 Add table/golden tests for every supported, limited, unsupported, collision, and malformed fixture; prove rejected fixtures cause no downstream resources
  - Collision coverage: The fixtures listed under tests/unit/testdata/migration include supported_* and specific unsupported/malformed inputs (unsupported_te.json, malformed_unknown_field.json), but there is no grounded fixture or test demonstrating the “collision” case (e.g., duplicate service IDs in a batch) and asserting zero outputs. The T057 proof references a generic migration_batch_test.go fatal on nonzero outputs, but does not show a test table/fixture that triggers a collision nor the corresponding structured causes.
  - REQUIRED: Add or surface a collision test (e.g., a batch with duplicate serviceId) in tests/unit/migration_batch_test.go and/or a dedicated collision fixture, and anchor assertions that RenderBatch returns a structured error and produces no YAML outputs.
  - NEEDS-GROUNDING: tests/unit/migration_batch_test.go
  - If a separate collision fixture exists, also ground it: NEEDS-GROUNDING: tests/unit/testdata/migration/<collision_fixture>.json

VERDICT 07e7b5fc911302e8: REJECTED



---
## Grounding transparency (machine-generated — read this)
These files you cited EXIST on disk, but the critic's grounding extractor could not include them in its snapshot, so the critic cannot 'see' their contents. This is a TOOLING limitation, NOT a missing file. Do NOT re-create, copy, or promote them — they are already present and correct. If a criterion depends on one, either cite it a different way (e.g. a slash path like `./T061-no-crd-controller.proof.txt`) or state in your evidence that grounding cannot reach it:
- `T061-no-crd-controller.proof.txt`
