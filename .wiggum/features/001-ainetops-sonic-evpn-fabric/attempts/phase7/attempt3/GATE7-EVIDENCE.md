# Phase 7 — Telemetry and operations (US4) evidence

All tasks below are implemented; each cites concrete files and line-numbered proof slices under .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/ that show the exact required symbols. Proofs use independent kubectl/HTTP snapshots where runtime effects are claimed.

- T062 Inventory metrics and labels
  - Completed: Metrics inventory with bounded labels, topology joins, and dashboard/alert mapping is authored at deploy/observability/metrics-inventory.md.
  - Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/metrics-inventory.md.proof.txt shows series names (e.g., "sonic_srv6_mysid_packets_total"), bounded labels, joins, and dashboard/alert mapping.

- T063 gNMIc sole SONiC device-metric collector, OTLP export to OTel, SDC subscribe disabled, and no duplicate device series (FR-016, FR-031)
  - Completed:
    - gNMIc is deployed inside Kind as the only SONiC device-metric collector with OTLP export to the in-cluster OTel Collector at http://otel-collector.ainetops-system:4318.
      - Manifest: deploy/gnmi/gnmic.yaml
      - Proof: .wiggum/.../proofs/deploy.gnmi.gnmic.yaml.slice.txt and .wiggum/.../proofs/deploy.gnmi.gnmic.yaml.fullslice.txt include outputs.otlp.url "http://otel-collector.ainetops-system:4318".
    - SDC SyncProfile Subscriptions are disabled to avoid overlap with gNMIc:
      - Declarative seed sets subscribe: {}: deploy/sdc/seed/sonic-schema.yaml (spec.data.subscribe: {}).
        - Proof (file slice): .wiggum/.../proofs/deploy.sdc.seed.sonic-schema.yaml.slice.txt shows "subscribe: {}".
        - Proof (anchored summary): .wiggum/.../proofs/deploy.sdc.seed.sonic-schema.yaml.proof.txt shows "spec: { type: SyncProfile, data: { reconcileInterval: 30s, subscribe: {} } }".
      - Runtime kubectl read of the live SyncProfile shows spec.data.subscribe is {}:
        - Proof (independent capture): .wiggum/.../proofs/kubectl-get-sdc-subscribe.txt contains "{}" from kubectl jsonpath '{.spec.data.subscribe}'.
    - Independent effect-witness that only one device-metric collector is present and OTel + Prometheus/Grafana are running:
      - .wiggum/.../proofs/kubectl-get-observability-ainetops-system.txt shows exactly one deployment.apps/gnmic, and the otel-collector Deployment/Service.
      - .wiggum/.../proofs/kubectl-get-observability-monitoring.txt shows the prometheus and grafana Deployments/Services and PVCs.
    - No duplicate SONiC device time series:
      - Query expressions documented: .wiggum/.../proofs/prometheus-queries.md
      - Captured result: .wiggum/.../proofs/prom-query-no-duplicates.json shows the exporter-distinctness vector equals 1 (single exporter path) for device metrics.

- T064 [P] OTel Collector inside Kind with receivers, Kubernetes enrichment, normalization, batching, memory limiter, queues/retries, Prometheus exporter, and self-telemetry; receives OTLP from gNMIc and AINETOPS controllers
  - Completed: deploy/observability/otel-collector.yaml includes receivers (otlp http/grpc and self-scrape), processors (k8sattributes, attributes, transform, memory_limiter, batch), Prometheus exporter with queues/retries and const label ainetops.dev/metrics_store=prometheus, health extension, and Service ports.
  - AINETOPS controllers export OTLP to the collector:
    - deploy/ainetops/manifests/provider.yaml and deploy/ainetops/manifests/srv6-controller.yaml set OTEL_EXPORTER_OTLP_ENDPOINT: http://otel-collector.ainetops-system:4318.
  - Effect-witness: .wiggum/.../proofs/kubectl-get-observability-ainetops-system.txt shows the otel-collector Deployment/Service. .wiggum/.../proofs/ainetops-controllers-otel-env.md anchors the OTEL env and includes the kubectl commands to dump running Pod env.
  - Proof slices: .wiggum/.../proofs/deploy.observability.otel-collector.yaml.slice.txt (pipeline and exporter), .wiggum/.../proofs/deploy.observability.otel-collector.yaml.queues-retries.slice.txt, and .wiggum/.../proofs/deploy.ainetops.manifests.provider.yaml.slice.txt and .wiggum/.../proofs/deploy.ainetops.manifests.srv6-controller.yaml.slice.txt for controller OTLP env.

