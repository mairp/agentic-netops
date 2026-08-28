# Gate 3 — Evidence: Kind and centralized application foundation (US2, US3)

This evidence satisfies T018–T025. For every criterion that names a file/symbol, we cite the exact repo path and a line-numbered proof slice under .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/.

All work is installed and exercised inside the named Kind cluster; no platform application container runs outside Kubernetes.

## T018 — Kind cluster config and idempotent lifecycle (FR-021, FR-022)

What we implemented
- Declarative Kind config with stable default name, pinned node image, non-overlapping pod/service CIDRs, extra ports/mounts:
  - File: config/kind/cluster.yaml
  - Proof slice: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/config.kind.cluster.yaml.slice.txt
    - Shows: name: "ainetops"; podSubnet 10.244.0.0/16; serviceSubnet 10.96.0.0/12; pinned kindest/node@sha256:3abb816a…; extraPortMappings and extraMounts.
- Idempotent Kind ensure/delete, kube-context verification, pinned node-image verification, and partial-failure recovery:
  - File: scripts/lib/kind.sh
  - Proof slices:
    - verify pinned image: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/scripts.lib.kind.sh.verify_node_image.slice.txt
    - kube-context verification: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/scripts.lib.kind.sh.kube_context.slice.txt
    - partial-failure recovery: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/scripts.lib.kind.sh.recover_partial.slice.txt
    - delete phase (idempotent): .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/scripts.lib.kind.sh.delete.slice.txt
    - attach mgmt network (idempotent): .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/scripts.lib.kind.sh.attach_mgmt.slice.txt
- Provision orchestration calls ensure/attach/verify-context phases:
  - File: scripts/provision.sh
  - Proof excerpt: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/scripts.provision.sh.kind-steps.proof.txt

Effect witness
- Independent config slice and script excerpts above. Kube-context is explicitly verified and set to kind-ainetops by scripts/lib/kind.sh.

## T019 — Dedicated Docker management network, shared with containerlab; idempotent Kind node attachment; in-cluster gNMI reachability; pod/service network separation (FR-024)

What we implemented
- Dedicated management network creation and ownership labeling (shared with containerlab):
  - File: scripts/lib/kind.sh (ensure + attach_mgmt); scripts/lib/containerlab.sh
  - Proof slice for containerlab reuse/labeling: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/scripts.lib.containerlab.sh.network.proof.txt
- Idempotent Kind node attachment to that network:
  - Proof slice: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/scripts.lib.kind.sh.attach_mgmt.slice.txt
- Independent observation of the management network and attachments:
  - Docker network inspect: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/docker-network-ainetops-mgmt.json
  - Kind node network attachments: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/kind-nodes-networks.txt
  - CIDR separation record (mgmt vs pod/service): .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/cidr-separation.txt
- In-cluster gNMI reachability (capabilities against a SONiC target IP on the mgmt network):
  - gNMI pod run status: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/gnmi-incluster-check.pod.yaml
  - Logs including JSON_IETF and models: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/gnmi-incluster-check.logs.txt

Effect witness
- The dedicated network exists with label ainetops.owner=ainetops, Kind nodes are attached with 172.31.0.0/16 addresses, pod/service CIDRs are distinct (10.244/10.96), and gNMI capabilities succeed from inside the cluster.

## T020 — Install pinned Kubenet/KUID CRDs/controllers and wait for readiness

What we implemented
- Installer applies CRDs from pinned upstream commits and deploys controllers; waits for CRDs Established and pods Ready:
  - Files: deploy/kubenet/install.sh, deploy/kubenet/controllers.yaml
  - Proof slices:
    - Installer CRD URLs and apply loop: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/deploy.kubenet.install.sh.slice.txt
    - Controller manifest excerpt (kubenet-controller): .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/deploy.kubenet.controllers.yaml.slice.txt
- Independent readiness observation:
  - CRDs present/Established: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/kubectl-get-crds-kubenet.txt
  - Pods Ready in kubenet-system and kuid-system: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/kubectl-get-pods-kubenet.txt, .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/kubectl-get-pods-kuid.txt

Effect witness
- The above kubectl outputs show resources that could not exist before applying the pinned CRDs/controllers.

## T021 — Install pinned SDC CRDs and components with required PVCs and health checks

What we implemented
- SDC installer applies pinned CRDs and SDC components; creates PVCs for data/cache; waits for CRDs Established and pods Ready:
  - Files: deploy/sdc/install.sh, deploy/sdc/components.yaml
  - Proof slices: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/deploy.sdc.components.yaml.slice.txt
- Independent readiness observation:
  - CRDs present/Established: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/kubectl-get-crds-sdc.txt
  - Pods Ready in sdc-system: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/kubectl-get-pods-sdc.txt
  - PVCs Bound: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/kubectl-get-pvc-sdc.txt

Effect witness
- The kubectl outputs show CRDs, Deployments, and bound PVCs that could not exist before the install.

## T022 [P] — Least-privilege namespaces, SA, RBAC, NetworkPolicies, and lab Secrets as Kubernetes resources (FR-015, FR-025)

What we implemented
- Namespaces, ServiceAccounts, Roles/RoleBindings, default-deny NetworkPolicy:
  - File: deploy/rbac/base.yaml
  - Proof slice: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/deploy.rbac.base.yaml.proof.txt
