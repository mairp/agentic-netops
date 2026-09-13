# deploy/agents — intent-tier Kubernetes manifests

Kubernetes objects for the AGNTCY intent tier (namespace
`agentic-netops-agents`). The tier sits **above** the fabric control plane: no
agent configures a device, and every agent-originated change reaches the fabric
only as a declarative resource submitted to the cluster API. The Nokia SR Linux
migration does not change that boundary — the tier has no route to the nodes,
and the only write path to the fabric stays the fabric-executor's gNMI Set.

## Contents

- `namespace.yaml`, `namespace-rbac.yaml` — the namespace, ServiceAccounts,
  Roles/Bindings and the NetworkPolicies that scope tier egress. The
  `allow-egress-scoped` policy carves the containerlab management subnet
  `172.31.0.0/16` out of model-provider egress, so a tier pod cannot dial an
  SR Linux node's gNMI port on `:57400`.
- `slim.yaml` — the A2A/SLIM gateway.
- `supervisor.yaml`, `mapper.yaml`, `allocator.yaml`, `deployer.yaml` — the four
  agents. The deployer carries the intent-translator sidecar, whose
  `FABRIC_NODE_MAP` and `FABRIC_PORT_MAP` name the site's real nodes and ports
  (`ethernet-1/3`, `ethernet-1/4` on SR Linux) so an endpoint the fabric does
  not have is refused before anything is submitted.
- `ui.yaml`, `ui-configmap.yaml` — the operator console.
- `telemetry.yaml` — the tier-owned OTel collector, exporting to ClickHouse and
  forwarding to the system-tier collector.
- `llm-provider-secret.yaml`, `secret-generator-job.yaml` — the generated
  credentials.
- `alerts/intent-tier-rules.yaml`, `dashboards/intent-tier.json` — tier
  observability.
- `networkpolicy-llm-egress.yaml` — model-provider egress budget.
- `tests/probes/` — the guardrail probes (management-network denial, RBAC
  denials, SLIM auth denial, rollback drill, secret rotation).

Keep `FABRIC_PORT_MAP` in step with the two other places that own these maps:
`FABRIC_NODE_MAP` in `scripts/provision.sh` (fabric-executor) and
`FABRIC_PORT_MAP` in `deploy/agentic-netops/manifests/provider.yaml`.

## Credential policy

No credential literal may appear anywhere under this directory or under
`docker/` — CI enforces it with the `no-credential-literals` job in
`.github/workflows/ci.yaml`. Secrets (SLIM gateway password, LLM provider key,
ClickHouse auth) are generated at install time by the
`intent-secret-generator` Job, following the existing
`deploy/rbac/secret-generator-job.yaml` pattern. The SR Linux gNMI credentials
live in `gnmi-lab-creds` / `gnmi-lab-tls` in `agentic-netops-system` and are
never mounted into a tier pod.
