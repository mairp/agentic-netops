# Agentic NetOps SONiC EVPN/VXLAN — Operator and Developer Guide (T075)

This guide covers operator/developer documentation for Phase 8 acceptance: compatibility matrix, resource sizing, image acquisition, EVPN/SRv6 mapping limitations, telemetry pipeline, topology presentation, recovery, and the break-glass finalizer procedure.

## Compatibility matrix

- Source of truth: versions.lock.yaml (immutable pins):
  - Kind binary/node image, Kubernetes version
  - Kubenet/KUID release/commit and API shape
  - SDC releases/commits (core, config-server, schema-server)
  - Containerlab version
  - Tooling images (gNMIc, OTel Collector, Prometheus, Grafana, Grafana Flow plugin)
  - SONiC image digests for profiles and their YANG compatibility mapping
- See: versions.lock.yaml
- Contract: scripts/lib/verify_pins.sh enforces immutability and cross-field consistency. The provider validates SONiC image/schema/mapping compatibility on reconcile and blocks when mismatched (SchemaMismatch) per contracts.

## Resource sizing

Minimum host resources (preflight enforced):
- CPU cores: 4 (AGENTIC_NETOPS_MIN_CPU)
- Memory: 8 GiB (AGENTIC_NETOPS_MIN_MEM_MB=8192)
- Disk free: 20 GiB (AGENTIC_NETOPS_MIN_DISK_MB=20480)

Runtime footprint (reference scale: 2 spines, 2 leaves, 4 endpoints, 1 Kind control-plane node):
- Kind cluster: 1 node (control-plane) using the pinned node image; ~2–3 GiB RAM under load
- Containerlab: 4 SONiC nodes (sonic-vs) + 4 Linux endpoints; requires a Docker-compatible runtime and a host MTU ≥ 1500
- Observability: OTel Collector (~100–200Mi), Prometheus (~256–512Mi with PVC), Grafana (~256–512Mi)

Adjustments:
- The sonic-vm conformance profile requires KVM/nested virtualization and significantly more CPU/RAM. Preflight enforces /dev/kvm when --profile=sonic-vm.

## Image acquisition

- SONiC images are not redistributed in this repository. Operators must acquire and locally import the image whose digest matches versions.lock.yaml.
- The fast profile uses containerlab-supported sonic-vs (pinned digest). The conformance profile uses a locally built sonic-vm image (pinned digest) created with vrnetlab.
- All controller/observability images are pinned by immutable digest in deploy/**.yaml.

## EVPN/SRv6 mapping limitations

- Supported EVPN mappings per spec:
  - VPLS/multipoint L2VPN → EVPN bridge domain with unique L2VNI, attachment VLANs, import/export RTs
  - L3VPN → Tenant VRF with L3VNI, RD/RTs, Type-5 routes where supported
  - VPWS/E-Line → Dedicated two-attachment bridge domain and L2VNI (limited equivalence; not full pseudowire parity)
  - Symmetric IRB for integrated L2/L3
- Unsupported or limited features are rejected with structured findings before any device mutation: RSVP-TE, SR-MPLS policy, pseudowire OAM/control-word, multicast VPN, complex QoS/OAM, service chaining, and unknown properties.
- Translation is all-or-nothing; no partial intent is applied on failure.

## Telemetry pipeline

- gNMIc runs inside the Kind cluster as the sole SONiC device-metric collector. It subscribes to interface, BGP, and SRv6 MySID counters and exports OTLP to the OTel Collector.
- OTel Collector processes and exposes Prometheus scrape endpoints.
- Prometheus scrapes OTel and other instrumented targets and retains metrics on a PVC.
- Grafana uses a provisioned Prometheus datasource and dashboards as code. The Grafana Flow plugin is pinned by digest; anonymous access is disabled; admin credentials are generated at runtime via a Kubernetes Job.
- SDC subscribe is disabled to avoid duplicate device series; only gNMIc provides SONiC metrics.

## Topology presentation

- A versioned topology ConfigMap (deploy/observability/topology-configmap.yaml) is generated from containerlab inspect output and labeled by the orchestration. Grafana’s Flow panel renders a physical fabric view using this ConfigMap and Prometheus metrics.
- Dashboards provided: physical-fabric.json, sdc-orchestration.json, srv6-service-path.json, pipeline-health.json (embedded in deploy/observability/grafana.yaml ConfigMaps).

## Recovery procedures

- Lab qualification failure (sonic-vs):
  - Run make off or scripts/off.sh to cleanly teardown.
  - Re-provision with the sonic-vm conformance profile: scripts/provision.sh --profile sonic-vm.
- Controller or SDC degraded:
  - Inspect Conditions and Events on SRv6Service, NetworkDevice, and SDC Config/Target.
  - The provider blocks downstream writes on schema/compatibility and validation failures and leaves last-known valid desired state intact.
- Metrics pipeline outage:
  - Controllers remain functional; observability alerts indicate OTel/Prometheus/gNMIc issues. See deploy/observability/rules/agentic-netops.rules.yaml alerts for guidance.

## Break-glass finalizer procedure

If a SRv6Service or provider-owned resource is stuck due to external issues and normal deletion does not proceed, remove finalizers explicitly as a last resort and allow the cluster to clean up owned resources:

- SRv6Service finalizer removal (example name: example-srv6):

```bash
kubectl -n default patch srv6service example-srv6 --type=json \
  -p='[{"op":"remove","path":"/metadata/finalizers"}]'
```

- Provider Config finalizer removal (if applicable to provider-created SDC resources):

```bash
kubectl -n sdc-system patch config <name> --type=json \
  -p='[{"op":"remove","path":"/metadata/finalizers"}]'
```

- After break-glass, use scripts/off.sh to complete teardown and ensure no unmanaged resources remain.

## Developer notes

- Do not log secret values. Use structured Conditions and reason strings.
- All images and plugins must be pinned by digest; deny-list CI enforces boundary terms. Run make supply-chain and make denylist locally.
- The only lifecycle implementations are scripts/provision.sh and scripts/off.sh; Make targets are wrappers only.
