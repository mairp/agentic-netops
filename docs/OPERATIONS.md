# Agentic NetOps SR Linux EVPN/VXLAN — Operator and Developer Guide

This guide covers operator/developer documentation: compatibility matrix,
resource sizing, image acquisition, construct mapping limitations, telemetry
pipeline, topology presentation, recovery, and the break-glass finalizer
procedure.

## Compatibility matrix

- Source of truth: `versions.lock.yaml` (immutable pins):
  - kind binary/node image, Kubernetes version
  - Kubenet/KUID release/commit and API shape
  - SDC releases/commits (core, config-server, schema-server)
  - Containerlab version
  - Tooling images (gNMIc, OTel Collector, Prometheus, Grafana, Grafana Flow plugin)
  - The SR Linux image digest and the matching YANG model release
- Contract: `scripts/lib/verify_pins.sh` enforces immutability and cross-field
  consistency. The provider validates the site's image/schema/mapping
  compatibility on reconcile and blocks when mismatched (`SchemaMismatch`) per
  the contracts. SRv6 capability is required only by `SRv6Service` objects, so a
  `Network` reconciles normally on a site pinned `cap-sai-srv6: "false"`.

## Resource sizing

Minimum host resources (preflight enforced):
- CPU cores: 4 (`AGENTIC_NETOPS_MIN_CPU`)
- Memory: 8 GiB (`AGENTIC_NETOPS_MIN_MEM_MB=8192`)
- Disk free: 20 GiB (`AGENTIC_NETOPS_MIN_DISK_MB=20480`)

Runtime footprint (reference scale: 2 spines, 2 leaves, 4 endpoints, 1 kind
control-plane node):
- kind cluster: 1 node (control-plane) using the pinned node image; ~2-3 GiB RAM
  under load
- Containerlab: 4 SR Linux nodes (`nokia_srlinux`, type `ixrd2l`, ~1.5-2 GiB
  each) + 4 Linux endpoints; requires a Docker-compatible runtime and jumbo MTU
  (9216) on the fabric links
- Observability: OTel Collector (~100-200Mi), Prometheus (~256-512Mi with PVC),
  Grafana (~256-512Mi)

There is no KVM requirement and no nested-virtualization profile: the SR Linux
container runs directly on the host kernel, so the conformance/fast profile
split of the previous generation is gone. There is one profile, `srlinux`.

## Image acquisition

- The SR Linux image is public: `docker pull ghcr.io/nokia/srlinux:26.7.2`. Its
  digest is pinned in `versions.lock.yaml` and enforced by `make verify-pins`.
- All controller/observability images are pinned by immutable digest in
  `deploy/**.yaml`.

## Construct mapping limitations

- Supported constructs:
  - **mac-vrf** — EVPN bridge domain with a unique L2VNI, attachment
    subinterfaces and route targets; rendered as a `mac-vrf` network-instance
    with a bridged `vxlan1.<l2vni>` and BGP-EVPN/BGP-VPN.
  - **ip-vrf** — tenant routed instance with an L3VNI, RD/RTs and Type-5
    routes; rendered as an `ip-vrf` network-instance with a routed
    `vxlan1.<l3vni>`.
  - **vlan** — local broadcast domain on a node; a `mac-vrf` network-instance
    with no vxlan-interface.
  - **acl** — an `acl-filter` bound on the input or output side of the service's
    subinterfaces.
  - Legacy names such as VPLS, VPWS/E-Line, L3VPN and IRB are migration aliases
    only and must not be used as operator vocabulary.
- **SRv6 is not applicable on this target** — the SR Linux container has no SRv6
  data plane. `SRv6Service` objects report `Ready=False` with
  `CapabilityMissing`.
- Unsupported or limited features are rejected with structured findings before
  any device mutation: RSVP-TE, SR-MPLS policy, pseudowire OAM/control-word,
  multicast VPN, complex QoS/OAM, service chaining, and unknown properties.
- Translation is all-or-nothing; no partial intent is applied on failure. A
  gNMI Set is itself transactional on SR Linux (candidate + commit per request),
  so a rejected op leaves nothing half-written on the node.

