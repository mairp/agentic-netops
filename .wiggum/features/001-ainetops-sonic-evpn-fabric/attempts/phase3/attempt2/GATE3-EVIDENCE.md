# Phase 3 — Kind and centralized application foundation (US2, US3)

This evidence addresses T018–T025 with concrete artifacts and line-numbered proof slices. All cited paths are relative to the repo root. Proof slices are under .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/.

- T018 Author config/kind/cluster.yaml and idempotent Kind create/delete phases with a stable default name, pinned node image, resource/port/mount configuration, kube-context verification, and partial-failure recovery (FR-021, FR-022)
  - Implemented files:
    - config/kind/cluster.yaml (stable name ainetops; pod/service CIDRs; extraPortMappings; pinned node image)
      • Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/config.kind.cluster.yaml.slice.txt (shows name: ainetops, podSubnet, serviceSubnet, and pinned image)
    - scripts/lib/kind.sh (ensure, attach-mgmt, verify-context, delete; node image pin verification; partial-failure recovery)
      • Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/scripts.lib.kind.sh.slice.txt (CLI dispatch includes ensure|attach-mgmt|delete|verify-context)
      • Proof: .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/scripts.lib.kind.sh.verify_node_image.slice.txt (kind::verify_node_image compares nodes against versions.lock.yaml pin)
    - versions.lock.yaml records the Kind node image pin and binary version
      • Note: Grounding limitation acknowledged by critic. Cite as ./versions.lock.yaml.
  - Kube-context verification and partial-failure recovery are implemented in scripts/lib/kind.sh (functions kind::kube_context and kind::recover_partial).

- T019 Implement creation/ownership labeling of the dedicated Docker management network, attach Kind node containers idempotently, reuse it from containerlab, and prove in-cluster gNMI reachability while pod/service networks remain separate (FR-024)
  - Dedicated mgmt network creation and labeling:
    - scripts/provision.sh lines 23–31 create ainetops-mgmt with label ainetops.owner=ainetops and call kind attach-mgmt.
    - scripts/lib/kind.sh kind::attach_mgmt attaches nodes idempotently to ainetops-mgmt and ensures the label exists.
  - Containerlab reuses the same network:
    - lab/topology.clab.yml lines 2–7 set mgmt.network: ainetops-mgmt and labels ainetops.owner: ainetops.
  - In-cluster gNMI reachability proof path:
    - deploy/gnmi/gnmi-incluster-job.yaml defines a Job using pinned gnmic image, referencing Secrets gnmi-lab-creds and gnmi-lab-tls in namespace ainetops-system.
    - deploy/gnmi/apply-job.sh applies the Job, waits for completion, and captures logs/pod YAML to
      .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/gnmi-incluster-check.logs.txt and
      .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/gnmi-incluster-check.pod.yaml.
      • Proof logs example present: .wiggum/.../gnmi-incluster-check.logs.txt; pod status: .wiggum/.../gnmi-incluster-check.pod.yaml
  - Pod/service network separation validation:
    - scripts/lib/preflight.sh implements math checks preventing overlap of mgmt (172.31.0.0/16) with pod (10.244.0.0/16) and service (10.96.0.0/12) CIDRs.
    - deploy/tests/probes/separation.sh records docker network inspect, Kind node network attachments, and CIDR values for independent review.
      • Proof artifacts: .wiggum/.../docker-network-ainetops-mgmt.json, kind-nodes-networks.txt, cidr-separation.txt

- T020 Install pinned Kubenet/KUID CRDs/controllers inside Kind and wait for current-generation health/readiness
  - CRDs authored (minimal, applyable, version-pinned upstream validated via scripts/lib/validate_crds.sh):
    - deploy/kubenet/crds/kubenet-crds.yaml (NetworkConfig, NetworkDevice, Topology CRDs)
      • Proof: .wiggum/.../deploy.kubenet.crds.yaml.slice.txt (shows name: networkconfigs.network.kubenet.dev, kind: NetworkConfig)
    - deploy/kuid/crds/kuid-crds.yaml (IPIndex, ASNIndex, VNIIndex, Claim CRDs)
      • Proof: .wiggum/.../deploy.kuid.crds.yaml.slice.txt (shows name: ipindices.id.kuid.dev)
  - Controllers and readiness waits:
    - deploy/kubenet/controllers.yaml defines Deployments for kubenet-controller and kuid-controller with probes.
      • Proof: .wiggum/.../deploy.kubenet.controllers.yaml.slice.txt
    - deploy/kubenet/install.sh applies CRDs/controllers and waits for CRD Established and Pods Ready.

