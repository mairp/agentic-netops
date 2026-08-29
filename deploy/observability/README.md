# Observability stack (Phase 7)

This folder contains Kubernetes manifests for the Phase 7 observability stack:
- gNMIc inside Kind as the sole SONiC device-metric collector exporting OTLP to OTel Collector.
- OpenTelemetry Collector with OTLP receivers, Kubernetes enrichment, normalization, batching, memory limiter, queues/retries and a Prometheus exporter, including its own telemetry.
- Prometheus with a PVC, pinned retention/resource limits, scrape discovery, and health rules.
- Grafana with a PVC, Secret-based credentials, Service, a provisioned Prometheus datasource, and dashboards as code. The Grafana Flow plugin is pinned in versions.lock.yaml and installed via GF_INSTALL_PLUGINS with digest grafana-flow-panel@sha256:5c9d6b4d6b899be4a3f3c728b3acb0a8f8c3e6a46c9f5b07d705e8ca3c1a2c44.

The manifests are applied by scripts/lib/observability.sh and wired into scripts/provision.sh.

Prometheus is the only metrics store; no durable log or trace query components are deployed (Tempo/Loki are intentionally absent).
