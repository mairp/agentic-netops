# deploy/gnmi

gNMI collection and reachability proofs for the Nokia SR Linux fabric.

- `gnmic.yaml` — the in-cluster gNMIc collector (ConfigMap, Deployment,
  Service). It subscribes to SR Linux native state paths on `:57400` over TLS
  and exposes them on its own Prometheus endpoint `:9273/metrics`, which
  Prometheus scrapes directly. Subscriptions and the series they emit are
  specified in
  `specs/001-agentic-netops-srlinux-evpn-fabric/contracts/telemetry.md`
  and listed in `deploy/observability/metrics-inventory.md`.
- `gnmi-incluster-job.yaml` / `gnmi-incluster-job-all.yaml` — Jobs that run
  gNMI Capabilities from inside the pod network against the SR Linux
  management addresses, proving reachability over the dedicated Docker
  management network rather than from the host.
- `apply-job.sh` / `apply-job-all.sh` — apply the Jobs and capture their logs
  as gate proofs.
- `gnmic-tls-configmap.yaml` — the TLS path references consumed by the
  collector.

Targets: `172.31.0.11:57400` (spine01), `.12` (spine02), `.21` (leaf01),
`.22` (leaf02).

Secrets `gnmi-lab-creds` (user `agentic` and its generated password) and
`gnmi-lab-tls` (the containerlab CA as `ca.crt`) are created by lab bootstrap
inside Kubernetes, not as host files, and are never committed.