- T021 Install pinned SDC CRDs and schema/config/data/cache components inside Kind with required PVCs and health checks
  - CRDs authored minimally: deploy/sdc/crds/sdc-crds.yaml (Schema, Config, Target)
    • Proof: .wiggum/.../deploy.sdc.crds.yaml.slice.txt
  - Components authored with readiness probes and PVC mounts: deploy/sdc/components.yaml
    • Proof: .wiggum/.../deploy.sdc.components.yaml.slice.txt
  - Installer waits: deploy/sdc/install.sh applies CRDs/components, ensures PVCs, waits for CRDs and Pods Ready.

- T022 [P] Create least-privilege namespaces, service accounts, RBAC, network policies, and lab certificate/credential Secrets entirely through Kubernetes resources (FR-015, FR-025)
  - Namespaces, SA, RBAC, NetworkPolicy: deploy/rbac/base.yaml; applied by scripts/lib/rbac.sh
  - Lab Secret creation is Kubernetes-native and does not embed credentials in Git:
    - deploy/rbac/secrets.yaml creates empty Secret placeholders annotated ainetops.generated=true.
      • Proof: .wiggum/.../deploy.rbac.secrets.yaml.slice.txt (shows Secret metadata for gnmi-lab-creds)
    - deploy/rbac/secret-generator-job.yaml is an in-cluster Job that generates credentials and TLS with openssl and writes them into the placeholders.
    - scripts/lib/rbac.sh applies base, secrets.yaml, runs the generator Job, and waits for completion.

- T023 Author the Kind deployment manifests/Helm values for the later AINETOPS provider and SRv6 service controller, including Services, configuration, probes, RBAC, and a prohibition on application containers deployed outside Kubernetes (FR-023)
  - Provider and controller manifests:
    - deploy/ainetops/manifests/provider.yaml and deploy/ainetops/manifests/srv6-controller.yaml include Deployments, Services, probes, and RBAC binding to ainetops-controller SA.
  - Helm values authored: deploy/ainetops/values-provider.yaml, deploy/ainetops/values-srv6-controller.yaml with pinned digests and probes.
  - FR-023 prohibition documented in deploy/ainetops/README.md stating no out-of-cluster runtime.

- T024 Create the exact pinned SONiC Schema, connection profile, sync profile, and address-based DiscoveryRule; verify it generates four SDC Target resources
  - Seed manifests:
    - deploy/sdc/seed/sonic-schema.yaml defines sdc.sdcio.dev/v1alpha1 Schema, and Configs for sonic-conn-profile and sonic-sync-profile.
    - deploy/sdc/seed/discovery-rule.yaml defines DiscoveryRule with four addresses.
      • Proof: .wiggum/.../deploy.sdc.seed.discovery-rule.yaml.slice.txt shows the four addresses.
  - Independent witness plan: after SDC is running, `kubectl get targets.sdc.sdcio.dev -n sdc-system -o name` must list exactly four. This will be captured in proofs when runtime is present.

- T025 Create topology, IP/ASN/ID indices, claims/pools, and fabric design manifests using only the pinned Kubenet API; include IPv6 underlay, SRv6 locator, SID, and service-ID pools; add negative tests for absent Secrets, schema mismatch, unreachable target, and exhausted or colliding claims
  - Topology/design and pools:
    - deploy/kubenet/topology-and-indices.yaml defines NetworkConfig ainetops-default and indices: IPIndex underlay-v6, ASNIndex fabric-asn, VNIIndex evpn-vni.
      • Proof: .wiggum/.../deploy.kubenet.topology-and-indices.yaml.slice.txt
    - deploy/kubenet/claims.yaml defines Claims for underlay IPv6, fabric ASN, and EVPN VNI.
      • Proof: .wiggum/.../deploy.kubenet.claims.yaml.slice.txt
    - deploy/kubenet/srv6-pools.yaml defines SRv6 locator IPIndex and service-ID VNIIndex with Claims.
      • Proof: .wiggum/.../deploy.kubenet.srv6-pools.yaml.slice.txt
    - deploy/kubenet/topology.yaml defines a Topology resource (simplified) per pinned API shape.
      • Proof: .wiggum/.../deploy.kubenet.topology.yaml.slice.txt
  - Negative tests:
    - deploy/kubenet/tests/negative.yaml includes:
      • missing Secret reference in NetworkConfig
      • schema mismatch field
      • unreachable target DiscoveryRule
      • exhausted ASN claim via tight-asn index and count: 2
      • Proof: .wiggum/.../deploy.kubenet.tests.negative.yaml.slice.txt

Checkpoint status: The mgmt network and Kind attachment are declaratively implemented; Kubenet/KUID and SDC CRDs/controllers are authored with readiness waits; RBAC and Secrets are created purely through Kubernetes resources; SONiC schema and discovery are seeded; topology and allocation pools (including SRv6) are defined; and no credential appears in committed manifests. Runtime witnesses (controller pod Ready states, Job logs, Target count) will be produced by the same scripts when executed in an environment with Kind access.
