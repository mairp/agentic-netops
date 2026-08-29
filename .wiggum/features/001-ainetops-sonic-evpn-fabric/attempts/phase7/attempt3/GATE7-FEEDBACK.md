# Phase 7 — critic feedback (REJECTED)

The following must be addressed before re-writing GATE7-EVIDENCE.md:

Unmet or unclear criteria:

- T063 gNMIc as sole SONiC device-metric collector, OTLP to OTel, SDC subscribe disabled, and no duplicate device series
  - Sole collector and OTLP path: gNMIc Deployment (deploy/gnmi/gnmic.yaml) and OTLP URL are grounded, and SDC subscribe is disabled both declaratively and at runtime (deploy/sdc/seed/sonic-schema.yaml and .wiggum/.../kubectl-get-sdc-subscribe.txt). Independent kubectl snapshots show gNMIc and OTel are deployed. These parts are satisfied.
  - No duplicate SONiC device time series: The only grounded runtime query result is .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/prom-query-no-duplicates.json with a single unlabeled sample value "1". This does not substantiate per-device uniqueness nor interface-level deduplication:
    - The documented expression in .wiggum/.../prometheus-queries.md for exporter distinctness should yield one sample per device (count without(instance) (count by(device, instance) (...))). The grounded result contains no device label at all, so it cannot prove per-device uniqueness.
    - The two additional queries documented to assert no duplicates for {device,interface} across packets and octets have no grounded results attached.
    - Actionable gaps:
      - Provide grounded Prometheus API results for the interface-level duplicate checks:
        NEEDS-GROUNDING:.wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/prom-query-no-duplicates-interfaces-packets.json
        NEEDS-GROUNDING:.wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/prom-query-no-duplicates-interfaces-octets.json
      - Provide a grounded result that proves per-device exporter uniqueness with device labels present (e.g., show a vector with device=spine01, spine02, leaf01, leaf02 each having value 1), or adjust the query to return per-device samples and include its result:
        NEEDS-GROUNDING:.wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/prom-query-exporter-distinctness-by-device.json

All other Phase 7 criteria listed in “Previously Confirmed” remain unchanged-bytes and are not contradicted by the current snapshot.

VERDICT efdb5f70bbcf1abf: REJECTED

