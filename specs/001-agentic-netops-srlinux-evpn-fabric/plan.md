# Implementation Plan: agentic-netops on Nokia SR Linux

**Branch**: `001-agentic-netops-srlinux-evpn-fabric` | **Date**: 2026-09-13 | **Spec**: [spec.md](spec.md)
**Input**: spec.md, research.md, data-model.md, contracts/

## Summary

Replace the SONiC southbound of agentic-netops with a Nokia SR Linux fabric:
containerlab `nokia_srlinux` topology with startup configuration for the
underlay/overlay, gNMI-native fabric-executor, an SR Linux renderer in
`pkg/fabricplan`, SR Linux telemetry paths, updated suites, manifests,
documentation and the recording driver. The intent tier, CRDs, allocation
authority and operator console are untouched except for wording.

## Technical Context

**Language/Version**: Go 1.22 (vendored), Python 3.13 (uv), TypeScript (Node 20)
**Primary Dependencies**: controller-runtime v0.17.5, kubenet/kuid pins, `github.com/openconfig/gnmi` + `google.golang.org/grpc` (new, vendored), gnmic 0.47.0, containerlab 0.79.0, kind v0.27.0
**Storage**: Kubernetes objects; SR Linux running config persisted via `tools system configuration save`
**Testing**: `go test ./tests/unit ./pkg/...`, `go test ./tests/envtest`, `uv run pytest`, `npm run build`, `make test-static`, `make lab-qualify`, `tests/integration/*.sh` (live)
**Target Platform**: Linux host with Docker, kind, containerlab; no KVM
**Project Type**: multi-component platform (Go controllers, Python agents, React UI, bash lifecycle)
**Performance Goals**: a construct converges (`Ready=True`) within the deployer's 1200 s convergence watch; typically < 60 s on SR Linux (gNMI commit is seconds)
**Constraints**: no docker socket on the write path; no SONiC artifact anywhere; jumbo MTU; deterministic renders
**Scale/Scope**: 4 fabric nodes, 4 constructs, 1 site

## Constitution Check

- I (fabric truth): every construct carries gNMI Get checks; `Ready` set only after verify. ✅
- II (fail closed): qualify/verify/supply-chain gates exit non-zero; SRv6 declared not-applicable. ✅
- III (one path): gNMI Set only; executor loses `exec`. ✅
- IV (pins): SR Linux image digest, gnmi Go modules vendored and pinned. ✅
- V (nothing else changes): agents/UI touched for wording and the pool comment only; CRDs untouched. ✅

## Project Structure

```
lab/topology.clab.yml                     nokia_srlinux nodes, startup-config
lab/profiles/srlinux/{profile.yaml,config/*.cfg}
lab/images/                                (SONiC image recipes removed; clients kept)
scripts/{provision.sh,off.sh,install-deps.sh}
scripts/lib/{containerlab,preflight,qualify,persistence,lab_secrets,verify_pins}.sh
scripts/ci/supply_chain.sh
tests/integration/{fabric_verify,srlinux_gnmi_suite,evpn_suite,yang_paths_suite,...}.sh
pkg/fabricplan/plan.go(+_test)            SR Linux renderer
pkg/register/oc_vs_srlinux.yaml
pkg/compat/                               srlinux pins, SRv6 optional
cmd/fabric-executor/                      gNMI backend
cmd/srlinux-provider/, controllers/srlprovider/
deploy/agentic-netops/manifests/provider.yaml
deploy/gnmi/gnmic.yaml, deploy/observability/**
deploy/sdc/seed/srlinux-schema.yaml, deploy/kubenet/**
agents/** (wording, config comments), ui/src/components/MainArea/MainArea.tsx
docs/**, README.md, TUTORIAL.md
testautomation/video/{record.py,accept.py}
versions.lock.yaml, Makefile, .github/workflows/ci.yaml
```

## Phases (mirrors tasks.md)

1. **Foundation (offline)**: pins, topology, startup configs, profile, lifecycle scripts, supply-chain inversion. Verified by `make verify-pins`, `bash -n`, `yq`, `containerlab inspect` (when installed).
2. **Southbound (offline)**: renderer, executor gNMI backend, provider rename, compat pins, register, unit tests. Verified by `go build -mod=vendor -tags agentic_netops_k8s ./...` and `go test`.
3. **Platform surfaces (offline)**: manifests, telemetry, dashboards, agents/UI wording, docs, CI, video driver. Verified by `uv run ruff/pytest`, `npm run build`, `supply_chain.sh`, `python3 -m py_compile`.
4. **Bring-up (live, host)**: `provision.sh --profile srlinux`, capability gate, `fabric_verify.sh`.
5. **Intent tier convergence (live, host)**: `--with-intent-tier`, four constructs to `Ready=True`, drift repair, refusal path.
6. **Walkthrough recording (live, host)**: smoke, rehearsal, final take, `accept.py`.

Phases 1–3 are executed in the authoring session (Opus 5 implementation agents
under a Fable 5.1 spec); phases 4–6 run on the operator's host through the
wiggum orchestrator with the Claude backend pinned to Opus 5
(`docs/HOST_RUNBOOK_WIGGUM_OPUS5.md`). Phase gates 1–3 re-verify offline on the
host before phase 4 starts, so the loop begins from a proven tree.

## Complexity Tracking

| Deviation | Why | Simpler alternative rejected |
|---|---|---|
| New Go deps (gnmi, grpc) vendored | native gNMI client | shelling out to gnmic binds the executor to a host binary; kept only as documented fallback |
| acl-only binds on subinterface 0 | SR Linux binds ACLs to subinterfaces, not ports | refusing acl-only would drop a construct the tier advertises |
