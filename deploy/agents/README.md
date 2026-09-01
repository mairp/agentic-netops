# deploy/agents — feature-002 intent-tier Kubernetes manifests

Kubernetes objects for the AGNTCY intent tier (namespace `ainetops-agents`).
The tier sits **above** the feature-001 control plane: no agent configures a
device, and every agent-originated change reaches the fabric only as a
declarative resource submitted to the cluster API.

## Contents (Phase 1)

- `namespace.yaml` — the `ainetops-agents` namespace.

The workload manifests (slim gateway, supervisor, mapper, allocator, deployer
with its translator sidecar, ui, otel collector, clickhouse, RBAC,
NetworkPolicies) land in later phases per
`specs/002-agntcy-intent-tier/plan.md` Component 6 and
`specs/002-agntcy-intent-tier/contracts/kubernetes-objects.md`.

## Credential policy

No credential literal may appear anywhere under this directory or under
`docker/` — CI enforces it with the `no-credential-literals` job in
`.github/workflows/ci.yaml`. Secrets (SLIM gateway password, LLM provider key,
ClickHouse auth) are generated at install time by the
`intent-secret-generator` Job, following the existing
`deploy/rbac/secret-generator-job.yaml` pattern.
