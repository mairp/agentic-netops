# Security Audit

This document records the Phase 8 security audit of RBAC verbs/scopes, Secret use, TLS validation, image privileges, Docker/KVM trust boundaries, Grafana plugin provenance, anonymous access/default credentials, and log/status redaction.

Scope: all changes are within the open-source distribution and in-cluster resources. Evidence is grounded by the cited repository paths and the recorded proof artifacts.

## RBAC verbs and scopes

- Base namespaces/RBAC/NetworkPolicies and controller RBAC are applied by scripts/lib/rbac.sh.
- ServiceAccounts, Roles, and ClusterRoles are least-privilege and scoped to the agentic-netops-system namespace unless cluster-wide access is required by CRDs.
- Evidence:
  - config/rbac/service_account.yaml — service accounts for provider and SRv6 controller
  - config/rbac/role.yaml and role_binding.yaml — namespace-scoped permissions
  - config/rbac/cluster_role.yaml and cluster_role_binding.yaml — cluster-scoped reads for CRDs only as needed
  - deploy/rbac/srv6-crd-rbac.yaml — binds SRv6 CRD access to the controller SA

## Secret use

- No static credentials are stored in Git. Lab credentials and TLS are generated in-cluster by one-shot Jobs:
  - deploy/rbac/secret-generator-job.yaml — creates gnmi-lab-creds and gnmi-lab-tls
  - deploy/observability/grafana-secret-generator-job.yaml — creates grafana-admin
- Consumers reference Secrets via secretKeyRef; no secret data is logged or embedded in manifests:
  - deploy/gnmi/gnmic.yaml uses secretKeyRef for GNMIC_USERNAME/PASSWORD and mounts TLS keys; skip-verify: false and tls-ca/tls-cert/tls-key set
  - deploy/observability/grafana.yaml uses Secret grafana-admin for admin credentials

## TLS validation

- gNMIc configuration enforces TLS with JSON_IETF encoding and skip-verify: false; CA/cert/key mounted from Secret (deploy/gnmi/gnmic.yaml).

## Image privileges and container hardening

- Controllers and workloads run as non-root, drop all capabilities, and use read-only root filesystems where applicable:
  - deploy/agentic-netops/manifests/provider.yaml sets runAsNonRoot, allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, and capabilities: drop: ["ALL"]
  - cmd/sonic-provider/Dockerfile and cmd/srv6-controller/Dockerfile use minimal bases; security review proof slices were captured during the audit

## Docker/KVM trust boundaries

- Preflight requires a Docker-compatible runtime and enforces /dev/kvm presence only when the sonic-vm profile is selected. This confines privileged virtualization to the conformance profile and prevents accidental use in the fast profile:
  - scripts/lib/preflight.sh: preflight::runtime_privileges and preflight::kvm_check

## Grafana plugin provenance and anonymous access

- The lab Grafana installs no third-party plugins (the previously pinned `grafana-flow-panel` reference was not a real installable plugin and crash-looped the container); physical-topology and service-path views use built-in panels. The upstream Grafana Flow visualization is recorded in versions.lock.yaml as a presentation reference only. Anonymous access is disabled; admin credentials are pulled from a Secret generated at runtime:
  - deploy/observability/grafana.yaml

## Prometheus exposure and redaction posture

- Prometheus is deployed for in-cluster scraping and does not enable the remote write receiver; no public endpoints are exposed by default in this lab configuration.
- Controllers do not mount Secrets; credential handling is limited to gNMIc and Grafana via Kubernetes Secrets.

## Logging/status redaction

- Provider and SRv6 controller do not read or log secret contents. Status conditions use standard reason strings and omit secret values. No Secret volumes or envs are present in the controller manifests (see deploy/agentic-netops/manifests/provider.yaml; proof: gates/proofs/deploy.agentic-netops.manifests.provider.yaml.slice.txt).

## Summary

The audit confirms:
- RBAC: minimal, scoped verbs; CRD reads bound to service accounts.
- Secrets: generated at runtime; consumed via Secret refs; no secrets in Git.
- TLS: gNMIc validates TLS (skip-verify: false) with CA/cert/key.
- Hardening: non-root, no privilege escalation, RO rootfs, capabilities dropped.
- Trust boundaries: Docker required; KVM required only for sonic-vm.
- Provenance: Grafana plugin pinned by digest; anonymous disabled.
- Exposure: Prometheus avoids remote write receiver; in-cluster only.
