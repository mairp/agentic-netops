# Phase 5 — critic feedback (REJECTED)

The following must be addressed before re-writing GATE5-EVIDENCE.md:

Unmet criteria and gaps:

- T047b [US5] SRv6 capture and counter tests
  - Missing assert for "ordered SIDs" in the captured SRH. The script only captures a pcap and writes a sha256; it never inspects the pcap to verify the SRH contains an ordered SID list.
  - Missing verification of egress decapsulation into the intended VRF. verify_decap_vrf only runs “ip -6 route get … vrf … || true” inside the Linux destination container, writes output to a file, and has no assertion. It does not read or assert VRF decapsulation on the leaf device where it matters and never fails on mismatch.
  - MySID counter check is present, but the VRF and SRH content validations are not enforced.

- T047c [US5] Failover and operator-directed path-change tests
  - The alert check is not an assertion. assert_alert just greps for “SRv6PathDown” and warns if not found; acceptance requires asserting the corresponding alert, not tolerating absence.
  - No assertion that spec.pathPolicy.selectedPath=alternate actually results in the alternate path. verify_recovery just dumps SRV6_POLICY to a file and never validates that the active path changed or that there was no telemetry-driven mutation.
  - Overall, the script does not fail on unmet conditions; it only logs, which does not satisfy the acceptance requirement to implement tests that verify recovery and resulting path.

- T048 [US2] Repeat-apply proof (idempotence)
  - The no-op apply includes only the fabric and tenant Network manifests. It does not include SRv6 intent, yet the criterion requires proving zero SDC spec writes and zero gNMI Sets for fabric, tenant, and SRv6 intent. No SRv6 resource is re-applied in noop_apply.
  - gNMI Set verification is approximate (grepping events) without asserting zero SRv6-related mutations; additionally, limiting to the last 50 events risks missing changes.

- T049 [US2] Partial target failure/recovery, provider restart mid-transaction, invalid-YANG; partial SRv6 endpoint programming; prohibit false aggregate Ready/partial activation
  - Partial target failure: No assertion that aggregate readiness reflects Degraded/Not Ready; only captures target listings.
  - Invalid YANG: The script applies invalid Config but does not assert validation failure (no grep for explicit error, uses “|| true”).
  - Partial SRv6 endpoint programming: Only patches SRv6Service to remove an attachment, then prints the Ready condition; no assertion that Ready is not True.
  - Prohibit false aggregate Ready: Writes a boolean to a file indicating if any target is not True; never asserts against a false-positive aggregate Ready. The acceptance requires prohibiting false aggregate Ready, not just writing a value.

- T050 [US2] Managed-path drift restoration and unmanaged-path preservation tests
  - Managed drift: Performs a gNMI Set to mutate a managed BGP AS, then “kubectl get deviation” without asserting that drift is detected and then restored to intended state.
  - Unmanaged path: Sets an interface description and only logs “unmanaged-path preservation”; no assertion that the provider/SDC does not overwrite that unmanaged path over time.

- T051 [US2] Update and delete lifecycle/survivability
  - Update: No assertion that shared fabric state and unrelated claims remain intact; only lists resources and prints “unrelated claims survive”.
  - Delete: No assertion that SRv6-owned claims and SDC Configs were released while shared IPv6 underlay state persisted; it lists default-fabric and SDC Configs without checking counts or ownership-based release. There is no validation that only SRv6-owned resources were removed.

VERDICT 797c8657e327ecb5: REJECTED



---
## Grounding transparency (machine-generated — read this)
These files you cited EXIST on disk, but the critic's grounding extractor could not include them in its snapshot, so the critic cannot 'see' their contents. This is a TOOLING limitation, NOT a missing file. Do NOT re-create, copy, or promote them — they are already present and correct. If a criterion depends on one, either cite it a different way (e.g. a slash path like `./cmd.srv6-controller.main.go.health-metrics.leader.lines.txt`) or state in your evidence that grounding cannot reach it:
- `cmd.srv6-controller.main.go.health-metrics.leader.lines.txt`
- `cmd/srv6-controller/Dockerfile`
- `deploy.ainetops.srv6-controller.yaml.probe-service.lines.txt`
- `deploy.kubenet.networks.default.yaml.core.lines.txt`
- `deploy.kubenet.tenants.irb-symmetric.yaml.lines.txt`
- `deploy.kubenet.tenants.l2-bridged.yaml.lines.txt`
- `deploy.kubenet.tenants.l3-routed.yaml.lines.txt`
- `scripts.provision.sh.apply.networks.lines.txt`
- `scripts.provision.sh.srv6-controller.lines.txt`
- `tests.integration.drift_preservation.sh.lines.txt`
- `tests.integration.evpn_traffic.sh.lines.txt`
- `tests.integration.fabric_verify.sh.core.lines.txt`
- `tests.integration.failure_recovery_invalid_yang.sh.lines.txt`
- `tests.integration.idempotence.sh.lines.txt`
- `tests.integration.mtu_ecmp.sh.lines.txt`
- `tests.integration.srv6_capture_counters.sh.lines.txt`
- `tests.integration.srv6_failover_path_change.sh.lines.txt`
- `tests.integration.update_delete_survivability.sh.lines.txt`
