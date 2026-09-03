# Agentic NetOps Developers Guide

This document describes development workflows and responsibilities for the Agentic NetOps SONiC EVPN/VXLAN Fabric implementation.

- Build binaries: make build
- Run envtest: make test-envtest
- Static checks: make test-static
- Verify pins and API shapes: make verify-compat
- Supply-chain checks: make supply-chain; CI also runs deny-list and provenance

## RBAC and field ownership

- Provider uses server-side apply with field manager "agentic-netops-sonic-provider"
- ClusterRole scopes are minimal: events, Kubenet NetworkDevice/status, SDC Config/Target
- Do not widen verbs without justification

## Logging and redaction

- Do not log secrets, usernames, or passwords
- Emit events with reason strings from pkg/reasons; use standard Condition types

## Reproducibility

- All container images are built with CGO_ENABLED=0 (static) and use distroless:nonroot runtime
- Avoid reliance on local state; render deterministically from inputs

## Deny-list policy

- See README for policy summary; run make denylist locally to reproduce CI policy

