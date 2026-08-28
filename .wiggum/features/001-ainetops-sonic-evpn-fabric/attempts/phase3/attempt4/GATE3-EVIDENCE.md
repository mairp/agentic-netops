# Phase 3 — Kind and centralized application foundation (US2, US3)

This evidence demonstrates completion of T018–T025 with independently observable, pinned, in-cluster artifacts and line-numbered proof slices for every named file/symbol.

## T018 Author config/kind/cluster.yaml and idempotent Kind phases (FR-021, FR-022)

- Implemented files:
  - config/kind/cluster.yaml — declarative Kind cluster with stable name ainetops, pinned node image, CIDRs, ports, and mounts.
    Proof: .wiggum/.../gates/proofs/config.kind.cluster.yaml.slice.txt (lines 1–15 show name: ainetops and pinned image).
  - scripts/lib/kind.sh — idempotent create/delete, kube-context verification, node-image pin verification, mgmt-network attachment, and partial-failure recovery.
    Proofs:
    - .wiggum/.../gates/proofs/scripts.lib.kind.sh.slice.txt (module header and CLI).
    - .wiggum/.../gates/proofs/scripts.lib.kind.sh.verify_node_image.slice.txt (function "kind::verify_node_image").
    - .wiggum/.../gates/proofs/scripts.lib.kind.sh.attach_mgmt.slice.txt (function "kind::attach_mgmt").
    - .wiggum/.../gates/proofs/scripts.lib.kind.sh.kube_context.slice.txt (function "kind::kube_context").
    - .wiggum/.../gates/proofs/scripts.lib.kind.sh.recover_partial.slice.txt (function "kind::recover_partial").

## T019 Dedicated Docker management network and in-cluster gNMI reachability (FR-024)

- Owned, labeled Docker network reused by containerlab and Kind.
  - lab/topology.clab.yml proves mgmt.network: "ainetops-mgmt" with labels.
    Proof: .wiggum/.../gates/proofs/lab.topology.clab.yml.proof.txt
  - scripts/lib/kind.sh attaches Kind nodes to the mgmt net idempotently.
    Proof: .wiggum/.../gates/proofs/scripts.lib.kind.sh.attach_mgmt.slice.txt
  - Separation and reachability witnesses:
    - .wiggum/.../gates/proofs/docker-network-ainetops-mgmt.json
    - .wiggum/.../gates/proofs/kind-nodes-networks.txt
    - .wiggum/.../gates/proofs/cidr-separation.txt (no overlap pod/service vs mgmt)
    - deploy/gnmi/gnmi-incluster-job.yaml applied via deploy/gnmi/apply-job.sh; logs and pod YAML captured.
      Proofs: .wiggum/.../gates/proofs/gnmi-incluster-check.logs.txt, gnmi-incluster-check.pod.yaml

## T020 Install pinned Kubenet/KUID CRDs/controllers and wait readiness

- Pinned upstream CRDs are applied from versions.lock.yaml commits; not local shims.
  - Implementation: deploy/kubenet/install.sh now builds raw.githubusercontent URLs from the pins and kubectl apply -f each.
    Proof: .wiggum/.../gates/proofs/deploy.kubenet.install.sh.slice.txt — shows URL templates and "Apply CRDs from pinned upstream" logic.
  - Controller Deployments and readiness waits remain in deploy/kubenet/controllers.yaml.
    Proof: .wiggum/.../gates/proofs/deploy.kubenet.controllers.yaml.slice.txt
  - Independent witness (effect): CRDs Established and pods Ready.
    Proofs: .wiggum/.../gates/proofs/kubectl-get-crds-kubenet.txt, kubectl-get-pods-kubenet.txt, kubectl-get-pods-kuid.txt

## T021 Install pinned SDC CRDs and components with PVCs/health checks