## Telemetry pipeline

- gNMIc runs inside the kind cluster as the sole device-metric collector. It
  subscribes to SR Linux native state paths on `:57400` over TLS — interface
  statistics and oper-state, BGP neighbor session state and received routes,
  platform CPU/memory — and serves them on its own Prometheus endpoint `:9273`.
- Prometheus scrapes gnmic directly and retains metrics on a PVC.
- The OTel Collector carries the intent tier's own telemetry and the pipeline
  health signals, and exposes a Prometheus scrape endpoint.
- Grafana uses a provisioned Prometheus datasource and dashboards as code.
  Anonymous access is disabled; admin credentials are generated at runtime via a
  Kubernetes Job.
- SDC subscribe is disabled to avoid duplicate device series; only gNMIc
  provides device metrics.

The series names follow gnmic's default path-joined convention and are listed in
`deploy/observability/metrics-inventory.md`, which also carries the command to
verify them against a running collector. They have not yet been read off a live
SR Linux node from this tree.

## Topology presentation

- A versioned topology ConfigMap
  (`deploy/observability/topology-configmap.yaml`) is generated from
  `containerlab inspect` output by
  `scripts/observability/gen-topology-configmap.sh`, which normalises port names
  to the device-side form (`e1-3` → `ethernet-1/3`) so they join the
  `interface_name` label. Grafana's Flow panel renders a physical fabric view
  from this ConfigMap and the Prometheus metrics.
- Dashboards provided: `fabric-telemetry.json`, `physical-fabric.json`,
  `sdc-orchestration.json`, `srv6-service-path.json` (marked not applicable) and
  `pipeline-health.json`, embedded in the `grafana-dashboards` ConfigMap in
  `deploy/observability/grafana.yaml`.

## Recovery procedures

- **Lab qualification failure**: read the named failing check in the report —
  the gate fails closed and prints it. Run `scripts/off.sh` for a clean
  teardown and re-provision; a startup-configuration or gNMI-path correction
  belongs in the tree files, never as a manual change on a node.
- **Controller or SDC degraded**: inspect Conditions and Events on the
  `Network`, `NetworkDevice` and SDC `Config`/`Target`. The provider blocks
  downstream writes on schema/compatibility and validation failures and leaves
  the last-known valid desired state intact.
- **Node restart**: SR Linux keeps its committed configuration across a
  container restart, and the executor saves after every successful apply; the
  5-minute resync repairs any residual drift.
- **Metrics pipeline outage**: controllers remain functional; the observability
  alerts indicate OTel/Prometheus/gNMIc issues. See
  `deploy/observability/rules/agentic-netops.rules.yaml`.

## Break-glass finalizer procedure

If a provider-owned resource is stuck due to external issues and normal deletion
does not proceed, remove finalizers explicitly as a last resort and allow the
cluster to clean up owned resources:

- `SRv6Service` finalizer removal (example name: `example-srv6`):

```bash
kubectl -n default patch srv6service example-srv6 --type=json \
  -p='[{"op":"remove","path":"/metadata/finalizers"}]'
```

- Provider Config finalizer removal (if applicable to provider-created SDC
  resources):

```bash
kubectl -n sdc-system patch config <name> --type=json \
  -p='[{"op":"remove","path":"/metadata/finalizers"}]'
```

Break-glass skips the controller's ordered rollback, so the service's device
objects are left in place. Afterwards, use `scripts/off.sh` to complete teardown
and confirm on the leaf that no orphaned network-instance, vxlan-interface,
subinterface or acl-filter remains:

```bash
docker exec clab-agentic-netops-fabric-leaf01 sr_cli "show network-instance summary"
docker exec clab-agentic-netops-fabric-leaf01 sr_cli "show acl summary"
```

## Developer notes

- Do not log secret values. Use structured Conditions and reason strings.
- All images and plugins must be pinned by digest; the deny-list CI job enforces
  boundary terms. Run `make supply-chain` and `make denylist` locally.
- The only lifecycle implementations are `scripts/provision.sh` and
  `scripts/off.sh`; Make targets are wrappers only.
