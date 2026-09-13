Pinned SDC (schema-driven configuration) CRDs, controllers and operational
components for in-cluster deployment against the Nokia SR Linux fabric.

- CRDs, schema/config/data/cache components and the required PVCs are installed
  inside kind.
- `seed/srlinux-schema.yaml` registers the SR Linux YANG schema
  (`nokia/srlinux-yang-models` at the release matching the pinned image), the
  gNMI connection profile (`:57400`, `JSON_IETF`, TLS) and the sync profile.
- `seed/discovery-rule.yaml` creates one Target per node from the management
  addresses `172.31.0.11/12/21/22`.
- SDC subscriptions stay disabled so gNMIc remains the only device-metric
  collector (see `deploy/observability/tests/no-duplicate-series.md`).
- Health checks and bounded readiness waits are required by
  `scripts/provision.sh` phases.
- Versions pinned in `versions.lock.yaml`.

SDC observes and validates; it is not a write path. Every change to the fabric
goes through the fabric-executor's gNMI Set, driven by the deterministic
renderer in `pkg/fabricplan` (constitution, Principle III).