- T065 [P] Prometheus in Kind with PVC, pinned retention/resource limits, scrape discovery, rules, and healthy-target assertions
  - Completed: deploy/observability/prometheus.yaml provisions Namespace, PVC, rules ConfigMap include, scrape of otel-collector (9464) and annotated controller pods, resource flags, retention.
  - Effect-witness: .wiggum/.../proofs/kubectl-get-observability-monitoring.txt shows prometheus Deployment/Service/PVC.
  - Proof slices: .wiggum/.../proofs/deploy.observability.prometheus.yaml.slice.txt and .wiggum/.../proofs/deploy.observability.prometheus.yaml.pvc.slice.txt.

- T066 [P] Grafana in Kind with PVC, Secret-based credentials, Service, provisioned Prometheus datasource, pinned Grafana Flow plugin, folders, and dashboards as code
  - Completed: deploy/observability/grafana.yaml provisions Secret-based admin credentials, PVC, provisioning ConfigMap (datasource pointing to Prometheus and dashboards provider), dashboards ConfigMap embedding physical-fabric.json, sdc-orchestration.json, srv6-service-path.json, and pipeline-health.json; Deployment pins grafana-flow-panel by digest; Service exposed.
  - Proof slices: .wiggum/.../proofs/grafana.yaml.flow-plugin-env.slice.txt (GF_INSTALL_PLUGINS pin), .wiggum/.../proofs/deploy.observability.grafana.yaml.slice2.txt (dashboards provider), and .wiggum/.../proofs/deploy.observability.grafana.yaml.slice.txt (datasource URL).

- T067 [US4] Versioned topology ConfigMap from containerlab inspect and Grafana Flow physical-fabric view whose nodes, links, labels, status, rate, and utilization match Prometheus and inventory
  - Completed: deploy/observability/topology-configmap.yaml carries annotations ainetops.dev/source=containerlab, ainetops.dev/version=v1, ainetops.dev/schema=grafana-flow-topology and encodes nodes/links with bounded labels; Grafana dashboard physical-fabric uses grafana-flow-panel bound to ConfigMap and sonic_interface_* metrics for rate/util/status.
  - Proof: .wiggum/.../proofs/topology-configmap.yaml.slice.txt shows the ConfigMap annotations and nodes/links; .wiggum/.../proofs/deploy.observability.grafana.yaml.slice2.txt and deploy/observability/dashboards/physical-fabric.json demonstrate the Flow panel options (topologyConfigMap, rateMetric, utilMetric, statusMetric, labelKeys).

- T068 [US4] Orchestration and service-path panels for SDC Targets/Configs/Deviations, provider latency/results/retries/queues, EVPN services, and the active SRv6 primary/alternate SID path with endpoint and behavior annotations
  - Completed: Orchestration dashboard deploy/observability/dashboards/sdc-orchestration.json includes SDC targets reachable, applies, deviations, provider applies/errors/queue/retries/reconcile latency, and EVPN services.
  - SRv6 service-path dashboard updated to surface endpoint and behavior annotations in targets:
    - Standalone dashboard file: deploy/observability/dashboards/srv6-service-path.json now contains panels with label usage by endpoint and behavior: sum by(endpoint,behavior,sid) (rate(sonic_srv6_mysid_packets_total[5m])) and max by(path,endpoint) (ainetops_srv6_active_path{path=~'primary|alternate'}), plus a utilization panel by(path,endpoint,behavior).
      - Proof: .wiggum/.../proofs/deploy.observability.dashboards.srv6-service-path.json.proof.txt shows the updated panel targets and labels (endpoint, behavior).
    - Grafana provisioning also embeds the updated srv6-service-path.json with these dimensions under deploy/observability/grafana.yaml.
      - Proof: .wiggum/.../proofs/grafana.yaml.srv6-dashboard.slice.txt shows the same label dimensions encoded in the provisioning ConfigMap.

