# deploy/agents — intent-tier Kubernetes manifests

Kubernetes objects for the AGNTCY intent tier (namespace `agentic-netops-agents`).
The tier sits **above** the fabric control plane: no agent configures a
device, and every agent-originated change reaches the fabric only as a
declarative resource submitted to the cluster API.

## Contents (Phase 1)

- `namespace.yaml` — the `agentic-netops-agents` namespace.

The workload manifests (slim gateway, supervisor, mapper, allocator, deployer
with its translator sidecar, ui, otel collector, clickhouse, RBAC,
NetworkPolicies) land in later phases. The manifests follow the supervisor's
contract for the Kubernetes objects it submits.

## Telemetry (traces)

Each agent emits OTLP exactly once to the tier-owned `agent-otel-collector`
(research.md Decision 8), which is the single fan-out point with three sinks:

- `clickhouse` — the tier's `agent_analytics` store (traces + metrics).
- `otlp/feature001` — feature 001's collector (metrics only; its filter keeps
  `agentic_netops_agent_*` metrics into Prometheus).
- `otlphttp/phoenix` — **traces only**, to the host-side
  `mairp/agent-observability-stack` collector (Arize Phoenix trace backend).
  Endpoint comes from `AOS_OTLP_HTTP_ENDPOINT` (lab default
  `http://172.17.0.1:4318`, the docker bridge gateway from inside kind).
  Traces appear in Phoenix (UI host `:3006`) as one project per
  `service.name` — `intent-supervisor`, `intent-mapper`, `intent-allocator`,
  `intent-deployer` — though A2A round-trips propagate W3C context, so a
  request's full trace (client + remote agent spans) files under the
  supervisor's project. The spans are OpenInference-native (ioa-observe is a
  rebranded Traceloop SDK): the supervisor's `ChatLiteLLM.chat` spans carry
  full prompt/completion content plus token counts, and the AOS collector
  maps them to LLM/AGENT kinds and fixes the model name
  (`transform/phoenix_agentic_netops`). Note: the `agentic-netops.*` span
  attributes stamped in `agents/common/llm.py` (incl. the T333-T335 redacted
  prompt/response) do not reach exported spans — the SDK's context scoping
  keeps them off the spans — so content is captured as-is. The collector's
  egress to the AOS host is admitted by the `allow-egress-aos-otel`
  NetworkPolicy (`namespace-rbac.yaml`, T051) — collector pod only; without
  it the dial is dropped by the deny-all baseline and the sink fails
  silently. Note: the collector mounts its config as a file, so applying a
  changed `telemetry.yaml` also needs `kubectl rollout restart
  deploy/agent-otel-collector -n agentic-netops-agents`. Kill switch:
  remove `otlphttp/phoenix` from the traces pipeline exporters and re-apply
  (plus the restart).

## Credential policy

No credential literal may appear anywhere under this directory or under
`docker/` — CI enforces it with the `no-credential-literals` job in
`.github/workflows/ci.yaml`. Secrets (SLIM gateway password, LLM provider key,
ClickHouse auth) are generated at install time by the
`intent-secret-generator` Job, following the existing
`deploy/rbac/secret-generator-job.yaml` pattern.
