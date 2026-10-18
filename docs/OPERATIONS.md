# Agentic NetOps SONiC EVPN/VXLAN — Operator and Developer Guide

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

## Fabric write path per node kind

The fabric-executor is the only southbound write path (host service on the kind
bridge gateway, port 8084). Every node it serves has exactly one transport, and
`GET /v1/nodes` names each node with its kind — the output below is the
authoritative statement of which write path applies where:

| Node kind (`/v1/nodes`) | Profile | Write path | Privilege | Durable FRR file |
| --- | --- | --- | --- | --- |
| `docker` | sonic-vs | `docker exec` into the SONiC VS container over the host docker socket | root in the container | `/etc/frr/bgpd.conf` |
| `ssh` | sonic-vm | SSH into the SONiC guest (per-lab key under `secrets/`, BatchMode, strict host key) | `sudo -n` | `/etc/sonic/frr/bgpd.conf` |

- Reads (telemetry) never use the executor: gNMI via gNMIc is the only
  device-metric collector, and it is read-only.
- GCU patches travel as the applied command's stdin payload on both kinds.
- Provisioning builds the executor's transport map from each node container's
  `clab-node-kind` label (`scripts/provision.sh`); a node without an ssh entry
  uses `docker`.

## EVPN/SRv6 mapping limitations

- Supported EVPN constructs:
  - mac‑vrf (datacenter L2 over EVPN) — EVPN bridge domain with unique L2VNI, attachment VLANs, route targets.
  - ip‑vrf (datacenter L3 instance) — Tenant VRF with L3VNI, RD/RTs, Type‑5 routes where supported.
  - vlan — local broadcast domain on a node.
  - acl — filter bound to service ports at INGRESS/EGRESS.
  - Legacy names such as VPLS, VPWS/E‑Line, L3VPN, IRB are migration aliases only and must not be used as operator vocabulary (migration alias).
- Unsupported or limited features are rejected with structured findings before any device mutation: RSVP‑TE, SR‑MPLS policy, pseudowire OAM/control‑word, multicast VPN, complex QoS/OAM, service chaining, and unknown properties.
- Translation is all‑or‑nothing; no partial intent is applied on failure.

## Telemetry pipeline

- gNMIc runs inside the Kind cluster as the sole SONiC device-metric collector. It subscribes to interface and BGP paths and exports OTLP to the OTel Collector. There is no SRv6 counter subscription: the pinned image serves no such counters (`COUNTERS_SRV6_NAME_MAP` is empty — proof `spike-counters`), so the SRv6 dashboards and alerts do not run on gNMIc series.
- The SRv6Service controller emits its own gauges on :8081 (scraped via the pod's `prometheus.io/scrape` annotation): `agentic_netops_srv6_locator_state`, `agentic_netops_srv6_sid_state`, `agentic_netops_srv6_active_path`.
- The fabric-executor exposes two kernel forwarding-counter families on its own /metrics: `fabric_executor_srv6_sid_packets_total{node,sid,direction}` — the kernel per-SID counters, kept by the End.DT46 decap route because the plan installs it with the seg6local `count` flag (visible as `packets N bytes M errors 0` on the route line of `ip -s -6 route show`); this is the series the SRv6 dashboard plots — and `fabric_executor_node_vrf_packets_total{node,device,direction}`, the coarser VRF-device companion granularity. Both are read at scrape time through the executor's node transports.
- OTel Collector processes and exposes Prometheus scrape endpoints.
- Prometheus scrapes OTel, the annotated controller pods, and the host-side fabric-executor (through the `kind` bridge gateway address — the executor holds the lab's SSH keys, so it is not a pod; a `FabricExecutorDown` alert watches the scrape), and retains metrics on a PVC.
- Grafana uses a provisioned Prometheus datasource and dashboards as code. The Grafana Flow plugin is pinned by digest; anonymous access is disabled; admin credentials are generated at runtime via a Kubernetes Job.
- SDC subscribe is disabled to avoid duplicate device series; only gNMIc provides SONiC metrics.

## Topology presentation

- A versioned topology ConfigMap (deploy/observability/topology-configmap.yaml) is generated from containerlab inspect output and labeled by the orchestration. Grafana’s Flow panel renders a physical fabric view using this ConfigMap and Prometheus metrics.
- Dashboards provided: physical-fabric.json, sdc-orchestration.json, srv6-service-path.json, pipeline-health.json (embedded in deploy/observability/grafana.yaml ConfigMaps).

## SRv6Service states an operator will see

The `Ready` condition's reason is the contract (specs/004-srv6-service-requests
data-model §6); each message names the node and check where one applies:

| Reason | Ready | Meaning |
| --- | --- | --- |
| `Verified` | True | every per-node check passed and the data path passed at first activation; re-verified every ~5 min |
| `InvalidSite` | False (terminal) | unknown node, port or spine; message lists the valid names |
| `PortInUse` | False (terminal) | an attachment port belongs to another service; message names it |
| `CapabilityMissing` | False (terminal) | the capability record is not `"true"`, absent or unreadable |
| `UnsupportedVariant` | False (terminal) | construct/signalling pair outside the delivered set (e.g. ip-vrf over srv6 with evpn signalling, mac-vrf over srv6); message names it |
| `PoolExhausted` | False (terminal) | an identifier pool ran out; message names the pool, partial claims released |
| `ApplyFailed` | False | a node failed to apply; rolled back on every node |
| `CheckFailed` | False | a per-node verification check failed; message names node and check |
| `LocatorMissing` | False | the bootstrap-owned locator is absent or changed; never recreated by the controller |
| `DataPathFailed` | False | device state correct, client traffic does not pass |
| `DataPathUnverifiable` | False (terminal) | no probe host registered for an attachment; decided before any claim |
| `VlanInUse` | False (terminal) | the named VLAN of a mac-vrf is reserved elsewhere; no device write |
| `PathDown` | False | a steered service has neither path usable |
| `Finalizing` | False | delete in progress; message names the nodes not yet clean |

A steered service reports its current path in `status.activePath`
(preferred/alternate spine). Requests that type a locator, SID or VRF
themselves are refused — identifiers are pool-claimed only, never typed.

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

- SRv6Service finalizer removal (example name: srv6-ip-vrf-vpn in namespace agentic-netops-intent):

```bash
kubectl -n agentic-netops-intent patch srv6service srv6-ip-vrf-vpn --type=json \
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
