# Phase 1 — critic feedback (REJECTED)

The following must be addressed before re-writing GATE1-EVIDENCE.md:

Unmet or unclear acceptance criteria:

- T001 Create the implementation directory structure from plan.md
  - Missing grounding to verify “from plan.md”: The referenced ./plan.md does not exist in the snapshot, so it is unclear whether the created structure matches the plan. Provide the actual plan.md at repo root or update the reference and include the file so the structure can be compared.
  - NEEDS-GROUNDING:./plan.md

- T006 Implement make verify-pins to reject latest, floating refs, missing digests, and inconsistent compatibility metadata (NFR-003)
  - The top-level Makefile itself is not present in the snapshot. Although a proof slice exists, we must observe the actual Makefile on disk to verify the make verify-pins target is implemented and callable. Without it, we cannot independently confirm that make verify-pins exists or is wired to scripts/lib/verify_pins.sh.
  - Provide the top-level Makefile containing the verify-pins target that invokes scripts/lib/verify_pins.sh.
  - NEEDS-GROUNDING:Makefile

- T007 Implement reusable strict-shell preflight for host resources, Kind/runtime privileges, address conflicts, tool versions, MTU, and KVM when required; invoke it from scripts/provision.sh
  - Address-conflict check is a no-op: preflight::address_conflicts only runs grep against /dev/null and never evaluates overlap with pod/service CIDRs or any configured ranges. This does not implement the required address conflict validation.
  - Tool versions are not verified: preflight::tool_versions only checks presence of commands; it does not verify their versions against the pinned versions/constraints. The criterion explicitly calls for tool versions to be validated.
  - Required fixes:
    - Implement a real conflict check (e.g., parse AINETOPS_MGMT_CIDR and compare against pinned pod/service CIDRs or configured ranges; fail on overlap).
    - Verify host tool versions (kind, kubectl, helm, containerlab, etc.) meet the pinned versions in versions.lock.yaml (or contractually documented equivalents); fail on mismatch.

- T008 Validate upstream Kubenet/KUID and SDC CRDs/examples with Kubernetes server-side dry-run; document whether the selected release uses NetworkConfig or NetworkDesign
  - The validation script’s fetch-and-apply method is likely incorrect for multiple files: scripts/lib/validate_crds.sh runs kubectl apply --dry-run=server -f <(curl -fsSL "${files[@]}"). When multiple URLs are provided, curl concatenates outputs without YAML document separators (---). This can cause kubectl to fail to parse multiple resources or to only consider the first document. The correct approach is to pass multiple -f flags directly to kubectl (kubectl apply --dry-run=server -f URL1 -f URL2 ...) or to concatenate with explicit --- separators.
  - The provided run log (.wiggum/.../validate-crds.run.log) contains only the script’s echo lines and “OK” but no independent evidence that kubectl successfully performed server-side validation across all CRD/example files. Given the likely concatenation issue, the validation may be non-functional for multiple files.
  - Required fixes:
    - Update scripts/lib/validate_crds.sh to apply each URL with separate -f flags or generate a combined stream with proper --- separators.
    - Re-run and capture logs that include at least kubectl’s success indications or a summary proving each CRD/example was validated server-side (errors would fail the script).

VERDICT a43e78e81f9ce448: REJECTED

