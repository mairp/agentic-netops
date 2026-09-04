# Intent-tier deployment transaction

This document is the implementation and operating contract for turning an approved
`NormalizedServiceIntent` into declarative Kubernetes resources. It covers the
deployer stage only. Mapping and allocation happen earlier, and the deployer must
never bypass either operator confirmation.

## Safety boundary

The supervisor may call the deployer only when both of these persisted facts hold:

- `workflow_status == APPROVED`
- `confirmation_2.decided == "confirm"`

The deployer runs as ServiceAccount `intent-deployer`. Its token is mounted in the
deployer container, its pod opts into Kubernetes API egress, and RBAC limits it to
`Network`, `SRv6Service`, and audit `Event` objects in
`agentic-netops-intent`. It has no device credentials, device-network access, or
permission to modify controller-owned resources in other namespaces.

The supervisor sends a deployment envelope containing the already validated intent
and immutable request context:

```json
{
  "action": "submit",
  "intent": {"serviceId": "...", "type": "VPWS", "tenant": "..."},
  "context": {
    "correlationId": "32-lowercase-hex",
    "threadId": "conversation-thread-id",
    "principal": "operator identity"
  }
}
```

The deployer also accepts a bare normalized intent for compatibility, but production
supervisor traffic always uses the envelope so every resource receives the same
correlation metadata as the conversation and audit record.

## Transaction

The following steps execute in order:

1. **Validate the request.** Parse the envelope and validate `intent` against
   `NormalizedServiceIntent`. Unknown fields and unsupported service properties are
   rejected before translation or cluster access.
2. **Translate once.** POST the normalized intent to the pod-local Go translator at
   `127.0.0.1:8090/v1/translate`. Python does not reproduce translation semantics.
3. **Validate and stamp manifests.** Accept only the allow-listed namespaced kinds
   `network.kubenet.dev/v1alpha1/Network` and
   `agentic-netops.io/v1alpha1/SRv6Service`. Require valid object names, place every
   object in `agentic-netops-intent`, and stamp:
   - label `agentic-netops.io/correlation-id`
   - label `agentic-netops.io/tier=intent`
   - annotations for thread ID, principal, and RFC3339 submission time
4. **Dry-run the whole bundle.** Perform server-side apply with `dryRun=All` for
   every object. If any object is rejected, stop and report its kind/name. No object
   has been mutated at this point.
5. **Apply deterministically.** Sort by namespace, kind, and name, then server-side
   apply each object with the same field manager used by the dry-run.
6. **Roll back partial application.** If any apply fails, list both allow-listed
   resource kinds by the correlation label and delete every match. Report the full
   rolled-back set and any survivor whose deletion failed. A rollback with survivors
   is a failed transaction and is never reported as submitted.
7. **Watch convergence.** Poll every submitted object until its `Ready` condition is
   true, a terminal failure condition/phase is observed, or the configured timeout
   expires. The submission report records `ready=true`, `ready=false`, or
   `ready=null` respectively and names the outcome `ready`, `failed`, or `timeout`
   for each resource.
8. **Report truthfully.** Only after every apply succeeds may the A2A worker emit the
   authoritative `DataPart` and compatibility marker containing
   `{"submitted": [ResourceRef...]}`. Translation output alone is never a
   submission report.

## Deployment reports

The deployer's authoritative payload is exactly one of:

- `{"submitted": [ResourceRef...]}` — every apply succeeded. Each `ResourceRef`
  carries the convergence `ready` value (`true`, `false`, or `null` for timeout).
- `{"failed": {"phase", "resource", "message", "rolledBack", "survivors"}}` — the
  transaction stopped. `phase` names the failed transaction phase
  (`request-validation`, `translation`, `manifest-validation`, `dry-run`, `apply`,
  `rollback`, `cluster-identity`; `transaction` for an unexpected error), `resource` names the object being processed when
  it stopped, `rolledBack` lists the `ResourceRef`s successfully deleted by the
  rollback, and `survivors` lists the ones whose deletion failed. A payload with
  `failed` is never paired with `submitted`, and the supervisor must end the
  workflow FAILED without recording a submission.

After every apply succeeds the deployer also emits its own `submit` audit event
carrying the submitted resources; on a named failure it emits a `refuse` audit event
carrying no resources. Audit emission is best-effort and never masks the outcome.

## Failure behavior

| Phase | Cluster mutation | Required result |
| --- | --- | --- |
| Request/translation/manifest validation | None | Named deployer failure |
| Server-side dry-run | None | Rejecting resource and API reason |
| Apply | Possible partial bundle | Label-selector rollback and complete rollback report |
| Convergence | Bundle remains as desired state | Per-resource ready, failed, or timeout outcome |
| Rollback with survivors | Survivors explicitly named | Terminal failure; never `submitted` |

## Operator verification

Given correlation ID `$CID`, reconcile the report against the cluster:

```bash
kubectl -n agentic-netops-intent get networks,srv6services \
  -l agentic-netops.io/correlation-id="$CID" -o wide

kubectl -n agentic-netops-intent get events \
  -l agentic-netops.io/correlation-id="$CID" --sort-by=.lastTimestamp
```

Before testing a request, verify the deployment identity and API path:

```bash
kubectl auth can-i create networks.network.kubenet.dev \
  -n agentic-netops-intent \
  --as=system:serviceaccount:agentic-netops-agents:intent-deployer

kubectl -n agentic-netops-agents exec deploy/deployer -c deployer -- \
  test -s /var/run/secrets/kubernetes.io/serviceaccount/token
```

The number and names of objects returned by the first query must equal the
`submitted` resources in the deployer audit event. A failed precondition or dry-run
must return zero objects for that correlation ID.

## Southbound reconciliation (operational, 2026-09-04)

Submission is not the end of the transaction: a `sonicprovider` Network
controller in `agentic-netops-system` reconciles every accepted Network onto
the fabric and owns its `Ready` condition. What the deployer's convergence
watch polls is now actually driven:

- **Render** (`pkg/fabricplan`): per-node ops from the Network spec — GCU for
  VRF declarations, raw CONFIG_DB for the L3VNI vlan + tunnel map, kernel-side
  SVI/attachment (bridge-access model; ports are shared per-vlan), FRR
  vrf/bgp as best-effort (D-A2). Intent VRF names are derived to device names
  (`Vrf-` + 10 chars) because sonic-vrf.yang caps names hard.
- **Execute** (`cmd/fabric-executor`): a HOST service on :8084 (kind nodes run
  containerd; the host docker.sock cannot enter a pod), reached by the provider
  at `http://172.30.0.1:8084` under a single-purpose netpol + iptables rule.
  Stops at the first failed op and reports the op's own output.
- **Verify**: CONFIG_DB rows, kernel masters, addresses, bridge-vids —
  `Ready=True` only when every node's checks pass; fatal op kinds (gcu, redis,
  shell) set `Ready=False/ApplyFailed` and requeue; vtysh/frrconf failures are
  degraded-but-True (D-A2). Deletion rolls back owned state before the
  finalizer drops.
