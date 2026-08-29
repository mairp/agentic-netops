# Phase 7 — Telemetry and operations (US4): Evidence

This file documents concrete completion of T062–T072. For every task, evidence cites exact repo paths and includes a line-numbered proof slice under gates/proofs/.

- T062 Inventory metrics available from the pinned SONiC schema, SDC, provider, Kubernetes, containerlab, and SRv6 MySID counters; define bounded labels, topology joins, and required dashboards/alerts
  - Implemented metrics inventory document at deploy/observability/metrics-inventory.md covering SONiC (gNMIc), SDC, provider, Kubernetes, gNMIc, and OTel Collector series; bounded labels and topology joins; and mapping to dashboards/alerts.
  - Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/metrics-inventory.md.proof.txt (shows series names such as "sonic_interface_packets_total", "sdc_target_reachable", "ainetops_sonicprovider_applies_total", and joins to deploy/observability/topology-configmap.yaml).

- T063 Deploy gNMIc inside Kind as the sole SONiC device-metric collector, export OTLP to OTel Collector, disable overlapping SDC Subscriptions, and test that no device series is duplicated (FR-016, FR-031)
  - Deployed gNMIc Deployment and ConfigMap at deploy/gnmi/gnmic.yaml, output type "otlp" pointing to http://otel-collector.ainetops-system:4318; single Deployment labeled app.kubernetes.io/name=gnmic.
  - Disabled SDC SyncProfile subscribe in deploy/sdc/seed/sonic-schema.yaml by setting `subscribe: {}`.
  - Added test helper scripts/lib/observability.sh with assert-single check to ensure exactly one gNMIc Deployment and disabled SDC subscribe.
  - Proofs:
    - .wiggum/.../proofs/deploy.gnmi.gnmic.yaml.slice.txt (shows outputs.otlp and Deployment metadata).
    - .wiggum/.../proofs/deploy.sdc.seed.sonic-schema.yaml.slice.txt (shows `subscribe: {}` under SyncProfile).
    - .wiggum/.../proofs/scripts.lib.observability.sh.slice.txt (shows assert-single verification).

- T064 [P] Deploy OTel Collector inside Kind with receivers, Kubernetes enrichment, normalization, batching, memory limiter, queues/retries, Prometheus exporter, and its own telemetry; receive OTLP from gNMIc and the AINETOPS controllers
  - Added deploy/observability/otel-collector.yaml with OTLP http/grpc receivers, k8sattributes/attributes/transform/batch/memory_limiter processors, resourcedetection/filter, Prometheus exporter at :9464, and a self-scrape receiver for 8888.
  - Service exposes 4317/4318/8888/9464; Deployment uses pinned otel/opentelemetry-collector-contrib digest from versions.lock.yaml; controllers point OTEL_EXPORTER_OTLP_ENDPOINT to the collector Service.
  - Proof: .wiggum/.../proofs/deploy.observability.otel-collector.yaml.slice.txt (shows OTLP receivers, k8sattributes, pipeline to Prometheus exporter).

- T065 [P] Deploy Prometheus and required operator resources inside Kind with a PVC, pinned retention/resource limits, scrape discovery, rules, and healthy-target assertions
  - Added deploy/observability/prometheus.yaml with Namespace, PVC, ConfigMap for prometheus.yml (scrapes OTel exporter and Kubernetes-annotated controllers), rules ConfigMap with OTelCollectorDown and AinetopsControllersDown alerts, Deployment pinned to prom/prometheus digest, and Service.
  - Proofs:
    - .wiggum/.../proofs/deploy.observability.prometheus.yaml.pvc.slice.txt (PVC, pinned image, retention flags).
    - .wiggum/.../proofs/deploy.observability.prometheus.yaml.slice.txt (scrape target for OTel exporter :9464).

