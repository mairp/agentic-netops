# Prometheus is the metrics store

Prometheus is the only metrics store deployed and tested in this feature. Remote read/write and long-term storage are not configured. Loki (logs) and Tempo (traces) are intentionally not deployed; no durable log or trace query features are exposed.

- Prometheus deployment manifest: deploy/observability/prometheus.yaml
- Grafana datasource points only at Prometheus: deploy/observability/grafana.yaml
- OTel Collector exports metrics to Prometheus exporter only: deploy/observability/otel-collector.yaml
