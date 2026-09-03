# Agentic NetOps Operators Guide

Applies to: the Agentic NetOps SONiC EVPN/VXLAN fabric managed by this repository.

This document provides operator-facing procedures and acceptance expectations for the Agentic NetOps SONiC EVPN/VXLAN Fabric reference.

Contents:
- Compatibility matrix and pins
- Resource sizing
- Image acquisition
- EVPN/SRv6 mapping limitations
- Telemetry pipeline and topology presentation
- Recovery and break-glass finalizer procedure
- Operator quickstart and lifecycle commands

## Compatibility matrix and pins

All platform versions are pinned in versions.lock.yaml and verified by make verify-compat.
- Kubernetes, controller-runtime, Go toolchain
- Kubenet/KUID release and commit (single API shape)
- SDC (core/config-server/schema-server releases)
- Containerlab version
- SONiC images (sonic_vs, optional sonic_vm) and their YANG compatibility
- Tooling images (gNMIc, OTel Collector, Prometheus, Grafana, Flow plugin) pinned by digest

See: versions.lock.yaml
Run: make verify-compat

## Resource sizing

Reference lab (8 SONiC nodes + 4 Linux endpoints):
- Host CPU: 8 vCPU minimum (16 recommended)
- Host Memory: 16 GiB minimum (32 GiB recommended)
- Disk: 40 GiB free (logs, images, PVCs)
- Kind cluster: 1 control-plane node
- Prometheus PVC: 5 GiB (configurable)

Preflight enforces minimal CPU/RAM/disk and tool versions.

## Image acquisition

- SONiC VS: import the pinned container image (versions.lock.yaml.sonic_images.sonic_vs.image)
- SONiC VM (optional conformance profile): build via vrnetlab and record digest in versions.lock.yaml; requires KVM (/dev/kvm) and nested virtualization
- All other platform images are pulled by Kubernetes from pinned digests

## EVPN/SRv6 mapping limitations

- VPWS/E-Line is represented by a dedicated 2-attachment L2VNI; full pseudowire/RFC 8214 feature parity is NOT claimed
- RSVP-TE, SR-MPLS policies, pseudowire OAM/control-word, multicast VPN, and complex QoS/OAM are unsupported
- Only qualified YANG paths are rendered; unsupported fields reject the translation before any device change

## Telemetry pipeline and topology presentation

- gNMIc runs in-cluster and subscribes to SONiC targets; it exports OTLP to the OTel Collector
- OTel Collector normalizes and exports to Prometheus (in-cluster metrics store)
- Grafana consumes Prometheus and the generated topology ConfigMap (monitoring/agentic-netops-topology) to render orchestration, pipeline health, and topology views

See manifests under deploy/observability/ and deploy/gnmi/

## Operator quickstart and lifecycle commands

- Provision: ./scripts/provision.sh --profile sonic-vs --cluster-name agentic-netops
- Teardown: ./scripts/off.sh --cluster-name agentic-netops [--delete-kind true] [--capture-evidence true]
- Capability gate: make lab-qualify (blocks downstream on failure)

## Recovery procedures

- Idempotence: re-run scripts/provision.sh to converge to Ready; unchanged intent results in no SDC spec write (verified by tests)
- Partial failures: controllers surface Degraded and exact target errors; recover by fixing cause and re-running provision
- Teardown: scripts/off.sh is safe from any partial state; it removes the containerlab lab, optionally deletes the Kind cluster, removes the owned Docker network, and cleans up lab-generated secrets

## Break-glass finalizer procedure

Controllers add agentic-netops.dev/finalizer to owned resources to delete downstream SDC intent first. If a controller or the API becomes permanently broken, an operator may break-glass:

1) Inspect finalizers:
   kubectl get networkdevices.network.kubenet.dev -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name} {.metadata.finalizers}\n{end}'

2) Remove the finalizer explicitly acknowledging loss of managed cleanup:
   kubectl -n <ns> patch networkdevice <name> --type=json -p='[{"op":"remove","path":"/metadata/finalizers"}]'

This skips ordered deletion of SDC intent and should be followed by a manual cleanup of any residual SDC Config resources.
