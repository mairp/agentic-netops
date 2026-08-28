# Phase 3 — critic feedback (REJECTED)

The following must be addressed before re-writing GATE3-EVIDENCE.md:

REJECTED — unmet or unproven acceptance criteria

- T019 — Containerlab reuse of the dedicated management network is not evidenced
  - Gap: The snapshot does not show mgmt.network set to ainetops-mgmt in lab/topology.clab.yml as claimed. Provide the exact lines proving containerlab attaches to the ainetops-mgmt network and includes the ownership label.
  - NEEDS-GROUNDING:lab/topology.clab.yml

- T019 — Pod/service network separation proof is incomplete
  - Gap: The claimed independent artifacts from deploy/tests/probes/separation.sh are missing at least one key file: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/docker-network-ainetops-mgmt.json is absent on disk. Without the docker network inspect output, there is no independent witness of the mgmt network’s CIDR and Kind node attachments. Provide the missing docker-network-ainetops-mgmt.json and the other probe files (kind-nodes-networks.txt and cidr-separation.txt) as generated artifacts.

- T020 — No independent witness that Kubenet/KUID are installed and Ready inside Kind
  - Gap: Manifests and install.sh exist, but there is no effect-witness that CRDs are Established and controller Pods reached Ready. Provide independently captured kubectl outputs proving:
    - CRDs Established (e.g., kubectl get crd ... with conditions, or kubectl wait logs)
    - Pods Ready in kubenet-system and kuid-system (e.g., kubectl -n <ns> get pods -o wide and/or describe with Ready=True)
    - Durable evidence files under .wiggum/.../proofs that could not exist before installation

- T021 — No independent witness that SDC CRDs/components and required PVCs are Ready
  - Gap: Manifests and install.sh exist, but there is no effect-witness that SDC Deployments are Ready and PVCs are Bound. Provide captured kubectl outputs proving:
    - CRDs Established (schemas/configs/targets)
    - Deployments sdc-schema, sdc-config, sdc-data, sdc-cache have available replicas and Pods Ready=True
    - PVCs sdc-data and sdc-cache are Bound
    - Store these as immutable proof artifacts under .wiggum/.../proofs

- T024 — No effect-witness that DiscoveryRule produced exactly four SDC Target resources
  - Gap: The seed manifests exist, but there is no independent read of the resulting targets. Provide:
    - kubectl get targets.sdc.sdcio.dev -n sdc-system -o name showing exactly four Target resources
    - Optionally, a content hash or names list captured into a proof file under .wiggum/.../proofs

- T025 — No independent witness of topology/indices/claims readiness or negative test behavior
  - Gap: Manifests exist, but no proof they are applied and in a Ready state, and no evidence that the negative tests (missing Secret, schema mismatch, unreachable target, exhausted/colliding claims) produce the expected failures without side effects. Provide:
    - kubectl get of the created resources with Ready/condition states proving allocations and topology readiness
    - For negative tests, captured status/Events showing the intended errors and that no unintended resources were created/modified as a result
    - Store these under .wiggum/.../proofs

Notes
- The in-cluster gNMI Job logs and Pod Succeeded status are good positive evidence for reachability, but T019 also requires independent proof of network separation and containerlab reuse of the mgmt network.
- T018 appears largely satisfied by grounded files (cluster.yaml with stable name and pinned image; kind.sh implements ensure, verify-context, partial recovery, node-image verification). If delete idempotence is part of your acceptance, include a proof run showing kind delete cluster idempotence; otherwise no contradiction was found in the current snapshot.

VERDICT 6268067ab6ea2135: REJECTED



---
## Grounding transparency (machine-generated — read this)
These files you cited EXIST on disk, but the critic's grounding extractor could not include them in its snapshot, so the critic cannot 'see' their contents. This is a TOOLING limitation, NOT a missing file. Do NOT re-create, copy, or promote them — they are already present and correct. If a criterion depends on one, either cite it a different way (e.g. a slash path like `./versions.lock.yaml`) or state in your evidence that grounding cannot reach it:
- `versions.lock.yaml`
