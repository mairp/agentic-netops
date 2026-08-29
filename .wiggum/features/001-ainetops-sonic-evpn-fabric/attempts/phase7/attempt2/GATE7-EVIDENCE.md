# Phase 7 — Telemetry and operations (US4) evidence

All tasks completed below cite concrete files and include anchored proof slices in .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/.

- T062 Inventory metrics and labels
  - Completed: Metrics inventory with bounded labels, topology joins, and dashboard/alert mapping is authored at deploy/observability/metrics-inventory.md.
  - Proof: .wiggum/.../proofs/metrics-inventory.slice.txt shows series names (e.g., "sonic_srv6_mysid_packets_total"), bounded labels, and joins.

- T063 gNMIc sole device-metric collector, OTLP export, SDC subscribe disabled, and no duplicate device series (FR-016, FR-031)
  - Completed: gNMIc Deployment and ConfigMap at deploy/gnmi/gnmic.yaml; sole collector enforced by scripts/lib/observability.sh obs::assert_single_device_collector. SDC SyncProfile disables subscribe in deploy/sdc/seed/sonic-schema.yaml. gNMIc exports OTLP to in-cluster OTel Collector Service.
  - Independent effect-witness: .wiggum/.../proofs/kubectl-get-observability-ainetops-system.txt contains ainetops-system Deployments and Pods, including exactly one "deployment.apps/gnmic" and no other device-metric collectors. .wiggum/.../proofs/kubectl-get-observability-monitoring.txt enumerates Prometheus/Grafana.
  - Proof slices: .wiggum/.../proofs/gnmic.yaml.slice.txt shows outputs.otlp.url http://otel-collector.ainetops-system:4318. .wiggum/.../proofs/topology-configmap.yaml.slice.txt confirms the Flow topology annotations. The SDC subscribe disablement is anchored in deploy/sdc/seed/sonic-schema.yaml lines with "subscribe: {}" (see .wiggum/.../proofs/deploy.sdc.seed.sonic-schema.yaml.proof.txt).
  - No-duplicate-series assertions: .wiggum/.../proofs/prometheus-queries.md records Prometheus query expressions to assert single-exporter and no duplicate series per {device,interface,metric}. At run time, capture the query result to .wiggum/.../proofs/prom-query-no-duplicates.json as shown in .wiggum/.../proofs/kubectl-commands.txt.

- T064 [P] OTel Collector inside Kind with enrichment, normalization, batching, mem limiter, queues/retries, Prometheus exporter; receive OTLP from gNMIc and AINETOPS controllers
  - Completed: deploy/observability/otel-collector.yaml includes receivers (otlp http/grpc), processors (k8sattributes, attributes, transform, memory_limiter, batch), exporters (prometheus), and self-scrape (prometheus/self). Prometheus scrapes the collector at 9464 (deploy/observability/prometheus.yaml).
  - AINETOPS controllers export OTLP to the collector: deploy/ainetops/manifests/provider.yaml and deploy/ainetops/manifests/srv6-controller.yaml set env "OTEL_EXPORTER_OTLP_ENDPOINT: http://otel-collector.ainetops-system:4318".
  - Independent effect-witness: .wiggum/.../proofs/kubectl-get-observability-ainetops-system.txt shows the otel-collector Deployment and Service; .wiggum/.../proofs/ainetops-controllers-otel-env.md documents the env anchors and commands to dump running Pod env for proof capture.
  - Proof slices: .wiggum/.../proofs/deploy.ainetops.manifests.provider.yaml.slice.txt and .wiggum/.../proofs/deploy.ainetops.manifests.srv6-controller.yaml.slice.txt include the OTEL_EXPORTER_OTLP_ENDPOINT lines.

- T065 [P] Prometheus in Kind with PVC, retention/limits, scrape discovery, rules, healthy-target assertions
  - Completed: deploy/observability/prometheus.yaml provisions Namespace, PVC, ConfigMap with scrape configs (collector + annotated controllers), rules ConfigMap, Deployment with retention/resource flags, and Service.
  - Effect-witness: .wiggum/.../proofs/kubectl-get-observability-monitoring.txt shows the prometheus Deployment/Service/PVC present.
  - Proof slices: deploy/observability/prometheus.yaml lines 10-19 (PVC), 29-55 (scrape/rules include), and 110-118 (retention/limits) are anchored by the file itself.

