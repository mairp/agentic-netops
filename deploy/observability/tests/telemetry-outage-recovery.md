# Telemetry outage/recovery test plan

- Simulate OTel Collector outage by scaling deployment to 0; verify:
  - Provider and SDC reconciliation continue to function (no dependency on collector health for device state).
  - Status conditions mark observability degradation (e.g., Prometheus alert OTelCollectorDown fired).
  - gNMIc -> OTel -> Prometheus pipeline stages expose health: up{job="otel-collector"} goes 0; otelcol_exporter_queue_size increases; gnmic_output_errors_total increments.
  - Missing/dropped data is visible via Grafana pipeline-health dashboard and Prometheus rules.
- Recover by scaling OTel Collector back to 1; verify alerts resolve and queues drain.

This plan can be executed with kubectl and observed via Prometheus/Grafana dashboards once the stack is deployed.
