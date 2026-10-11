# Planning guidance for `/speckit-plan`: SRv6 service requests end to end (004)

You are planning feature 004, "SRv6 service requests end to end", in `/root/agentic-netops`.
The feature spec says what has to be true; this guidance gives you the technical approach, the
decisions that are already settled, and the facts about the codebase that the spec does not
carry. The background for all of it is `roadmap/srv6-enablement-research.md`. Read that file in
full before filling in the plan, including its two closing sections ("Addendum 2026-10-11" and
"Owner decisions"), which supersede earlier recommendations in the same file where they
conflict.

## Before you start

- Run the setup script and check where it points. `.specify/feature.json` has been pointing at
  `specs/003-datacenter-service-constructs`, which already has a finished `plan.md`. If
  FEATURE_SPEC does not resolve to the 004 spec directory, stop and report that; do not write
  into 003.
- Planning is read-only with respect to the lab and the cluster. Read code, specs and existing
  proof logs freely. Do not provision, apply manifests, or write to any switch. In `agents/`,
  plain `pytest` is safe if you need it; never run the e2e lifecycle marker, because it purges
  the lab.
- `specs/` and `.wiggum/` are untracked, so check your edits by reading the files, not with
  `git diff`.
- The research file cites `file:line` as of commit `0720c4e2`. Re-read each location you rely
  on, since lines move. Claims it tags "(inferred)" or lists under "Not verified" are open
  until you confirm them from the code.
- If `spec.md` (including its Clarifications section) disagrees with this guidance, the spec
  wins. Note the disagreement in `research.md`.

## What is already decided

Treat these as inputs. Record each one in `research.md` in the Decision / Rationale /
Alternatives format, citing the owner decision of 2026-10-11, and do not reopen them.

- Service types: L3VPN over SRv6 and EVPN over SRv6. EVPN covers routed (Type-5) and bridged
  (MAC-VRF). Bridged may be deferred if the device recipe cannot be proven, in which case
  requests for it are refused by name.
- Acceptance is on the sonic-vm profile and requires client-to-client traffic between
  `srv6-client01` and `srv6-client02`. Control-plane state alone is not acceptance.
- `SRv6Service` stays a separate CRD. Upstream Kubenet `Network` field names do not change.
- Path steering is in scope in one form only: a preferred spine and an alternate spine, with
  failover and revert. The mapper's `tePolicy` refusal is lifted for that case and kept for
  everything else.
- Entry points: plain-language request, the chat UI (example prompts plus SRv6 in the status
  views, no structured form), and a directly applied `SRv6Service`.
- The controller allocates SIDs and VRFs from KUID on every entry point. A directly applied
  resource carries no hand-typed locator or SID.
- sonic-vm becomes the lab image for all four switches and the default profile. sonic-vs stays
  as a second selectable topology on which SRv6 is refused through the `cap.sai.srv6`
  capability. The two images are never mixed in one fabric.
- Outcomes of features 001, 002 and 003 are givens: the four-construct vocabulary, the
  two-confirmation flow, the deployer's apply/rollback/watch transaction, and the host-side
  fabric-executor as the only southbound.

Working defaults, to use unless the spec's clarifications say otherwise:

- Allocation: one SRv6 locator per node, owned by the lab bootstrap; per-service SIDs and VRFs
  claimed from KUID.
- Write path on sonic-vm: SSH into the guest, mirroring `tests/integration/lib/node_exec.sh`.
  gNMI Set stays out of scope.
- Placeholder renderers and register entries: rewrite against the tables that exist in the
  SONiC schema (`SRV6_MY_LOCATORS`, `SRV6_MY_SIDS`) and delete the ones with no schema behind
  them.
- Operator vocabulary: an "over srv6" qualifier on `ip-vrf` and `mac-vrf`, not a fifth
  construct. Whatever name is used has to pass `agents/tests/unit/test_vocabulary_guard.py`.

## Technical context to fill in