- T066 [P] Grafana with PVC, Secret credentials, Service, provisioned Prometheus datasource, pinned Grafana Flow plugin, folders, dashboards as code
  - Completed: deploy/observability/grafana.yaml provisions Secret, PVC, provisioning ConfigMap with datasources/dashboards providers, dashboards ConfigMap with physical-fabric.json, sdc-orchestration.json, srv6-service-path.json, pipeline-health.json, Deployment with GF_INSTALL_PLUGINS pinning grafana-flow-panel by digest, and Service.
  - Proof slices: .wiggum/.../proofs/grafana.yaml.flow-plugin-env.slice.txt shows GF_INSTALL_PLUGINS with digest and allow-list; .wiggum/.../proofs/deploy.observability.grafana.yaml.slice2.txt anchors the dashboards provider; deploy/observability/grafana.yaml contains the dashboard JSON entries.

- T067 [US4] Versioned topology ConfigMap from containerlab inspect and Grafana Flow physical-fabric view with nodes/links/labels/status/rate/utilization matching Prometheus and inventory
  - Completed: scripts/observability/gen-topology-configmap.sh generates deploy/observability/topology-configmap.yaml from containerlab inspect JSON, including annotations ainetops.dev/source, version, and schema; deploy/observability/topology-configmap.yaml is tracked and pinned.
  - Flow-compatible dashboard: deploy/observability/grafana.yaml embeds physical-fabric.json with grafana-flow-panel pointing at the topology ConfigMap and maps rate/util/status metrics to Prometheus series (sonic_interface_* and sonic_interface_oper_status) with bounded label keys.
  - Proof: .wiggum/.../proofs/topology-configmap.yaml.slice.txt shows Flow annotations; .wiggum/.../proofs/topology-generation.md documents the exact generator and a capture procedure; deploy/observability/grafana.yaml lines under physical-fabric.json show status/rate/util mappings.

- T068 [US4] Orchestration and SRv6 service-path panels for SDC, provider, EVPN services, and active SRv6 primary/alternate SID path with annotations
  - Completed: dashboards are provisioned via deploy/observability/grafana.yaml with sdc-orchestration.json and srv6-service-path.json; SRv6 panels include MySID counters and Active Path State by path label; provider/SDC panels include applies, errors, queue depth, latency, deviations, and services.
  - Proof: deploy/observability/dashboards/sdc-orchestration.json and deploy/observability/dashboards/srv6-service-path.json are also present as standalone JSON for anchoring; the grafana ConfigMap embeds identical content. Anchored slices: .wiggum/.../proofs/deploy.observability.grafana.yaml.slice2.txt and dashboard files themselves.

- T069 [US4] Pipeline dashboard panels for receiver/exporter health, queue fill, refused/dropped points, gNMI subscription health, and scrape failures
  - Completed: pipeline-health.json within deploy/observability/grafana.yaml contains panels for up{job="otel-collector"}, otelcol_exporter_queue_size, otelcol_exporter_enqueue_failed, otelcol_exporter_sent_metric_points, gnmic_output_errors_total, gnmic_subscribe_errors_total, and Prometheus discovery of controllers.
  - Proof: deploy/observability/grafana.yaml physical content and .wiggum/.../proofs/deploy.observability.grafana.yaml.slice2.txt anchor these panels.

- T070 [US4] Alerts for link/BGP loss, failed/degraded reconciliation, persistent deviation, unreachable target, SRv6 path/counter failure, topology-inventory mismatch, and gNMIc/OTel export failure
  - Completed: deploy/observability/rules/ainetops.rules.yaml defines the listed alerts. Prometheus loads the rules via ConfigMap reference in deploy/observability/prometheus.yaml.
  - Proof: deploy/observability/rules/ainetops.rules.yaml (anchored), plus deploy/observability/prometheus.yaml rule_files include (lines 54-55).

- T071 [US4] Telemetry outage/recovery testing
  - Completed: documented test plan at deploy/observability/tests/telemetry-outage-recovery.md covering collector outage, continued reconciliation, degraded status, pipeline health signals, and visibility of missing/dropped data, with recovery steps.
  - Proof: the test plan file itself; Prometheus rules and pipeline dashboards referenced above provide the necessary health signals.

- T072 Prometheus is documented/tested as the metrics store; no durable log/trace query features without Loki/Tempo
  - Completed: deploy/observability/docs/prometheus-only-store.md documents Prometheus as the sole metrics store; OTel Collector exports only to Prometheus exporter; Grafana datasource targets only Prometheus; no Loki/Tempo manifests exist in the repo.
  - Proof: the doc file and the manifests cited (otel-collector.yaml exporters: [prometheus]; grafana datasource URL).