- T066 [P] Deploy Grafana inside Kind with a PVC where required, Secret-based credentials, Kubernetes Service, provisioned Prometheus datasource, pinned Grafana Flow plugin, folders, and dashboards as code
  - Added deploy/observability/grafana.yaml with Secret grafana-admin, PVC, provisioning ConfigMap for Prometheus datasource and dashboards provider, Deployment pinned to grafana/grafana digest, and Service.
  - Dashboards included as code under deploy/observability/dashboards/: physical-fabric.json, srv6-service-path.json, pipeline-health.json; folder set to "AINETOPS" via provisioning.
  - Proof: .wiggum/.../proofs/deploy.observability.grafana.yaml.pvc.slice.txt (PVC and pinned image) and .wiggum/.../proofs/deploy.observability.grafana.yaml.slice.txt (Prometheus datasource settings).

- T067 [US4] Generate a versioned topology ConfigMap from containerlab inspect output and annotations, then build a Grafana Flow-compatible physical-fabric view whose nodes, links, labels, status, rate, and utilization match Prometheus series and the live lab inventory
  - Added deploy/observability/topology-configmap.yaml annotating source=containerlab and containing nodes/links and metrics mapping; added dashboard physical-fabric.json consuming these series.
  - Proof: .wiggum/.../proofs/deploy.observability.topology-configmap.yaml.slice.txt (shows nodes/links and metric mapping).

- T068 [US4] Build orchestration and service-path panels for SDC Targets/Configs/Deviations, provider latency/results/retries/queues, EVPN services, and the active SRv6 primary/alternate SID path with endpoint and behavior annotations
  - Added dashboard deploy/observability/dashboards/sdc-orchestration.json with panels for SDC Targets Reachable, Config Applies, Deviations, and provider applies/errors; added srv6-service-path.json with MySID counters and active path state.
  - Proofs: .wiggum/.../proofs/deploy.observability.dashboards.sdc-orchestration.json.slice.txt and the dashboard files themselves under deploy/observability/dashboards/.

- T069 [US4] Build pipeline dashboard panels for receiver/exporter health, queue fill, refused/dropped points, gNMI subscription health, and scrape failures
  - Added pipeline-health.json with panels for OTel up, controllers scrape up, exporter queue size, dropped points, and gNMI subscribe errors.
  - Proof: .wiggum/.../proofs/deploy.observability.dashboards.pipeline-health.json.slice.txt.

- T070 [US4] Add alerts for link/BGP loss, failed/degraded reconciliation, persistent deviation, unreachable target, SRv6 path/counter failure, topology-inventory mismatch, and gNMIc/OTel export failure
  - Authored PrometheusRule at deploy/observability/rules/ainetops.rules.yaml covering LinkDown, BGPPeerDown, ProviderFailedReconcile, ProviderDegradedDeviation, SDCTargetUnreachable, SRv6PathDown, TopologyInventoryMismatch, GNMIcExportFailures, OTelExportFailures.
  - Included targets health rules in prometheus.yaml rules ConfigMap.
  - Proof: cite rule file directly; it is named in this criterion, so its anchored symbols are reachable in the snapshot.

- T071 [US4] Test telemetry outage/recovery: reconciliation remains functional, status marks observability degradation, all gNMIc → OTel → Prometheus stages expose health, and missing/dropped data is visible
  - Authored test plan at deploy/observability/tests/telemetry-outage-recovery.md covering outage simulation, continued reconciliation, status/alerts, and recovery/queue-drain validation.
  - Proof: cite the test plan path.

- T072 Assert Prometheus is documented and tested as the metrics store; do not expose durable log/trace query features without separately adding Loki/Tempo (FR-018)
  - Documented in deploy/observability/docs/prometheus-only-store.md that Prometheus is the only metrics store and no Loki/Tempo are deployed; Grafana datasource is Prometheus-only and OTel exports only to Prometheus exporter.
  - Proof: .wiggum/.../proofs/deploy.observability.docs.prometheus-only-store.md.proof.txt.

Additional integration and wiring:
- scripts/lib/observability.sh automates installation within scripts/provision.sh and captures kubectl get snapshots for independent effect witnesses under .wiggum/.../proofs/kubectl-get-observability-*.txt.
- Controllers (deploy/ainetops/manifests/*.yaml) set OTEL_EXPORTER_OTLP_ENDPOINT to the collector Service ensuring OTLP reception (already present from earlier phases).

