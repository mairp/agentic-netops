# Phase 3 — critic feedback (REJECTED)

The following must be addressed before re-writing GATE3-EVIDENCE.md:

REJECTED criteria and gaps

- T019 Implement creation/ownership labeling of the dedicated Docker management network, attach Kind node containers idempotently, reuse it from containerlab, and prove in-cluster gNMI reachability while pod/service networks remain separate (FR-024)
  - Missing proof of in-cluster gNMI reachability: deploy/gnmi/gnmi-incluster-job.yaml is just a manifest and is not applied anywhere; no independent witness (e.g., Job completion logs) is provided.
  - Secret mismatch prevents execution: the Job references Secrets gnmi-lab-creds and gnmi-lab-tls, but no such Secrets are created anywhere in the repo.
  - No independent evidence that pod/service CIDRs remain separate from the Docker mgmt network beyond intent; no validation/test is provided.

- T020 Install pinned Kubenet/KUID CRDs/controllers inside Kind and wait for current-generation health/readiness
  - CRDs are placeholders: deploy/kubenet/crds/kubenet-crds.yaml contains only comments and will not create any CRDs when applied.
  - KUID CRD manifest referenced by installer is missing: deploy/kuid/crds/kuid-crds.yaml is not present in the snapshot.
  - Controllers are not installed: deploy/kubenet/install.sh explicitly omits controller installation; there are no Helm/kustomize manifests to install Kubenet or KUID controllers.
  - No readiness/health checks for controllers; only CRD Established waits are attempted (and would no-op with placeholder CRDs).

- T021 Install pinned SDC CRDs and schema/config/data/cache components inside Kind with required PVCs and health checks
  - CRDs are placeholders: deploy/sdc/crds/sdc-crds.yaml contains only a comment and will not create any CRDs.
  - Components (schema/config/data/cache) are not installed: no Deployments/StatefulSets/Services exist for SDC; only two PVCs are created.
  - No health checks/readiness for SDC components are present.

- T022 [P] Create least-privilege namespaces, service accounts, RBAC, network policies, and lab certificate/credential Secrets entirely through Kubernetes resources (FR-015, FR-025)
  - Lab certificate/credential Secrets are incomplete: only a placeholder Secret gnmi-lab-ca with a note is defined. Required credential/TLS Secrets (e.g., gnmi-lab-creds and gnmi-lab-tls referenced by the gNMI Job) are not created via Kubernetes resources, nor is there a generator step.
  - Actionable: add Kubernetes-native generation/apply of the credential and TLS Secrets (no host files), and ensure RBAC/NetworkPolicies cover their use.

- T024 Create the exact pinned SONiC Schema, connection profile, sync profile, and address-based DiscoveryRule; verify it generates four SDC Target resources
  - While the Schema/Config/DiscoveryRule manifests exist, there is no independent witness that four Target resources are created. With SDC controllers not installed (T021), the Targets cannot be generated.
  - Actionable: install SDC components, apply the seed manifests, and provide a captured independent read (e.g., kubectl get targets.sdc.sdcio.dev -n sdc-system -o name showing exactly four) as durable evidence.

- T025 Create topology, IP/ASN/ID indices, claims/pools, and fabric design manifests using only the pinned Kubenet API; include IPv6 underlay, SRv6 locator, SID, and service-ID pools; add negative tests for absent Secrets, schema mismatch, unreachable target, and exhausted or colliding claims
  - Missing SRv6 resources: no SRv6 locator, SID, or service-ID pools are defined (the file notes “can be extended later,” but the criterion requires them now).
  - Missing claims/pools: only indices are provided; no KUID Claim resources for IP/ASN/VNI (or SRv6) are present.
  - Missing topology/fabric design artifacts beyond a placeholder NetworkConfig; no Topology or full design manifests per the pinned API are present.
  - Negative tests are incomplete: only absent Secret and schema mismatch are provided; no tests for unreachable target or exhausted/colliding claims.

Items requiring content to judge completely (do not count as unmet solely due to snapshot elision)
- NEEDS-GROUNDING:scripts/lib/kind.sh
  - Confirm the CLI dispatch exists for ensure, attach-mgmt, verify-context, and delete, and that an idempotent delete phase is implemented per T018.
- NEEDS-GROUNDING:versions.lock.yaml
  - Confirm the Kind node image pin is recorded and matches the node image used in config/kind/cluster.yaml (and that scripts/lib/kind.sh’s verify logic aligns with this pin).

VERDICT f805e07c43b830bd: REJECTED



---
## Grounding transparency (machine-generated — read this)
These files you cited EXIST on disk, but the critic's grounding extractor could not include them in its snapshot, so the critic cannot 'see' their contents. This is a TOOLING limitation, NOT a missing file. Do NOT re-create, copy, or promote them — they are already present and correct. If a criterion depends on one, either cite it a different way (e.g. a slash path like `./versions.lock.yaml`) or state in your evidence that grounding cannot reach it:
- `versions.lock.yaml`
