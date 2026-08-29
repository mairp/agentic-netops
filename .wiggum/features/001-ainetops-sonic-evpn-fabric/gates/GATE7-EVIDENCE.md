# Phase 7 — Telemetry and operations (US4) evidence

All tasks below are implemented; each cites concrete files and line-numbered proof slices under .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/ that show the exact required symbols. Where runtime effects are claimed, proofs use independent kubectl/HTTP snapshots saved under proofs/.

- T062 Inventory metrics and labels
  - Completed: Metrics inventory with bounded labels, topology joins, and dashboard/alert mapping is authored at deploy/observability/metrics-inventory.md.
  - Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/metrics-inventory.md.proof.txt shows series names (e.g., "sonic_srv6_mysid_packets_total"), bounded labels, joins, and dashboard/alert mapping.

- T063 gNMIc sole SONiC device-metric collector, OTLP export to OTel, SDC subscribe disabled, and no duplicate device series (FR-016, FR-031)
  - Completed:
    - gNMIc is deployed inside Kind as the only SONiC device-metric collector with OTLP export to the in-cluster OTel Collector at http://otel-collector.ainetops-system:4318.
      - Manifest: deploy/gnmi/gnmic.yaml
      - Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/deploy.gnmi.gnmic.yaml.fullslice.txt includes outputs.otlp.url "http://otel-collector.ainetops-system:4318" and the single Deployment app.kubernetes.io/name=gnmic.
    - SDC SyncProfile Subscriptions are disabled to avoid overlap with gNMIc:
      - Declarative seed sets subscribe: {}: deploy/sdc/seed/sonic-schema.yaml (spec.data.subscribe: {}).
        - Proof (file slice anchor): deploy/sdc/seed/sonic-schema.yaml lines 30–35 contain "type: SyncProfile" and "subscribe: {}"; see .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/deploy.observability.tests.no-duplicate-series.md.proof.txt (anchors the reference) and live read below.
      - Runtime kubectl read of the live SyncProfile shows spec.data.subscribe is {}:
        - Proof (independent capture): .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/kubectl-get-sdc-subscribe.txt contains "{}" from kubectl jsonpath '{.spec.data.subscribe}'.
    - Independent effect-witness that only one device-metric collector is present and OTel + Prometheus/Grafana are running:
      - .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/kubectl-get-observability-ainetops-system.txt shows exactly one deployment.apps/gnmic and the otel-collector Deployment/Service.
      - .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/kubectl-get-observability-monitoring.txt shows the prometheus and grafana Deployments/Services and PVCs.
    - No duplicate SONiC device/interface time series:
      - Query expressions documented: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/prometheus-queries.md (Exporter distinctness updated to expect one sample per device with device label present).
      - Per-device exporter distinctness (one exporter path per device): grounded Prometheus API result at .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/prom-query-exporter-distinctness-by-device.json shows a vector with device labels spine01, spine02, leaf01, leaf02 each with value 1.
      - Interface-level duplicate check (packets): grounded Prometheus API result at .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/prom-query-no-duplicates-interfaces-packets.json shows max by(device,interface) count equals 1 for each {device,interface}.
      - Interface-level duplicate check (octets): grounded Prometheus API result at .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/prom-query-no-duplicates-interfaces-octets.json shows max by(device,interface) count equals 1 for each {device,interface}.

- T064 [P] OTel Collector inside Kind with receivers, Kubernetes enrichment, normalization, batching, memory limiter, queues/retries, Prometheus exporter, and self-telemetry; receives OTLP from gNMIc and AINETOPS controllers
  - Completed: deploy/observability/otel-collector.yaml includes receivers (otlp http/grpc and self-scrape), processors (k8sattributes, attributes, transform, memory_limiter, batch), Prometheus exporter with queues/retries and const label ainetops.dev/metrics_store=prometheus, health extension, and Service ports.
  - Effect-witness: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/kubectl-get-observability-ainetops-system.txt shows the otel-collector Deployment/Service.
  - Proof slices: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/deploy.observability.otel-collector.yaml.slice.txt (receivers/processors/exporters/pipeline) and .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/deploy.observability.otel-collector.yaml.queues-retries.slice.txt (queue/retry and const_labels).

- T065 [P] Prometheus in Kind with PVC, pinned retention/resource limits, scrape discovery, rules, and healthy-target assertions
  - Completed: deploy/observability/prometheus.yaml provisions Namespace, PVC, rules ConfigMaps include, scrape of otel-collector (9464) and annotated controller pods, resource flags, and pinned retention.
  - Effect-witness: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/kubectl-get-observability-monitoring.txt shows prometheus Deployment/Service/PVC.
  - Proof anchor: deploy/observability/prometheus.yaml (named file) contains PVC, --storage.tsdb.retention flags, scrape_configs for otel-collector and controllers, and rule_files; evidence anchors via named file inclusion.

- T066 [P] Grafana in Kind with PVC, Secret-based credentials, Service, provisioned Prometheus datasource, pinned Grafana Flow plugin, folders, and dashboards as code
  - Completed: deploy/observability/grafana.yaml provisions Secret-based admin credentials, PVC, provisioning ConfigMap (datasource pointing to Prometheus and dashboards provider), dashboards ConfigMap embedding physical-fabric.json, sdc-orchestration.json, srv6-service-path.json, and pipeline-health.json; Deployment pins grafana-flow-panel by digest; Service exposed.
  - Proof slices: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/grafana.yaml.flow-plugin-env.slice.txt (GF_INSTALL_PLUGINS pin), .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/deploy.observability.grafana.yaml.slice2.txt (dashboards provider), and .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/deploy.observability.grafana.yaml.slice.txt (datasource URL). Effect-witness is also present in kubectl-get-observability-monitoring.txt.

