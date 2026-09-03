# Intent Tier Runbook

This runbook covers bring-up, teardown, and per-stage failure diagnosis for the AGNTCY multi-agent intent tier (the `agentic-netops-intent` fabric-intent tier in this repository). It assumes the Agentic NetOps SONiC EVPN/VXLAN fabric is managed by this repository and that the Kind cluster and observability stack are provisioned by the standard scripts.

## Bring-up

Preconditions:
- Host has Docker, Kind, kubectl, Go toolchain, Node.js 20, and `uv` installed per repo README.
- External Docker network `agentic-netops-mgmt` present (the provision script ensures this idempotently).

Steps:
1. Provision the base fabric and control plane, then install the intent tier in the same run:
   - ./scripts/provision.sh --profile sonic-vs --with-intent-tier
   - Environment overrides (optional): AGENTIC_NETOPS_CLUSTER_NAME (default: agentic-netops), AGENTIC_NETOPS_TIMEOUT.
2. The script performs:
   - pins/CRD verification, Kind ensure/attach, containerlab deploy;
   - base RBAC, Kubenet/KUID/SDC installation and readiness waits;
   - observability stack install and image preloads;
   - intent-tier install via scripts/lib/intent_tier.sh (secret generator job -> SLIM -> supervisor/mapper/allocator/deployer -> UI);
   - bounded rollout waits for every tier deployment.
3. Validate readiness:
   - kubectl --context kind-agentic-netops -n agentic-netops-agents get deploy,po,svc
   - curl http://supervisor.agentic-netops-agents.svc:9090/health (liveness ok)
   - curl http://supervisor.agentic-netops-agents.svc:9090/v1/health (200 ok with workers map, or 503 degraded with named worker)
   - curl http://supervisor.agentic-netops-agents.svc:9090/transport/config (expects endpoint :46357)
- Access UI at http://localhost:30000 (Kind NodePort mapping).

Expected outcomes:
- All tier Deployments Ready; supervisor /v1/health reports status ok and transport SLIM with the in-cluster gateway endpoint (http://slim.agentic-netops-agents.svc:46357).

## Teardown

To remove only the intent tier (leaving the fabric/control plane intact):
- ./scripts/off.sh --purge-intent-tier
  - This calls intent::uninstall: deletes supervisor/mapper/allocator/deployer/slim/ui deployments and services, the secret generator job, config/secrets, and the supervisor checkpoint PVC; it optionally reverts the Grafana dashboard mount.

To fully tear down the environment (including lab and Kind):
- ./scripts/off.sh --cluster-name agentic-netops --delete-kind true

Idempotence expectations:
- Re-running provision with --with-intent-tier performs no duplicate submissions and converges to Ready.
- Re-running off.sh --purge-intent-tier when absent performs no-op deletions without error.

## Per-stage failure diagnosis

Use these checks to attribute and remediate failures:

1) Transport and worker availability
- Supervisor readiness: curl http://supervisor.agentic-netops-agents.svc:9090/v1/health
  - 200 ok: workers map all ok.
  - 503 degraded: workers map includes unreachable worker(s) — investigate the named deployment and SLIM gateway.
- SLIM gateway: kubectl -n agentic-netops-agents get deploy slim; ensure Service on 46357/TCP; inspect slim logs for TLS/auth issues.

2) Classifier/model provider issues
- The supervisor falls back to general_info with a message indicating model unavailability; verify llm-provider Secret and LLM_MODEL prefix.
- Check agents/common/errors.py provider_unavailable_message patterns and supervisor logs for actionable messages.

3) Mapper stage rejections and clarifications
- Clarification cases present pending_action=clarify, missing_fields[], and an operator prompt: “Before I can map this service I need: …”.
- Rejections name “mapper payload out of contract: …” in the error and include a correlation id.

4) Allocator stage failures
- Rejections name “allocator payload out of contract: …”.
- Confirm KUID API reachability from allocator pod. If Kubernetes API issues occur, use cluster_api_unavailable_message guidance.

5) Deployer submission preconditions
- The deployer refuses with “submission precondition failed: …” unless workflow_status==APPROVED and confirmation_2.decided=="confirm".
- Submission report: supervisor NDJSON includes a “Submission report received” line naming Network/<serviceId> and correlation id; audit contains a submit event.

6) General error handling
- Operator-facing failures include the responsible stage and correlation id. Use the correlation id to locate audit events and cluster resources.

Appendix: Useful commands
- kubectl --context kind-agentic-netops -n agentic-netops-agents logs deploy/supervisor
- kubectl --context kind-agentic-netops -n agentic-netops-agents logs deploy/mapper
- kubectl --context kind-agentic-netops -n agentic-netops-agents logs deploy/allocator
- kubectl --context kind-agentic-netops -n agentic-netops-agents logs deploy/deployer
- kubectl --context kind-agentic-netops -n agentic-netops-agents get events --sort-by=.lastTimestamp
