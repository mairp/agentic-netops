# Security Audit

This document records the security audit of RBAC verbs/scopes, Secret use, TLS
validation, image privileges, Docker trust boundaries, Grafana plugin
provenance, anonymous access/default credentials, and log/status redaction, for
the Nokia SR Linux target.

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
  - deploy/gnmi/gnmic.yaml uses secretKeyRef for GNMIC_USERNAME/PASSWORD and
    mounts the lab CA; skip-verify: false and tls-ca set
  - deploy/observability/grafana.yaml uses Secret grafana-admin for admin credentials

## TLS validation

- gNMIc enforces TLS with JSON_IETF encoding and skip-verify: false; the trust
  bundle is mounted from Secret gnmi-lab-tls (deploy/gnmi/gnmic.yaml). The
  SR Linux gNMI server presents the containerlab-generated server certificate
  and authenticates the client with username/password, so no client certificate
  is required and none is mounted; the Secret keeps tls.crt/tls.key for API
  compatibility with consumers that still expect them.
- The fabric-executor uses the same CA file (FABRIC_GNMI_CA) and the same
  generated credentials (FABRIC_GNMI_USER/FABRIC_GNMI_PASS) for both Set and
  Get. It holds no docker socket: on this target the write path is gNMI only,
  which removes the previous generation's most privileged mount from the
  executor entirely.

## Device credentials

- The SR Linux image's default admin credentials are used exactly once, by
  `scripts/lib/containerlab.sh bootstrap`, to create the generated user
  `agentic` over a single gNMI Set on
  `/system/aaa/authentication/user[username=agentic]`. They are read from the
  environment (SRLINUX_ADMIN_PASSWORD), never written to disk and never stored
  in a Secret.
- The generated password lives only in Secret gnmi-lab-creds and the
  containerlab CA in Secret gnmi-lab-tls, both in agentic-netops-system. No
  credential literal appears in any manifest; CI's no-credential-literals job
  enforces it.

## Image privileges and container hardening

- Controllers and workloads run as non-root, drop all capabilities, and use read-only root filesystems where applicable:
  - deploy/agentic-netops/manifests/provider.yaml sets runAsNonRoot, allowPrivilegeEscalation: false, readOnlyRootFilesystem: true, and capabilities: drop: ["ALL"]
  - cmd/srlinux-provider/Dockerfile and cmd/srv6-controller/Dockerfile use
    minimal bases; security review proof slices were captured during the audit

## Docker trust boundaries

- Preflight requires a Docker-compatible runtime. There is no KVM requirement
  and no privileged virtualization profile on this target: the SR Linux
  container runs on the host kernel, so the /dev/kvm check of the previous
  generation is gone rather than merely unused.
  - scripts/lib/preflight.sh: preflight::runtime_privileges
- The intent tier has no route to the fabric. NetworkPolicy/allow-egress-scoped
  in deploy/agents/namespace-rbac.yaml excludes 172.31.0.0/16 from every egress
  rule, and deploy/agents/tests/probes/mgmt-network-denial.sh attempts the
  connection to 172.31.0.21:57400 and asserts it fails. Only the system-tier
  provider carries allow-fabric-gnmi-egress (172.31.0.0/16 port 57400).

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
- TLS: gNMIc validates TLS (skip-verify: false) against the lab CA.
- Device credentials: image default used once to create the generated user,
  never stored; generated credentials live only in Secrets.
- Hardening: non-root, no privilege escalation, RO rootfs, capabilities dropped.
- Trust boundaries: Docker required; no KVM; no docker socket on the write path;
  the intent tier is provably unable to reach the management subnet.
- Provenance: Grafana plugin pinned by digest; anonymous disabled.
- Exposure: Prometheus avoids remote write receiver; in-cluster only.
