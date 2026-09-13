# docs/legacy — findings from the SONiC generation

These documents record work done against the **previous** fabric, SONiC
(`sonic-vs` / `sonic-vs-gnmi` under containerlab), before this repository was
re-targeted to Nokia SR Linux. They are kept for provenance: each one is a
record of what was actually observed on that platform, and several of them are
the reason a decision in
`specs/001-agentic-netops-srlinux-evpn-fabric/research.md` reads the way it
does. None of them describes the current target, and nothing in them should be
read as a claim about SR Linux.

The mapping from each SONiC mechanism to its SR Linux replacement is in
[../MIGRATION_FROM_SONIC.md](../MIGRATION_FROM_SONIC.md).

## `sonic/`

- **`SRV6_GNMI_CAPABILITY_FINDINGS.md`** — the capability investigation that
  established what the SONiC image's gNMI server would and would not do. Its
  central finding, that gNMI **Set** was not usable on that build and the write
  path had to go through GCU/redis with a gNMI read-back as the witness, is the
  direct reason the SR Linux target exists: on SR Linux gNMI Set is native and
  transactional, so the whole GCU/redis/FRR layer collapses into one primitive
  (research D2). The SRv6 conformance criteria recorded here are also the
  baseline against which SRv6 is now declared *not applicable* — the SR Linux
  container has no SRv6 data plane, so those criteria cannot be met and are
  reported as `not-applicable` with that reason rather than as `pass`.
- **`SONIC_IMAGE_SWAP_ANALYSIS.md`** — whether a different SONiC image could
  fix the EVPN Type-5 origination and L2 VNI adoption defects (D-A2/D-A3), and
  what had to be rebuilt to find out. An account of chasing a platform defect
  through image builds.
- **`FABRIC_BGP_EVPN_DEFERRED.md`** — what the SONiC fabric bootstrap
  implemented and what it deliberately deferred, including the self-repair
  hooks (`configure-fabric-bgp.sh`) that re-toggled `advertise-all-vni` and
  restarted zebra when the VNI was lost. SR Linux needs none of that: the
  underlay and overlay come from startup configuration and survive a container
  restart (research D4).
- **`CLUSTER_REBUILD_FINDINGS.md`** — root-causing an A2A TLS failure and
  rebuilding the kind lab on the committed pins. The Kubernetes-side findings
  still hold; the fabric-side ones are SONiC-specific.
- **`PHASE8_UNBLOCK_STATUS.md`** — the status note recording the SONiC
  capability gate going green (17/17), including the `sonic-srv6` entries that
  have no equivalent on this target.
- **`SUGGESTED_PROMPTS_POSTMORTEM.md`** — why every prompt the console itself
  offered was unrunnable, and how the suggested-prompt surface came to be
  derived from the supervisor's own construct list. The intent tier is
  unchanged by the migration, so this postmortem's conclusions still apply —
  only the port names in its examples belong to the old site.
