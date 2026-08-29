# Phase 7 — critic feedback (REJECTED)

The following must be addressed before re-writing GATE7-EVIDENCE.md:

Unmet or unclear criteria (actionable gaps):

- T063 Deploy gNMIc as sole SONiC device-metric collector, export OTLP, disable overlapping SDC subscriptions, and test no device series duplication
  - Missing independent effect-witness that the deployment exists and is the only device collector. You show manifests and a helper script, but no proof-of-run. Provide kubectl get output (already referenced in scripts/lib/observability.sh) under .wiggum/.../proofs showing exactly one Deployment for gNMIc and none other collecting SONiC device metrics.
  - The “no duplicate device series” test is not evidenced. The assert-single function only checks Deployment count and SDC subscribe={}, not duplicate series. Add a Prometheus query result proof (e.g., saved query output under .wiggum/.../proofs) demonstrating no duplicated device metrics, such as:
    - distinct exporters per device label for sonic_* metrics equals 1
    - absence of duplicate time series for the same {device,interface,metric}
  - Keep the existing SDC subscribe: {} proof; it’s good (deploy/sdc/seed/sonic-schema.yaml), but you still need the above independent observations.

- T064 [P] Deploy OTel Collector with required processors/exporters and receive OTLP from gNMIc and AINETOPS controllers
  - The collector config satisfies processors/exporter requirements and gNMIc points to it. However, there is no grounded evidence that the AINETOPS controllers actually export OTLP to the collector.
  - NEEDS-GROUNDING: deploy/ainetops/manifests/provider.yaml
  - NEEDS-GROUNDING: deploy/ainetops/manifests/srv6-controller.yaml
  - Provide anchored excerpts or proof slices showing OTEL_EXPORTER_OTLP_ENDPOINT (or equivalent) configured to the in-cluster collector Service, and a kubectl get/env dump proving those settings are applied to running Pods.

- T066 [P] Deploy Grafana with PVC, Secret creds, Service, provisioned Prometheus datasource, pinned Grafana Flow plugin, folders, and dashboards as code
  - The Flow plugin is not pinned/installed. grafana.yaml lacks any plugin installation (e.g., GF_INSTALL_PLUGINS for Grafana Flow). Add explicit, pinned plugin installation and provide a proof slice showing the exact plugin and version.
  - Dashboards-as-code exist (fabric-overview.json, pipeline-health.json), but there is no Grafana Flow physical topology dashboard provisioned here (see T067). Ensure the Flow-compatible dashboard JSON is included and referenced by the provisioning ConfigMap.

- T067 [US4] Generate a versioned topology ConfigMap from containerlab inspect and build a Grafana Flow-compatible physical-fabric view with nodes, links, labels, status, rate, and utilization matching Prometheus and live inventory
  - The topology ConfigMap exists and is versioned, but it appears static; there is no evidence it is generated from containerlab inspect output. Provide the generation script and a proof artifact tying it to containerlab inspect (e.g., the inspect JSON and a generated hash/content match).
  - A Grafana Flow-compatible physical-fabric dashboard is missing. Evidence mentions physical-fabric.json, but it is not in the snapshot. Add the Flow-compatible dashboard JSON (nodes/links layered with rate/utilization and status) and a provisioning reference under grafana-provisioning.
  - The topology/dashboards must include explicit status metric mappings (up/sonic state) in addition to rate/utilization; add and prove those mappings exist.

- T068 [US4] Build orchestration and service-path panels for SDC and the active SRv6 primary/alternate SID path with annotations
  - sdc-orchestration.json covers SDC and provider panels, but the SRv6 service-path dashboard (srv6-service-path.json) is missing. Add it with active primary/alternate SID path visualization, endpoint/behavior annotations, and MySID counters, and provide proof slices.

VERDICT c175bad1b96c8bef: REJECTED



---
## Grounding transparency (machine-generated — read this)
These files you cited EXIST on disk, but the critic's grounding extractor could not include them in its snapshot, so the critic cannot 'see' their contents. This is a TOOLING limitation, NOT a missing file. Do NOT re-create, copy, or promote them — they are already present and correct. If a criterion depends on one, either cite it a different way (e.g. a slash path like `./versions.lock.yaml`) or state in your evidence that grounding cannot reach it:
- `versions.lock.yaml`
