# Phase 3 — critic feedback (REJECTED)

The following must be addressed before re-writing GATE3-EVIDENCE.md:

REJECTED criteria and gaps

- T020 Install pinned Kubenet/KUID CRDs/controllers inside Kind and wait for current-generation health/readiness
  - Gap: The CRDs applied are not the pinned upstream CRDs. Your repository installs “minimal/simplified” CRDs (deploy/kubenet/crds/kubenet-crds.yaml and deploy/kuid/crds/kuid-crds.yaml) that explicitly state they are simplified placeholders, not the pinned upstream definitions. The acceptance requires installing the pinned Kubenet/KUID CRDs inside Kind, not reduced local shims. Action: Replace these with the actual pinned upstream CRD YAMLs (matching your versions.lock pin), install them in Kind, and keep the independent witness of Established/Ready.
  - Evidence of gap: Comments in deploy/kubenet/crds/kubenet-crds.yaml (“Minimal CRD definitions… simplified to satisfy…”) and in deploy/kuid/crds/kuid-crds.yaml (“Minimal CRD definitions…”). The witness files only prove these placeholders are applied/Established, not that pinned upstream CRDs are installed.

- T021 Install pinned SDC CRDs and schema/config/data/cache components inside Kind with required PVCs and health checks
  - Gap: Same CRD issue as T020. The file deploy/sdc/crds/sdc-crds.yaml is also a minimal placeholder (“Minimal SDC CRDs required…”), not the pinned upstream CRDs. The criterion requires installing pinned SDC CRDs inside Kind. Action: Install the actual pinned SDC CRDs that match your pinned SDC release, then keep the existing readiness/PVC witnesses.
  - Evidence of gap: Comment in deploy/sdc/crds/sdc-crds.yaml (“Minimal SDC CRDs required…”) confirms these are not the pinned upstream CRDs.

- T025 Create topology, IP/ASN/ID indices, claims/pools, and fabric design manifests using only the pinned Kubenet API; include IPv6 underlay, SRv6 locator, SID, and service-ID pools; add negative tests for absent Secrets, schema mismatch, unreachable target, and exhausted or colliding claims
  - Gap: No SRv6 SID pool is defined. The repo includes underlay IPv6 (IPIndex underlay-v6), an SRv6 locator IPIndex/Claim (srv6-locator-v6 and srv6-locator-claim), and a service-ID VNIIndex/Claim (srv6-service-ids and srv6-service-id-claim) in deploy/kubenet/srv6-pools.yaml, but there is no manifest for a SID pool (index and corresponding claim). The acceptance explicitly requires “SRv6 locator, SID, and service-ID pools.” Action: Add a dedicated SRv6 SID pool resource(s) using the pinned Kubenet/KUID API (e.g., an index and claim aligned to how SIDs are allocated in your model), apply it, and provide independent kubectl witness (Ready/Bound). The existing negative tests are fine for “exhausted or colliding” (you covered exhaustion).

VERDICT d6a05554d5cecf96: REJECTED

