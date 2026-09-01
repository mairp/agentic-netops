# Observability stack (Phase 7)

This folder contains Kubernetes manifests for the Phase 7 observability stack:
- gNMIc inside Kind as the sole SONiC device-metric collector exporting OTLP to OTel Collector.
- OpenTelemetry Collector with OTLP receivers, Kubernetes enrichment, normalization, batching, memory limiter, queues/retries and a Prometheus exporter, including its own telemetry.
- Prometheus with a PVC, pinned retention/resource limits, scrape discovery, and health rules.
- Grafana with a PVC, Secret-based credentials, Service, a provisioned Prometheus datasource, and dashboards as code (built-in panels only; no third-party plugin install). The upstream Grafana Flow visualization remains recorded in versions.lock.yaml as a presentation reference (FR-032) — it is not installed in the lab Grafana.

The manifests are applied by scripts/lib/observability.sh and wired into scripts/provision.sh.

Prometheus is the only metrics store; no durable log or trace query components are deployed (Tempo/Loki are intentionally absent).
