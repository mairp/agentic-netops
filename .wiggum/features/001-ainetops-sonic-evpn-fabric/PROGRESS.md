done:
  - T001 Directory skeleton created per plan.md; scripts/provision.sh and scripts/off.sh added; shared script helpers in scripts/lib/; Makefile with verify-pins; versions.lock.yaml with immutable pins; validate_crds.sh updated.
  - T006 Top-level Makefile present and wired verify-pins to scripts/lib/verify_pins.sh.
  - T007 Preflight strengthened: address conflict overlap math and tool version checks against versions.lock.yaml; invoked from scripts/provision.sh.
  - T008 validate_crds.sh now passes multiple files correctly (-f per URL); run log proof captured.
  - T009 lab/topology.clab.yml: includes mgmt.network ainetops-mgmt, mgmt.labels ainetops.owner/topology, MTU 9216, explicit links, interface mapping, annotations; defaults.labels added for container labeling.
  - T010 sonic-vs profile created: lab/profiles/sonic-vs/profile.yaml with minimal bootstrap (TLS, gNMI, /etc/sonic persistence) and pinned image digest.
  - T011 sonic-vm conformance overlay created with KVM/nested requirements documented; lab/profiles/sonic-vm/README.md and profile.yaml referencing /dev/kvm.
  - T012 Linux endpoint images/configuration present in lab/topology.clab.yml and lab/clients/README.md with deterministic dual-stack addressing and SRv6 clients per leaf.
  - T013 gNMI Capabilities/Get/Set/Subscribe tests implemented; fixed gnmic arg propagation to include TLS, creds, JSON_IETF; sonic-srv6 FR-003 path tested.
  - T014 Persistent configuration qualification implemented via scripts/lib/persistence.sh restart+verify and YANG path suite lab/requirements/yang-paths.txt.
  - T015 EVPN/SRv6 tests enhanced to probe specific OpenConfig EVPN route-table types and sonic-srv6 behavior/counter tables.
  - T016 make lab-qualify gates downstream, writes machine-readable report at .wiggum/.../qualify.report.json, fails on any test failure.
  - T017 containerlab deploy/inspect/destroy idempotent helpers implemented; destroy verifies no leftover containers, volumes, or generated creds.
  - T018 Kind cluster config updated with pinned node image, ports, mounts; scripts/lib/kind.sh implements idempotent create/delete, kube-context verification, and mgmt-network attachment with partial-failure recovery; scripts/provision.sh calls it.
  - T019 Dedicated Docker mgmt network creation/labeling reused and Kind nodes attached idempotently; containerlab shares the same labeled network; deploy/gnmi/gnmi-incluster-job.yaml with apply script and proof log capture validates in-cluster gNMI reachability; separation probe added.
  - T020 Kubenet/KUID install now applies minimal CRDs and controller Deployments and waits for pod readiness.
  - T021 SDC CRDs and Deployments for schema/config/data/cache added with PVCs and readiness waits.
  - T022 Least-privilege namespaces, ServiceAccounts, RBAC, NetworkPolicy, and Kubernetes-native lab Secrets (gnmi-lab-creds, gnmi-lab-tls) applied via scripts/lib/rbac.sh.
  - T023 Provider and SRv6 controller Deployment/Service manifests and Helm values authored; contract FR-023 prohibition documented.
  - T024 Pinned SONiC Schema, connection profile, sync profile, and address-based DiscoveryRule authored under deploy/sdc/seed/.
  - T025 Kubenet topology/indices/pools manifests plus SRv6 pools/claims and negative tests for absent Secrets, schema mismatch, unreachable target, and exhausted claims.
verified:
  - Proof slices added for config/kind/cluster.yaml, scripts/lib/kind.sh, Kubenet/KUID and SDC CRDs/controllers, SDC seed resources, RBAC Secrets, gNMI Job, Kubenet topology/indices/claims/SRv6 pools.
  - T019 separation artifacts present: gates/proofs/docker-network-ainetops-mgmt.json, kind-nodes-networks.txt, cidr-separation.txt; lab/topology.clab.yml proves mgmt.network ainetops-mgmt and ownership labels.
  - T020/T021 effect-witness artifacts present: kubectl-get-crds-*.txt, kubectl-get-pods-*.txt, kubectl-get-pvc-sdc.txt.
  - T024 target discovery witness present: kubectl-get-targets-names.txt (exactly 4) and kubectl-get-targets.txt (TOTAL=4).
  - T025 readiness and negative test artifacts present: kubectl-get-kuid-resources.txt, kubectl-get-topology.txt, negative-*.status.txt.
blocked:
  - none
next:
  - N/A for Phase 3; evidence written upon verification.
