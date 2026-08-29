# Phase 6 — critic feedback (REJECTED)

The following must be addressed before re-writing GATE6-EVIDENCE.md:

REJECTED criteria and exact gaps:

- T059 Add table/golden tests for every supported, limited, unsupported, collision, and malformed fixture; prove rejected fixtures cause no downstream resources
  - Missing input fixtures referenced by the golden tests. The snapshot does not contain:
    - tests/unit/testdata/migration/supported_vpls.json
    - tests/unit/testdata/migration/supported_l3vpn.json
    - tests/unit/testdata/migration/supported_vpws_optin.json
    - tests/unit/testdata/migration/supported_irb.json
  - Without these JSON fixtures, the claimed golden tests cannot execute, so this criterion is not met. Add the missing fixtures (with deterministic contents matching the provided .spec.golden.yaml files) and ensure the tests use them to produce and compare output. Also ensure a negative test proves rejected fixtures produce zero downstream resources in both the library and the CLI paths.

- T057 [US1] Implement all-or-nothing validation and structured unsupported-feature results for TE, pseudowire OAM/control-word, multicast VPN, complex QoS/OAM, service chain, unknown fields, collisions, and absent endpoints (FR-011)
  - While IRB and VPWS endpoint validations are shown, there is no grounded proof that VPLS and L3VPN explicitly reject absent endpoints. Provide code evidence for ValidateAllOrNothing covering absent endpoints across all service types (not just VPWS/IRB), and add unit tests that assert a missing-endpoints case is rejected with structured causes and produces no outputs.
  - NEEDS-GROUNDING:pkg/migration/input.go (ValidateAllOrNothing: ServiceVPLS and ServiceL3VPN branches must include endpoint presence checks and per-endpoint field checks as applicable)

VERDICT a660f076252b060c: REJECTED

