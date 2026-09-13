Pinned manifests (or Helm values) for the kubenet and kuid CRDs/controllers
installed inside kind.

Per contract:
- All Kubernetes resources are installed inside kind.
- Versions are pinned by commit/release in `versions.lock.yaml`.
- Installation occurs via `scripts/provision.sh` after the kind cluster is ready.

What is here:
- `crds/kubenet-crds.yaml` — the `Network`, `NetworkConfig` and related CRDs.
  The intent schema is unchanged by the SR Linux migration: `Network` still
  declares routers, bridgeDomains, vlans, attachments and accessLists, and the
  construct vocabulary is still vlan / mac-vrf / ip-vrf / acl. Only the device
  side of the render changed.
- `topology.yaml` — the four Nokia SR Linux fabric nodes and their roles.
- `networks/` — the default network and the tenant examples (`l2-bridged`,
  `l3-routed`, `irb-symmetric`).
- `claims.yaml`, `topology-and-indices.yaml`, `srv6-pools.yaml` — kuid indices
  and claims. The SRv6 pools are retained for API compatibility; SRv6 is not
  applicable on this site (the SR Linux container has no SRv6 data plane), so
  `SRv6Service` objects report `Ready=False` with reason `CapabilityMissing`
  rather than a fabricated success.
- `tests/negative.yaml` — refusal cases (missing Secret, schema mismatch,
  unreachable SDC target, exhausted ASN claim).

Attachment names in a `Network` stay logical (`ethernet1`, `ethernet2`,
`ethernet3`, `wan1`); the provider maps them to the SR Linux interfaces
`ethernet-1/3` and `ethernet-1/4` through `FABRIC_PORT_MAP`.
