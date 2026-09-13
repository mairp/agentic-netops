# Observability stack

Kubernetes manifests for the metrics pipeline of the Nokia SR Linux lab:

- **gNMIc** inside kind as the sole device-metric collector. It subscribes to
  SR Linux native gNMI state paths on `172.31.0.x:57400` over TLS (the
  containerlab CA and the generated `agentic` user) and serves them on its own
  Prometheus endpoint `:9273/metrics`, which Prometheus scrapes directly. The
  manifest lives in `deploy/gnmi/gnmic.yaml`; the subscriptions are specified in
  `specs/001-agentic-netops-srlinux-evpn-fabric/contracts/telemetry.md`.
- **OpenTelemetry Collector** with OTLP receivers, Kubernetes enrichment,
  normalization, batching, memory limiter, queues/retries and a Prometheus
  exporter, including its own telemetry. It is kept for the pipeline-health
  signals and for non-device sources; the device path from gnmic to Prometheus
  is direct, because the OTLP hop silently discarded every sample in the
  previous generation (gnmic's `otlp` output takes `endpoint`, not `url`).
- **Prometheus** with a PVC, pinned retention/resource limits, scrape discovery
  and health rules.
- **Grafana** with a PVC, Secret-based credentials, Service, a provisioned
  Prometheus datasource and dashboards as code (built-in panels only; no
  third-party plugin install). The upstream Grafana Flow visualization remains
  recorded in `versions.lock.yaml` as a presentation reference — it is not
  installed in the lab Grafana.

The manifests are applied by `scripts/lib/observability.sh` and wired into
`scripts/provision.sh`.

Prometheus is the only metrics store; no durable log or trace query components
are deployed (Tempo/Loki are intentionally absent).

The series each dashboard queries, their labels and the live-verification
command are listed in `metrics-inventory.md`. Those names follow the telemetry
contract and have **not** yet been read off a running SR Linux node — the
SR Linux walkthrough has not been recorded. Phase 4 of
`specs/001-agentic-netops-srlinux-evpn-fabric/tasks.md` is where they are
confirmed and the dashboard screenshots under `docs/images/` are refreshed.
