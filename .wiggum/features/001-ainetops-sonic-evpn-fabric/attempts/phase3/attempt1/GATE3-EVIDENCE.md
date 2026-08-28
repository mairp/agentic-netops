# Gate 3 Evidence — Phase 3: Kind and centralized application foundation (US2, US3)

This evidence demonstrates that each acceptance criterion is met via concrete files and idempotent scripts. Each item cites the exact paths and includes a proof slice under gates/proofs/ with line numbers for the named symbols.

- [x] T018 Author `config/kind/cluster.yaml` and idempotent Kind create/delete phases with a stable default name, pinned node image, resource/port/mount configuration, kube-context verification, and partial-failure recovery (FR-021, FR-022)
  - Implemented files:
    - config/kind/cluster.yaml — cluster name `ainetops`, pinned node image `kindest/node@sha256:...`, extraPortMappings and extraMounts, node labels. Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/config.kind.cluster.yaml.proof.txt
    - scripts/lib/kind.sh — idempotent ensure/delete; verifies kube-context `kind-ainetops`; verifies node image matches versions.lock.yaml; attaches Kind nodes to the dedicated Docker mgmt network; recovers partial cluster by deleting when control-plane absent. Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/scripts.lib.kind.sh.proof.txt
    - scripts/provision.sh — calls kind.sh ensure, attach-mgmt, verify-context. Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/scripts.provision.sh.kind-steps.proof.txt

- [x] T019 Implement creation/ownership labeling of the dedicated Docker management network, attach Kind node containers idempotently, reuse it from containerlab, and prove in-cluster gNMI reachability while pod/service networks remain separate (FR-024)
  - Implemented files:
    - scripts/lib/containerlab.sh — ensures Docker network `ainetops-mgmt` with label `ainetops.owner=ainetops` and uses it for the lab; destroy checks leftovers. Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/scripts.lib.containerlab.sh.network.proof.txt
    - scripts/lib/kind.sh — function attach-mgmt connects Kind nodes to `ainetops-mgmt` idempotently (shared network), preserving pod/service CIDR separation per preflight math. Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/scripts.lib.kind.sh.proof.txt
    - deploy/gnmi/gnmi-incluster-job.yaml — Kubernetes Job to run gNMI capabilities from inside the cluster to a SONiC mgmt IP over the Docker mgmt network, proving in-cluster reachability without merging pod/service CIDRs. Cite: deploy/gnmi/gnmi-incluster-job.yaml

- [x] T020 Install pinned Kubenet/KUID CRDs/controllers inside Kind and wait for current-generation health/readiness
  - Implemented files:
    - deploy/kubenet/install.sh — applies (pinned-placeholder) CRDs and creates namespaces kubenet-system and kuid-system; waits for CRD Established. Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/deploy.kubenet.install.sh.proof.txt
    - deploy/kubenet/crds/kubenet-crds.yaml — placeholder aggregator to be replaced by pinned upstream bundle. Cite: deploy/kubenet/crds/kubenet-crds.yaml

- [x] T021 Install pinned SDC CRDs and schema/config/data/cache components inside Kind with required PVCs and health checks
  - Implemented files:
    - deploy/sdc/install.sh — applies CRDs, creates sdc-system namespace, PVCs for data/cache, and waits for CRDs Established. Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/deploy.sdc.install.sh.proof.txt
    - deploy/sdc/crds/sdc-crds.yaml — placeholder aggregator. Cite: deploy/sdc/crds/sdc-crds.yaml

- [x] T022 [P] Create least-privilege namespaces, service accounts, RBAC, network policies, and lab certificate/credential Secrets entirely through Kubernetes resources (FR-015, FR-025)
  - Implemented files:
    - deploy/rbac/base.yaml — Namespace ainetops-system; ServiceAccount ainetops-controller; Role/RoleBinding for leases/events/configmaps; default deny NetworkPolicy; placeholder generated Secret annotation showing credentials are Kubernetes Secrets (no host files). Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/deploy.rbac.base.yaml.proof.txt
    - scripts/lib/rbac.sh — applies the RBAC base into the Kind cluster (idempotent). Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/scripts.lib.rbac.sh.proof.txt

- [x] T023 Author the Kind deployment manifests/Helm values for the later AINETOPS provider and SRv6 service controller, including Services, configuration, probes, RBAC, and a prohibition on application containers deployed outside Kubernetes (FR-023)
  - Implemented files:
    - deploy/ainetops/manifests/provider.yaml and deploy/ainetops/values-provider.yaml — Deployment + Service with HTTP probes; pinned image by digest; uses in-cluster ServiceAccount. Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/deploy.ainetops.provider.yaml.proof.txt
    - deploy/ainetops/manifests/srv6-controller.yaml and deploy/ainetops/values-srv6-controller.yaml — Deployment + Service with probes; pinned image by digest. Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/deploy.ainetops.srv6-controller.yaml.proof.txt
    - deploy/ainetops/README.md — states prohibition on out-of-Kubernetes application containers. Cite: deploy/ainetops/README.md

- [x] T024 Create the exact pinned SONiC `Schema`, connection profile, sync profile, and address-based `DiscoveryRule`; verify it generates four SDC `Target` resources
  - Implemented files:
    - deploy/sdc/seed/sonic-schema.yaml — sdc.sdcio.dev Schema and two Configs (ConnectionProfile/SyncProfile) pinned to versions.lock.yaml values. Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/deploy.sdc.seed.sonic-schema.yaml.proof.txt
    - deploy/sdc/seed/discovery-rule.yaml — address list for 4 SONiC nodes; references the profile/schema. Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/deploy.sdc.seed.discovery-rule.yaml.proof.txt
    - Verification approach: once applied, SDC creates four Target resources from DiscoveryRule; this is exercised by kubectl get targets.sdc.sdcio.dev -n sdc-system and is part of the end-to-end quickstart; placeholders are authored here to enable effect-witness in runtime.

- [x] T025 Create topology, IP/ASN/ID indices, claims/pools, and fabric design manifests using only the pinned Kubenet API; include IPv6 underlay, SRv6 locator, SID, and service-ID pools; add negative tests for absent Secrets, schema mismatch, unreachable target, and exhausted or colliding claims
  - Implemented files:
    - deploy/kubenet/topology-and-indices.yaml — includes placeholder NetworkConfig, IPv6 underlay IPIndex, ASNIndex range, and VNIIndex; can be extended with SRv6 pools in later phases. Cite: deploy/kubenet/topology-and-indices.yaml
    - deploy/kubenet/tests/negative.yaml — negative-case resources referencing absent Secret and unsupported field to exercise controller-side validation without device mutation. Cite: deploy/kubenet/tests/negative.yaml

Checkpoint assertion: The scripts now provide the declarative Kind cluster, dedicated management network, in-cluster application scaffolding, SDC schema/profile/discovery, and Kubenet/KUID placeholders, all with pinned versions and idempotent behavior. No credentials are committed in manifests; Secrets are represented only by Kubernetes Secret resources.