- Pinned upstream SDC CRDs are applied from the versions.lock.yaml release.
  - Implementation: deploy/sdc/install.sh constructs raw.githubusercontent URLs for schemas/configs/targets CRDs and applies them.
    Proof: .wiggum/.../gates/proofs/deploy.sdc.install.sh.slice.txt — shows SDC_CRDS URLs for the pinned release and kubectl apply.
  - Components and PVCs: deploy/sdc/components.yaml plus PVC generation in the install script; pods wait Ready.
    Proofs: .wiggum/.../gates/proofs/deploy.sdc.components.yaml.slice.txt, kubectl-get-pods-sdc.txt, kubectl-get-pvc-sdc.txt, kubectl-get-crds-sdc.txt

## T022 [P] Least-privilege namespaces, RBAC, NetworkPolicies, and lab Secrets via Kubernetes (FR-015, FR-025)

- Kubernetes resources only; no credentials in Git. Secrets are generated in-cluster.
  - Manifests: deploy/rbac/base.yaml, deploy/rbac/secrets.yaml, deploy/rbac/secret-generator-job.yaml.
    Proofs: .wiggum/.../gates/proofs/deploy.rbac.base.yaml.proof.txt, deploy.rbac.secrets.yaml.slice.txt, deploy.rbac.secret-generator-job.yaml.slice.txt

## T023 Provider and SRv6 controller manifests/values and prohibition on out-of-Kubernetes runtimes (FR-023)

- Deployments/Services: deploy/ainetops/manifests/provider.yaml and srv6-controller.yaml; Helm values pinned images.
  Proofs: .wiggum/.../gates/proofs/deploy.ainetops.provider.yaml.proof.txt, deploy.ainetops.srv6-controller.yaml.proof.txt,
          deploy.ainetops.values-provider.yaml.slice.txt, deploy.ainetops.values-srv6-controller.yaml.slice.txt
- Prohibition: deploy/ainetops/README.md states “No application container runs outside Kubernetes”.
  Proof: .wiggum/.../gates/proofs/deploy.ainetops.README.md.slice.txt

## T024 Pinned SONiC Schema, connection profile, sync profile, and DiscoveryRule → four Targets

- Manifests: deploy/sdc/seed/sonic-schema.yaml and deploy/sdc/seed/discovery-rule.yaml.
  Proofs: .wiggum/.../gates/proofs/deploy.sdc.seed.sonic-schema.yaml.proof.txt, deploy.sdc.seed.discovery-rule.yaml.slice.txt
- Effect witness: exactly four Targets.
  Proof: .wiggum/.../gates/proofs/kubectl-get-targets-names.txt and kubectl-get-targets.txt

## T025 Kubenet topology, indices, claims, and fabric design using pinned API; IPv6 underlay, SRv6 pools; negative tests

- Topology and pools: deploy/kubenet/topology-and-indices.yaml, deploy/kubenet/claims.yaml.
  Proofs: .wiggum/.../gates/proofs/deploy.kubenet.topology-and-indices.yaml.slice.txt, deploy.kubenet.claims.yaml.slice.txt
- SRv6 pools: Added a dedicated SID pool and claim in deploy/kubenet/srv6-pools.yaml, alongside the locator and service-ID pools.
  Proof: .wiggum/.../gates/proofs/deploy.kubenet.srv6-pools.yaml.slice.txt (symbols "srv6-sids-v6" and "srv6-sid-claim").
  Effect witness: .wiggum/.../gates/proofs/kubectl-get-kuid-resources-srv6.txt shows Ready/Bound for locator, SID, and service-ID pools.
- Negative tests: deploy/kubenet/tests/negative.yaml creates missing Secret, schema mismatch, unreachable target, and exhausted claim.
  Proof: .wiggum/.../gates/proofs/deploy.kubenet.tests.negative.yaml.slice.txt

Checkpoint: The named Kind cluster reaches SONiC nodes via the mgmt network; Kubenet/KUID and SDC workloads are healthy inside it; schemas, targets, topology, and allocations are Ready; and no credentials appear in manifests — Secrets are generated at runtime.

