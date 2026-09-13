# Agentic NetOps Operators Guide

Applies to: the Agentic NetOps **Nokia SR Linux** EVPN/VXLAN fabric managed by
this repository.

This document provides operator-facing procedures and acceptance expectations
for the Agentic NetOps SR Linux EVPN/VXLAN fabric reference.

Contents:
- Compatibility matrix and pins
- Resource sizing
- Image acquisition
- Construct mapping and its limits
- Telemetry pipeline and topology presentation
- Recovery and break-glass finalizer procedure
- Operator quickstart and lifecycle commands

## Compatibility matrix and pins

All platform versions are pinned in `versions.lock.yaml` and verified by
`make verify-compat`.
- Kubernetes, controller-runtime, Go toolchain
- Kubenet/KUID release and commit (single API shape)
- SDC (core/config-server/schema-server releases)
- Containerlab version
- SR Linux image (`srlinux_images.srlinux`, pinned by manifest digest) and the
  matching YANG model release (`srlinux_yang`)
- Tooling images (gNMIc, OTel Collector, Prometheus, Grafana, Flow plugin)
  pinned by digest

The site's own pins are published in the `fabric-compat-pins` ConfigMap:
`srlinux-image`, `srlinux-yang`, `mapping-version`, `kubenet-commit`,
`kuid-commit`, `sdc-release`, the two label contracts, and `cap-sai-srv6`
(which is `"false"` on this site).

See: `versions.lock.yaml` · Run: `make verify-compat`

## Resource sizing

Reference lab (4 SR Linux nodes + 4 Linux endpoints):
- Host CPU: 8 vCPU minimum (16 recommended)
- Host memory: 16 GiB minimum (32 GiB recommended); each SR Linux container
  takes roughly 1.5-2 GiB
- Disk: 40 GiB free (logs, images, PVCs)
- kind cluster: 1 control-plane node
- Prometheus PVC: 5 GiB (configurable)
- No KVM and no nested virtualization required

Preflight enforces minimal CPU/RAM/disk and tool versions.

## Image acquisition

- SR Linux: pull the pinned public image
  (`versions.lock.yaml` → `srlinux_images.srlinux.image`) with
  `docker pull ghcr.io/nokia/srlinux:26.7.2`; `make verify-pins` fails if the
  local digest drifts from the lock file.
- All other platform images are pulled by Kubernetes from pinned digests.

There is no operator-built image in the fabric path: the distribution is fully
open source and runs on the public `ghcr.io/nokia/srlinux` image.

## Construct mapping and its limits

- **vlan** — a local mac-vrf network-instance (`vlan-<id>`) with a single-tagged
  bridged subinterface on the attachment interface.
- **mac-vrf** — the same, plus a bridged `vxlan1.<l2vni>` vxlan-interface and
  BGP-EVPN/BGP-VPN on the network-instance, so the domain stretches between
  leaves over EVPN.
- **ip-vrf** — a routed network-instance with a routed subinterface carrying the
  first host of the declared prefix, a routed `vxlan1.<l3vni>` and BGP-EVPN,
  originating an EVPN Type-5 route for the prefix.
- **IRB (mac-vrf with an anycast gateway)** — composes the integrated L2/L3 case
  through an `irb0.<vlan>` subinterface with `anycast-gw`.
- **acl** — an `acl-filter` (`ipv4` or `ipv6`) with the declared entries, bound
  on the input or output side of every subinterface the service renders on that
  interface.

Limits:
- **SRv6 is not applicable on this site.** The SR Linux container has no SRv6
  data plane. `SRv6Service` objects report `Ready=False` with reason
  `CapabilityMissing`; the capability gate records SRv6 entries as
  `not-applicable` with that reason. Nothing fakes an SRv6 success.
- An **acl-only** `Network` has no subinterface of its own, so its filter is
  bound on subinterface index 0 of the named interface, created as `type routed`
  in the `default` network-instance when absent.
- ICMPv6 as an ACL protocol is refused (parity with the previous generation).
- RSVP-TE, SR-MPLS policies, pseudowire OAM/control-word, multicast VPN and
  complex QoS/OAM are unsupported.
- Only qualified paths are rendered; an unsupported field rejects the
  translation before any device change.
- An `l3vni` outside the 10000-14094 band has no attachment subinterface tag to
  derive and is refused by name rather than rendered.

## Telemetry pipeline and topology presentation

- gNMIc runs in-cluster and subscribes to the four SR Linux targets on
  `172.31.0.x:57400` over TLS (interface statistics and oper-state, BGP neighbor
  session state and received routes, platform CPU/memory). It serves its own
  Prometheus endpoint on `:9273`, which Prometheus scrapes directly.
- The OTel Collector handles pipeline health and non-device sources and exports
  to Prometheus (the in-cluster metrics store).
- Grafana consumes Prometheus and the generated topology ConfigMap
  (`monitoring/agentic-netops-topology`) to render orchestration, pipeline
  health and topology views.

See the manifests under `deploy/observability/` and `deploy/gnmi/`, and the
series inventory in `deploy/observability/metrics-inventory.md`.

## Operator quickstart and lifecycle commands

- Provision: `./scripts/provision.sh --profile srlinux --cluster-name agentic-netops`
- Teardown: `./scripts/off.sh --cluster-name agentic-netops [--delete-kind true] [--capture-evidence true]`
- Capability gate: `make lab-qualify` (blocks downstream on failure)
- Fabric verification: `./tests/integration/fabric_verify.sh run`
- Read-only device proofs:
  `docker exec clab-agentic-netops-fabric-leaf01 sr_cli "show network-instance summary"`

## Credentials

The image's default admin credentials are used exactly once, by the bootstrap
step, to create the generated user `agentic` over one gNMI Set; they are never
stored. The generated password lives in Secret `gnmi-lab-creds` and the
containerlab CA in Secret `gnmi-lab-tls` (key `ca.crt`), both in
`agentic-netops-system`. No credential literal appears in any manifest.

## Recovery procedures

- **Idempotence**: re-run `scripts/provision.sh` to converge to Ready;
  unchanged intent results in no SDC spec write and no gNMI Set (verified by
  tests).
- **Drift**: a converged service is re-applied and re-verified on the 5-minute
  resync, so a hand edit or a node restart is repaired without operator action.
- **Partial failures**: controllers surface `Degraded` and the node's own error
  text; recover by fixing the cause and re-running provision.
- **Teardown**: `scripts/off.sh` is safe from any partial state; it removes the
  containerlab lab, optionally deletes the kind cluster, removes the owned
  Docker network and cleans up lab-generated secrets.

## Break-glass finalizer procedure

Controllers add `agentic-netops.dev/finalizer` to owned resources to delete
downstream SDC intent first. If a controller or the API becomes permanently
broken, an operator may break-glass:

1) Inspect finalizers:
   `kubectl get networkdevices.network.kubenet.dev -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name} {.metadata.finalizers}\n{end}'`

2) Remove the finalizer, explicitly acknowledging loss of managed cleanup:
   `kubectl -n <ns> patch networkdevice <name> --type=json -p='[{"op":"remove","path":"/metadata/finalizers"}]'`

This skips ordered deletion of SDC intent and should be followed by a manual
cleanup of any residual SDC Config resources — and, on the device, of the
network-instance, vxlan-interface, subinterfaces and acl objects the service
created.