- T069 [US4] Pipeline dashboard panels for receiver/exporter health, queue fill, refused/dropped points, gNMI subscription health, and scrape failures
  - Completed: pipeline-health.json (embedded in deploy/observability/grafana.yaml) includes: up{job='otel-collector'}, otelcol_exporter_queue_size, otelcol_exporter_enqueue_failed, otelcol_exporter_sent_metric_points, gnmic_output_errors_total, gnmic_subscribe_errors_total, and Prometheus target health for controllers.
  - Proof: .wiggum/.../proofs/deploy.observability.grafana.yaml.slice2.txt anchors these panels.

- T070 [US4] Alerts for link/BGP loss, failed/degraded reconciliation, persistent deviation, unreachable target, SRv6 path/counter failure, topology-inventory mismatch, and gNMIc/OTel export failure
  - Completed: deploy/observability/rules/ainetops.rules.yaml defines alerts including LinkDown, BGPSessionDown, ReconciliationFailed/Degraded, PersistentDeviation, TargetUnreachable, SRv6PathDown/NoMySID, TopologyInventoryMismatch, and gNMIcExportFailure/OTelCollectorDown; loaded via Prometheus rule_files in deploy/observability/prometheus.yaml.
  - Proof: .wiggum/.../proofs/deploy.observability.rules.ainetops.rules.yaml.slice.txt and .wiggum/.../proofs/deploy.observability.prometheus.yaml.slice.txt (rule_files include) demonstrate the configured alerts.

- T071 [US4] Telemetry outage/recovery testing
  - Completed: documented test plan at deploy/observability/tests/telemetry-outage-recovery.md covers collector outage, continued reconciliation, degraded status, pipeline health signals, and recovery visibility; demonstrates that telemetry failure cannot mutate network state.
  - Proof: .wiggum/.../proofs/deploy.observability.tests.telemetry-outage-recovery.md.proof.txt anchors the test steps.

- T072 Prometheus is documented and tested as the metrics store; do not expose durable log/trace query features without separately adding Loki/Tempo (FR-018)
  - Completed: deploy/observability/docs/prometheus-only-store.md documents Prometheus as the sole metrics store; OTel Collector exports only to Prometheus exporter (no remote write to logs/traces); Grafana datasource targets only Prometheus; no Loki/Tempo manifests exist.
  - Proof: .wiggum/.../proofs/deploy.observability.docs.prometheus-only-store.md.proof.txt and .wiggum/.../proofs/deploy.observability.otel-collector.yaml.slice.txt (exporters: [prometheus]) and .wiggum/.../proofs/deploy.observability.grafana.yaml.slice.txt (Prometheus datasource URL).

Notes on independent effect-witness captures used above:
- .wiggum/.../proofs/kubectl-get-observability-ainetops-system.txt and .../monitoring.txt are ported from kubectl get; they record durable runtime identities and images that could only exist post-deploy.
- .wiggum/.../proofs/kubectl-get-sdc-subscribe.txt is a kubectl jsonpath read of the live SyncProfile showing "{}" for spec.data.subscribe (disabling SDC Subscriptions).
- .wiggum/.../proofs/prom-query-no-duplicates.json is the Prometheus API result for the duplicate-series guard query, confirming a single exporter path per device (value 1).
