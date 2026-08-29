# Phase 7 — critic feedback (REJECTED)

The following must be addressed before re-writing GATE7-EVIDENCE.md:

REJECTED criteria and required fixes:

- T063 — gNMIc sole SONiC device-metric collector, OTLP export, SDC subscribe disabled, and no duplicate device series
  - Missing independent proof that SDC Subscriptions are disabled at runtime. You cite a kubectl capture, but the file is absent. Additionally, your anchored proof shows a contradictory SyncProfile with subscribe.sampleInterval set, which undermines the claim.
    - Provide a kubectl read of the live SyncProfile showing spec.data.subscribe is {}.
    - NEEDS-GROUNDING:.wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/kubectl-get-sdc-subscribe.txt
    - Note: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/deploy.sdc.seed.sonic-schema.yaml.proof.txt currently shows subscribe: { sampleInterval: 10s }; reconcile this contradiction with fresh runtime evidence.
  - Missing runtime proof that no SONiC device time series are duplicated. You provided query expressions, but not their evaluated results.
    - Capture and commit the query results showing the expected single-exporter/no-duplicate series conditions.
    - NEEDS-GROUNDING:.wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/prom-query-no-duplicates.json

- T068 — Orchestration and SRv6 service-path panels
  - The SRv6 service-path dashboard does not meet the “active SRv6 primary/alternate SID path with endpoint and behavior annotations” requirement. The current dashboard (deploy/observability/dashboards/srv6-service-path.json) only includes:
    - MySID counters: rate(sonic_srv6_mysid_packets_total[5m])
    - Active Path State: max by(path) (ainetops_srv6_active_path{path=~'primary|alternate'})
    - It lacks any panel or label usage that surfaces endpoint and behavior annotations.
  - Add panels/targets that include endpoint and behavior labels (e.g., by(path, endpoint, behavior) or otherwise render these annotations visibly), and ensure the dashboard JSON encodes those dimensions.

All other criteria either have sufficient evidence or were previously confirmed and not contradicted by the current snapshot.

VERDICT e2b9ef4759f35c6d: REJECTED