Carry forward the stack from `specs/003-datacenter-service-constructs/plan.md` and state only
what changes:

- Go toolchain and Python version as pinned in `versions.lock.yaml`; no new Go module or Python
  package unless the SSH transport needs one, in which case name it, pin it and justify it.
- Device target: SONiC 202505 on `local/sonic-vm:202505` (vrnetlab, KVM, `ASIC: vs`, kernel
  6.1 with seg6 built in), 2 spines, 2 leaves, `lab/topology.sonic-vm.clab.yml`. Because the
  ASIC is `vs`, kernel seg6 is the SRv6 dataplane.
- Southbound: `pkg/fabricplan` to the fabric-executor, which gains a second transport selected
  per node kind (`docker exec` for sonic-vs, SSH for sonic-vm). The agent tier still opens no
  device session.
- Storage, cluster and namespaces: unchanged.

## The device recipe is the main unknown

No SRv6 VPN service has been signalled or forwarded on this image. If the spec directory or
`docs/` holds a spike record with the exact device state, read-backs and traffic captures for
each service type, build the design on it and cite it.

If there is no such record, do not invent device commands, CONFIG_DB rows or FRR configuration
and present them as known. Instead:

- Make the recipe spike the first phase of the plan, run by hand on the live lab between
  `leaf01` and `leaf02`, covering in order: underlay and locators, L3VPN over SRv6, routed EVPN
  over SRv6, bridged EVPN over SRv6, preferred-spine steering. Its output is, per service type,
  the device state that works, the read-back that proves it, and a capture of client traffic.
- Give the spike an exit gate with three outcomes per service type: proven, deferred (refused
  by name), or not achievable. State which later phases each outcome unlocks or removes.
  Bridged EVPN is the likeliest to be deferred, since FRR's SRv6 VPN support is known for L3
  behaviours and Layer-2 EVPN over SRv6 may be absent in this build.
- In `research.md`, record the recipe as a decision to settle it in that phase, with what is
  already verified (seg6 kernel config, the `uN` and `uDT46` rows the gate writes, FRR
  answering `show segment-routing srv6 locator`) and what is not (`seg6_enabled` per
  interface, `net.vrf.strict_mode` for `End.DT46`, BGP SID export per VRF).
- Keep recipe-dependent detail in one place in `data-model.md` and the contracts, so the spike
  result changes one section and not the whole design.

## Design direction by layer

The research file's "Required work" table has 17 items plus steering. The plan should cover
all of them, in an order that respects these dependencies.

1. **Lab foundation.** Per-node identity on sonic-vm (today every guest boots as `Loopback0
   10.1.0.1/32`, AS 65100): IPv4 and IPv6 loopbacks, the ASNs from the topology labels, IPv6 on
   the four fabric links, underlay BGP for both families, one locator per node advertised in
   the IPv6 underlay. Decide between a per-node `config_db.json` through containerlab
   `startup-config` and extending `init-sonic-bootstrap.sh`; whether the pinned vrnetlab build
   honours `startup-config` is unverified.
2. **Executor transport into the guest.** State where the SSH credentials live, who can read
   them, and how the transport is selected per node. This changes the trust boundary and sits
   under the four constructs that work today, so plan transport-level tests; neither the agents
   suite nor `pkg/fabricplan/plan_test.go` covers transport.
3. **Default profile flip** in `scripts/provision.sh`, `scripts/lib/containerlab.sh` and the
   `Makefile`, only after 1 and 2, and gated on the existing suites passing on sonic-vm. Suites
   and docs that assume `docker exec` have to move to `node_exec.sh`.
4. **Capability and pins.** `cap-sai-srv6` derived from the gate result for the active profile
   instead of a constant; `requiresSRv6()` applied to SRv6 objects only; the `sonic-image` pin
   following the profile; one form for the sonic-vm image across the topology and
   `versions.lock.yaml`. Check the tree first: part of this may already have landed as a
   separate small fix.
