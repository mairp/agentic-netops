Agentic NetOps Controllers: SR Linux Provider and SRv6Service

This repository contains two controller binaries built with a pinned Go toolchain and dependencies:

- cmd/srlinux-provider/: Controller manager for the Network intent loop (kubenet Network -> gNMI Set through the fabric-executor) and Kubenet NetworkDevice to SDC Config reconciliation
- cmd/srv6-controller/: Controller manager for SRv6Service with probes and leader election
- controllers/srlprovider/: provider reconciler (package `srlprovider`)
- controllers/srv6service/: SRv6 reconciler scaffold
- api/v1alpha1/: Go types for SRv6Service
- config/crd/bases/agentic-netops.io_srv6services.yaml: Structural CRD

The southbound is a third binary:

- cmd/fabric-executor/: the ONLY write path to the fabric. HTTP on :8084 (`/v1/nodes`,
  `/v1/node/apply`, `/v1/node/verify`), gNMI Set/Get over TLS on each node's
  `172.31.0.x:57400`. It holds the lab credentials (`FABRIC_GNMI_USER`,
  `FABRIC_GNMI_PASS`, `FABRIC_GNMI_CA`) and the node map
  (`FABRIC_NODE_MAP`); the provider never dials a device itself.

Names (kept consistent across manifests, metrics and RBAC):

| Thing | Name |
|---|---|
| Deployment / ServiceAccount / ClusterRole | `agentic-netops-srlinux-provider` |
| Image | `agentic-netops-srlinux-provider:dev` |
| Leader election id, field manager | `agentic-netops-srlinux-provider` |
| Metric subsystem | `agentic_netops_srlprovider_*` |
| Namespaced Role for the intent tier | `srlinux-provider-networks` (namespace `agentic-netops-intent`) |

SRv6 is not applicable on this fabric: the SR Linux 7220 container has no SRv6
data plane, the site pins carry `cap-sai-srv6: "false"`, and the SRv6Service
reconciler reports `Ready=False` with `CapabilityMissing`. `Network` objects
require no SRv6 capability and converge normally.

Pinned dependency set (shared by the binaries, see go.mod):
- Go: go 1.22 (go.mod line 3)
- controller-runtime: v0.17.5
- k8s.io/*: v0.29.x (api 0.29.4, apimachinery 0.29.4, client-go 0.29.4, apiextensions 0.29.2)
- zap/logr: go.uber.org/zap v1.26.0, github.com/go-logr/logr v1.4.1, github.com/go-logr/zapr v1.3.0
- OpenTelemetry API: go.opentelemetry.io/otel v1.24.0
- gNMI southbound: github.com/openconfig/gnmi v0.11.0, google.golang.org/grpc v1.63.2

pkg/version/pins.go documents the pinned toolchain for reference.
