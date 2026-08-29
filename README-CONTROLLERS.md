AINETOPS Controllers: SONiC Provider and SRv6Service

This repository contains two controller binaries built with a pinned Go toolchain and dependencies:

- cmd/sonic-provider/: Controller manager for Kubenet NetworkDevice to SDC Config reconciliation
- cmd/srv6-controller/: Controller manager for SRv6Service with probes and leader election
- controllers/sonicprovider/: provider reconciler
- controllers/srv6service/: SRv6 reconciler scaffold
- api/v1alpha1/: Go types for SRv6Service
- config/crd/bases/ainetops.io_srv6services.yaml: Structural CRD

Pinned dependency set (shared by both binaries, see go.mod):
- Go: go 1.22 (go.mod line 3)
- controller-runtime: v0.17.5
- k8s.io/*: v0.29.x (api 0.29.4, apimachinery 0.29.4, client-go 0.29.4, apiextensions 0.29.2)
- zap/logr: go.uber.org/zap v1.26.0, github.com/go-logr/logr v1.4.1, github.com/go-logr/zapr v1.3.0
- OpenTelemetry API: go.opentelemetry.io/otel v1.24.0

pkg/version/pins.go documents the pinned toolchain for reference.