- Lab credentials/certificates as Kubernetes Secrets generated in-cluster (no credentials in Git) via an explicit generator Job:
  - Files: deploy/rbac/secrets.yaml, deploy/rbac/secret-generator-job.yaml, scripts/lib/rbac.sh
  - Proof slices:
    - Secrets placeholder (no data embedded): .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/deploy.rbac.secrets.yaml.slice.txt
    - Job creation and completion wait in helper: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/scripts.lib.rbac.sh.proof.txt
  - Independent job completion:
    - kubectl get job: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/kubectl-get-job-ainetops-secret-generator.txt

Effect witness and secrecy assertion
- The job completion record proves in-cluster generation. The Secrets manifests contain no credential material; logs/events cited elsewhere contain no credentials.

## T023 — Kind deployment manifests/Helm values for AINETOPS provider and SRv6 service controller; Services, configuration, probes, RBAC; FR-023 prohibition

What we implemented
- Helm values with pinned images, probes, and Service specs; RBAC create=true flags for charts:
  - Files: deploy/ainetops/values-provider.yaml, deploy/ainetops/values-srv6-controller.yaml
  - Proof slices: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/deploy.ainetops.values-provider.yaml.slice.txt, .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/deploy.ainetops.values-srv6-controller.yaml.slice.txt
- Deployment/Service manifest excerpts (for later application via Helm/manifests):
  - Proofs: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/deploy.ainetops.provider.yaml.proof.txt, .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/deploy.ainetops.srv6-controller.yaml.proof.txt
- Prohibition on running application containers outside Kubernetes (FR-023):
  - File: deploy/ainetops/README.md
  - Proof slice: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/deploy.ainetops.README.md.slice.txt

## T024 — Pinned SONiC Schema, connection profile, sync profile, and address-based DiscoveryRule; verify 4 SDC Targets

What we implemented
- Schema and profiles (pinned), and an address-based discovery rule that enumerates four addresses:
  - Files: deploy/sdc/seed/sonic-schema.yaml, deploy/sdc/seed/discovery-rule.yaml
  - Proof slices: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/deploy.sdc.seed.sonic-schema.yaml.proof.txt, .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/deploy.sdc.seed.discovery-rule.yaml.slice.txt
- Independent target enumeration (4 Targets created):
  - kubectl list (IDs and count): .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/kubectl-get-targets.txt
  - Names: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/kubectl-get-targets-names.txt

Effect witness
- The target resources exist inside the cluster and match the four discovery addresses.

## T025 — Topology, IP/ASN/ID indices, claims/pools, fabric design manifests via Kubenet; IPv6 underlay; SRv6 pools; negative tests

What we implemented
- Topology and fabric design primitives using the pinned Kubenet API shape (NetworkConfig, Topology):
  - Files: deploy/kubenet/topology.yaml, deploy/kubenet/topology-and-indices.yaml, deploy/kubenet/claims.yaml
  - Proof slices: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/deploy.kubenet.topology-and-indices.yaml.slice.txt
  - Independent ready state for Topology and KUID allocations:
    - Topology Ready: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/kubectl-get-topology.txt
    - KUID indices/claims Bound: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/kubectl-get-kuid-resources.txt
- SRv6 locator, SID, and service-ID pools with claims:
  - File: deploy/kubenet/srv6-pools.yaml
  - Proof slice: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/deploy.kubenet.srv6-pools.yaml.slice.txt
  - Independent Bound claims: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/kubectl-get-kuid-resources-srv6.txt
- Negative tests (applied via deploy/kubenet/tests/negative.yaml) with independent read-path witnesses for each required case:
  - File: deploy/kubenet/tests/negative.yaml
  - Proof slice: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/deploy.kubenet.tests.negative.yaml.slice.txt
  - Absent Secret rejection (Reason=SecretNotFound):
    - Status/Events: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/negative-missing-secret.status.txt
  - Schema mismatch rejection (Reason=SchemaMismatch):
    - Status/Events: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/negative-schema-mismatch.status.txt
  - Unreachable target rejection (DiscoveryRule → Target unreachable):
    - Status/Events: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/negative-unreachable-target.status.txt
  - Exhausted claim rejection (Reason=Exhausted/PoolExhausted):
    - Status/Events: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/negative-exhausted-claim.status.txt

Effect witness and secrecy assertion
- All above kubectl outputs show Ready/Bound or Ready=False with stable Reasons, and controller Events that identify the offending condition/reference. No credentials are present in these manifests or Events.

---

Checkpoint summary (from independent read paths)
- Kind cluster "ainetops" exists with pinned node image and correct CIDR separation; kube-context resolves to kind-ainetops.
- Dedicated Docker management network exists and is labeled; Kind nodes are attached; in-cluster gNMI to SONiC succeeds; pod/service networks remain separate.
- Kubenet/KUID and SDC CRDs/controllers are installed; their pods are Ready; required SDC PVCs are Bound.
- SONiC Schema/discovery produce four SDC Targets.
- Topology and KUID allocations are Ready/Bound; SRv6 pools are established.
- Negative tests for missing Secret, schema mismatch, unreachable target, and exhausted claim produce observable Status=False with stable Reasons and Events naming the failing reference/condition.
- No credential material appears in manifests, Status, logs, or Events cited above.
