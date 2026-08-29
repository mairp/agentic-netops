# Phase 4 — critic feedback (REJECTED)

The following must be addressed before re-writing GATE4-EVIDENCE.md:

Unmet or unclear criteria (specific gaps to address):

- T027a — SRv6Service CRD scaffolding (RBAC, CR examples, CEL/envtest coverage)
  - RBAC: The spec requires RBAC manifests as part of the CRD scaffolding. The only RBAC present on disk is deploy/rbac/base.yaml, which grants namespaced permissions to core/v1 configmaps, events, and coordination.k8s.io leases. There is no manifest granting the SRv6 controller permissions to get/list/watch/patch/update ainetops.io/v1alpha1 SRv6Service (including the status subresource), nor to access Kubenet or SDC CRs referenced in the controllers. Provide the RBAC manifests granting the SRv6 controller the necessary permissions, or point to their exact file paths with anchored excerpts.
  - CR examples: The envtest test reads config/samples/ainetops_v1alpha1_srv6service.yaml, but that file is not present in the snapshot. Provide the example CR file at that path.
  - Actionable:
    - Add config/rbac Role/ClusterRole and RoleBinding/ClusterRoleBinding granting verbs for ainetops.io SRv6Service and its status, and any other CRDs the controller uses.
    - Provide the missing sample: NEEDS-GROUNDING:config/samples/ainetops_v1alpha1_srv6service.yaml

- T037 — Server-side apply with dedicated field manager and explicit policy
  - The acceptance requires: server-side apply with a dedicated field manager, and embedding an explicit transaction policy (priority, operation, revertive, deletion) under spec["$policy"]. While sdc/types.go defines BuildPolicy and controllers/sonicprovider/controller.go declares a fieldManager constant, the on-disk controller excerpt does not show the SSA Patch/Apply call or assignment of spec["$policy"]. The claimed proof slice controllers.sonicprovider.controller.go.policy.proof.txt is not included in the snapshot, so the required mutation mechanics are not independently observable here.
  - Actionable:
    - Provide the anchored code implementing SSA with FieldManager "ainetops-sonic-provider" and Force=true, and the code that sets obj.Spec["$policy"] = sdc.BuildPolicy(...). NEEDS-GROUNDING:controllers/sonicprovider/controller.go

- T041 — Instrumentation and in-Kind deployment verification (RBAC)
  - Instrumentation and probes appear in code, and kubectl outputs show Pods/Service. However, RBAC verification fails: deploy/rbac/base.yaml does not grant access to the required custom resources (e.g., sdc.sdcio.dev Configs, Kubenet NetworkDevice, ainetops.io SRv6Service). The evidence claims RBAC for SDC "configs", but the only on-disk RBAC grants core/v1 and coordination.k8s.io permissions; there is no rule for sdc.sdcio.dev or ainetops.io in the visible manifests. The provided kubectl outputs do not describe the role’s rules; thus we cannot verify the required RBAC.
  - Actionable:
    - Add/ground the RBAC rules that allow the provider/SRv6 controller to get/list/watch and update status for the CRDs they reconcile (Kubenet NetworkDevice, sdc.sdcio.dev Config/Target/Deviation as applicable, ainetops.io SRv6Service). Provide kubectl describe role/clusterrole output or anchored manifest excerpts showing these permissions.

VERDICT 7bf070d6c705ef36: REJECTED



---
## Grounding transparency (machine-generated — read this)
These files you cited EXIST on disk, but the critic's grounding extractor could not include them in its snapshot, so the critic cannot 'see' their contents. This is a TOOLING limitation, NOT a missing file. Do NOT re-create, copy, or promote them — they are already present and correct. If a criterion depends on one, either cite it a different way (e.g. a slash path like `./cmd.sonic-provider.main.go.probes_le.leader.proof.txt`) or state in your evidence that grounding cannot reach it:
- `cmd.sonic-provider.main.go.probes_le.leader.proof.txt`
- `config.rbac.role.yaml.proof.txt`
- `config.rbac.role_binding.yaml.proof.txt`
- `controllers.sonicprovider.controller.go.final_backoff_owners.proof.txt`
- `controllers.sonicprovider.controller.go.metrics_tracing.proof.txt`
- `controllers.sonicprovider.controller.go.policy.proof.txt`
- `controllers.sonicprovider.controller.go.t038_events_ready.proof.txt`
- `controllers.sonicprovider.indexes.go.proof.txt`
- `deploy.ainetops.manifests.provider.yaml.slice.txt`
- `pkg.register.oc_vs_sonic.yaml.proof.txt`
- `pkg.render.canon.go.proof.txt`
- `pkg.render.evpn_advanced.go.proof.txt`
- `pkg.render.srv6.go.proof.txt`
- `pkg.sdc.offline.go.proof.txt`
- `pkg.sdc.types.go.policy.proof.txt`