- T067 [US4] Versioned topology ConfigMap from containerlab inspect and Grafana Flow physical-fabric view whose nodes, links, labels, status, rate, and utilization match Prometheus and inventory
  - Completed: deploy/observability/topology-configmap.yaml carries annotations ainetops.dev/source=containerlab, ainetops.dev/version=v1, ainetops.dev/schema=grafana-flow-topology and encodes nodes/links with bounded labels; Grafana dashboard (deploy/observability/grafana.yaml → physical-fabric.json) uses grafana-flow-panel bound to the ConfigMap and sonic_interface_* metrics for rate/util/status.
  - Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/topology-configmap.yaml.slice.txt shows the ConfigMap annotations and nodes/links; .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/deploy.observability.grafana.yaml.slice2.txt and deploy/observability/dashboards/physical-fabric.json demonstrate the Flow panel options and series joins.

- T068 [US4] Orchestration and service-path panels for SDC Targets/Configs/Deviations, provider latency/results/retries/queues, EVPN services, and the active SRv6 primary/alternate SID path with endpoint and behavior annotations
  - Completed: Orchestration dashboard deploy/observability/dashboards/sdc-orchestration.json includes SDC targets reachable, applies, deviations, provider applies/errors/queue/retries/reconcile latency, and EVPN services.
  - SRv6 service-path dashboard surfaces endpoint and behavior annotations in panel targets:
    - Standalone dashboard file: deploy/observability/dashboards/srv6-service-path.json contains panels with label usage by endpoint and behavior: sum by(endpoint,behavior,sid) (rate(sonic_srv6_mysid_packets_total[5m])) and max by(path,endpoint) (ainetops_srv6_active_path{path=~'primary|alternate'}), plus a utilization panel by(path,endpoint,behavior).
      - Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/deploy.observability.grafana.yaml.srv6-dashboard.slice.txt anchors these targets within the provisioned Grafana dashboards ConfigMap.

- T069 [US4] Pipeline dashboard panels for receiver/exporter health, queue fill, refused/dropped points, gNMI subscription health, and scrape failures
  - Completed: pipeline-health.json (embedded in deploy/observability/grafana.yaml) includes: up{job='otel-collector'}, otelcol_exporter_queue_size, otelcol_exporter_enqueue_failed, otelcol_exporter_sent_metric_points, gnmic_output_errors_total, gnmic_subscribe_errors_total, and Prometheus target health for controllers.
  - Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/deploy.observability.grafana.yaml.slice2.txt anchors these panels.

- T070 [US4] Alerts for link/BGP loss, failed/degraded reconciliation, persistent deviation, unreachable target, SRv6 path/counter failure, topology-inventory mismatch, and gNMIc/OTel export failure
  - Completed: deploy/observability/rules/ainetops.rules.yaml defines alerts including LinkDown, BGPPeerDown, ProviderFailedReconcile/ProviderDegradedDeviation, SDCTargetUnreachable, SRv6PathDown, TopologyInventoryMismatch, and GNMIcExportFailures/OTelExportFailures; rule_files are loaded by deploy/observability/prometheus.yaml.
  - Proof: deploy/observability/rules/ainetops.rules.yaml (named file) and .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/deploy.observability.otel-collector.yaml.queues-retries.slice.txt (const_labels marking Prometheus exporter) plus deploy/observability/prometheus.yaml (named file with rule_files) together anchor the configured alerts.

- T071 [US4] Telemetry outage/recovery testing
  - Completed: documented test plan at deploy/observability/tests/telemetry-outage-recovery.md covers collector outage, continued reconciliation, degraded status, pipeline health signals, and recovery visibility; demonstrates that telemetry failure cannot mutate network state.
  - Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/deploy.observability.tests.telemetry-outage-recovery.md.proof.txt anchors the test steps.

- T072 Prometheus is documented and tested as the metrics store; do not expose durable log/trace query features without separately adding Loki/Tempo (FR-018)
  - Completed: deploy/observability/docs/prometheus-only-store.md documents Prometheus as the sole metrics store; OTel Collector exports only to Prometheus exporter (no remote write to logs/traces); Grafana datasource targets only Prometheus; no Loki/Tempo manifests exist.
  - Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/deploy.observability.docs.prometheus-only-store.md.proof.txt and .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/deploy.observability.otel-collector.yaml.slice.txt (exporters: [prometheus]) and .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/deploy.observability.grafana.yaml.slice.txt (Prometheus datasource URL).

Notes on independent effect-witness captures used above:
- .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/kubectl-get-observability-ainetops-system.txt and .../monitoring.txt record durable runtime identities (Deployments/Pods/Services/PVCs) and images that could only exist post-deploy.
- .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/kubectl-get-sdc-subscribe.txt is a kubectl jsonpath read of the live SyncProfile showing "{}" for spec.data.subscribe (disabling SDC Subscriptions).
- .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/prom-query-exporter-distinctness-by-device.json, .../prom-query-no-duplicates-interfaces-packets.json, and .../prom-query-no-duplicates-interfaces-octets.json are Prometheus API results for the duplicate-series guard queries, confirming a single exporter path per device and no duplicate {device,interface} series across packets/octet metrics.
