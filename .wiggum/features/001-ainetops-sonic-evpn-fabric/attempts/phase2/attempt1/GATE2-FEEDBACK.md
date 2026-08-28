# Phase 2 — critic feedback (REJECTED)

The following must be addressed before re-writing GATE2-EVIDENCE.md:

Unmet or unclear criteria detected:

- T009 [US3] lab/topology.clab.yml completeness (management network reuse and annotations)
  - The criterion requires explicit reuse of the external AINETOPS-owned Docker management network and annotations. The actual lab/topology.clab.yml snapshot does not show the top-level mgmt block or any AINETOPS annotations; only a comment mentions annotations/labels. The .wiggum proof file shows:
      mgmt:
        network: ainetops-mgmt
        mtu: 9216
        labels:
          ainetops.owner: ainetops
          ainetops.topology: sonic-evpn
    but this is not independently confirmed in the actual lab/topology.clab.yml excerpt provided. To approve, the mgmt.network ainetops-mgmt and mgmt labels/annotations must be visible in the grounded topology file content.
  - NEEDS-GROUNDING: lab/topology.clab.yml (top-level mgmt: network and mgmt: labels)

- T013 [US3] gNMI Capabilities/Get/Set/Subscribe qualification tests against pinned schema and credentials (including sonic-srv6 paths)
  - tests/integration/sonic_gnmi_suite.sh defines a run_all function that sets TLS/JSON_IETF and credential flags into an args array, but never uses that array when invoking gnmic. The code calls:
      "$GNMIC_BIN" --address "$t" "$@"
    and does not include "${args[@]}", so the tests are not actually run with TLS, certificates, or JSON_IETF encoding. This fails the “against the pinned schema and credentials” requirement and undermines Capabilities/Get/Set/Subscribe and sonic-srv6 path validation.
  - Required fix: pass the TLS/auth/encoding arguments to gnmic invocations (e.g., "$GNMIC_BIN" --address "$t" "${args[@]}" "$@") and ensure tests honor the pinned schema/credentials.

- T014 [P] [US3] Persistent configuration and required YANG path qualification tests
  - While tests/integration/yang_paths_suite.sh and lab/requirements/yang-paths.txt exist (good), the “persistent configuration” test in tests/integration/sonic_gnmi_suite.sh does not verify persistence across a restart. It only performs a Get on a telemetry port path and has a comment about the harness invoking it across a restart; however, scripts/lib/qualify.sh never performs a device/container restart between runs. Thus, no actual persistence qualification occurs.
  - Required fix: implement a controlled SONiC container restart in the qualification flow and re-run the Get/Set checks to confirm values persist (or otherwise provide a concrete, automated verification of persistence).

- T015 [P] [US3] EVPN/VXLAN Type 2/3/5 and SRv6 behaviors/counters capability tests
  - tests/integration/evpn_srv6_suite.sh only issues very generic gNMI Get calls (e.g., /openconfig-bgp:bgp for EVPN “Type 2/3/5”), and echoes markers for SRv6 behaviors. It does not actually validate EVPN route-type capabilities (Type 2, 3, 5 tables/routes), nor does it meaningfully assert H.Encaps.Red, End, End.DT46, ordered SID-list steering, decapsulation, or counters beyond superficial path existence on high-level sonic-srv6 nodes. This is insufficient to qualify the specified capabilities.
  - Required fix: enhance tests to:
    - Probe specific OpenConfig/SONiC paths that unambiguously indicate EVPN Type 2/3/5 route presence or configuration/state (not just top-level bgp).
    - Validate SRv6 behaviors by checking concrete sonic-srv6 structure/state (e.g., policy/locator/SID-list presence and relevant counters) and, where mandated by the spec, program and read back configuration/state indicative of H.Encaps.Red, End, End.DT46, SID-steering, and decapsulation.

- T016 [US3] make lab-qualify gating and machine-readable report
  - Positives: Makefile contains a lab-qualify target invoking scripts/lib/qualify.sh; qualify.sh aggregates test results and writes .wiggum/.../qualify.report.json, and exits non-zero on any failure (blocking downstream).
  - Concern: Runtime artifact proofs/qualify.report.json are missing from the snapshot, but that file is generated at runtime; absence in repo is not a blocker. However, because T013/T014/T015 are currently insufficient, this gate cannot be considered passing for the release acceptance profile requirement (“MUST pass both EVPN and SRv6, with no skip, mock, or Linux-only substitute”). Once the above fixes are made, ensure the gate runs the strengthened tests and the acceptance profile passes them without skips/mocks.

- T017 [US3] Idempotent containerlab deploy/inspect/destroy and teardown cleanliness
  - scripts/lib/containerlab.sh implements deploy/inspect/destroy, ensures the external ainetops-mgmt network, and checks for leftover AINETOPS-labeled containers, volumes named ainetops-*-etc-sonic, and generated TLS creds. This looks good.
  - Note: This is contingent on T009’s mgmt network definition being present in the actual topology file; confirm T009 as above.

VERDICT 3e1d97b6ae7a38af: REJECTED



---
## Grounding transparency (machine-generated — read this)
These files you cited EXIST on disk, but the critic's grounding extractor could not include them in its snapshot, so the critic cannot 'see' their contents. This is a TOOLING limitation, NOT a missing file. Do NOT re-create, copy, or promote them — they are already present and correct. If a criterion depends on one, either cite it a different way (e.g. a slash path like `./kvm`) or state in your evidence that grounding cannot reach it:
- `/dev/kvm`
- `versions.lock.yaml`