5. **API.** Rework `SRv6Service` for both service types, steering and controller-side
   allocation. Fix the CEL markers that use a typographic quote, then generate the CRD from the
   markers rather than hand-writing it.
6. **Plan rendering.** SRv6 operations, checks and rollback in the executor's vocabulary in
   `pkg/fabricplan`; rewrite or delete the placeholders in `pkg/render`, `pkg/register` and the
   embedded copy in `pkg/sdc/validate.go`.
7. **Controller.** A real reconcile modelled on
   `controllers/sonicprovider/network_controller.go`: finalizer, KUID claims, plan, apply,
   verify, Ready from device-observed state, periodic re-verify, drift repair, delete with
   rollback and claim release. Remove the swallowed wait in `scripts/provision.sh`.
8. **Intent contract and tier.** Go `ServiceInput`, validation and a translator branch that
   emits `SRv6Service`; Python schema parity; mapper detection ahead of the `l3vpn`, `evpn` and
   `vrf` patterns; supervisor vocabulary, clarification and prompts; deployer status listing;
   early refusal in the tier on a profile without the capability, before any claim. The mapper
   is regex-ordered, so plan a check that existing corpus phrasings still map as before. An
   SRv6 request must never be provisioned over another transport; check the tree for an interim
   refusal that may already exist.
9. **UI.** Example prompts served and in the offline fallback, which are guarded against drift,
   and SRv6 services in the status views.
10. **Gate, tests, observability, docs.** Fix the seg6 probe that uses `dev lo` so the
    encapsulation and SID-list checks run on sonic-vm; a check that cannot run reports skipped,
    never passed. Emit or scrape the metrics the existing SRv6 dashboard and alert already
    query. Correct the tutorial, the demo tutorial and the sonic-vm README.

Phase the plan so that each phase ends in something verifiable on the live lab, and so the four
existing constructs keep working at every phase boundary.

## Constitution check

Answer each gate concretely for this feature rather than marking it PASS:

- **I.** Which device read-backs and which traffic check make Ready true, per service type, and
  which condition reason names a failing node.
- **II.** The two-confirmation flow applies to SRv6 requests unchanged. Say how a directly
  applied resource fits this principle.
- **III.** Translate, dry-run, apply, rollback and convergence watch for the new kind; zero
  device writes on an unchanged re-apply.
- **IV.** The signals behind `deploy/observability/dashboards/srv6-service-path.json` and the
  SRv6 alert rule, and where they come from.
- **V.** The sonic-vm image is operator-built and cannot be pulled. State how it is pinned and
  how `make verify-pins` treats it.
- **VI.** Acceptance packet sizes under MTU 9216 with the SRv6 header, and no gate recorded as
  passed while skipped.

The SSH transport and the default-profile flip are the likely entries for Complexity Tracking.

## Artifacts

- `research.md`: the settled decisions above, the recipe item, and the unknowns you resolved by
  reading code. Separate what you verified from what you inferred.
- `data-model.md`: `SRv6Service` spec and status, the per-service claims and their relation to
  the KUID pools in `deploy/kubenet/srv6-pools.yaml`, the per-node locator, the capability
  value, and the state transitions of a service including failover.
- `contracts/`: the CRD schema with its validation rules; the intent JSON for the SRv6 variants
  as shared by Go and Python; the fabricplan operations and checks added for SRv6; the operator
  phrasings that are accepted, clarified and refused, with the refusal texts; the capability
  ConfigMap keys.
- `quickstart.md`: one runnable scenario per acceptance criterion in the spec, each naming the
  command that produces its proof. Proofs are captures taken on the live lab by a recorded
  command. This repository has had approvals later contradicted by evidence, so a scenario that
  cannot be shown this way should say so rather than describe an expected result.

## What to report at the end

The branch, the plan path and the artifacts written; the gates that did not pass cleanly; and
the list of points where this guidance, the spec and the code disagreed.
