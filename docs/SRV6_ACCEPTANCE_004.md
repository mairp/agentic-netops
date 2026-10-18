# Acceptance record: SRv6 Service Requests End to End (004)

**Status: skeleton.** Every proof-name cell is empty until the criterion's
proofs exist on the live lab. Filled at T593 (plan 12-25); this file is the
tracked index that cites proofs by name (FR-039, SC-015).

Source of the criteria: `specs/004-srv6-service-requests/spec.md`
("Success Criteria", SC-001 to SC-018). The outcome column is a one-line
restatement, not a substitute for the spec text.

Rules this record follows:

- A proof name is a capture taken through
  `scripts/proof.sh <name> -- <command>`; its `.cmd` sits next to its `.out`
  under `.wiggum/features/004-srv6-service-requests/gates/proofs/`, and
  re-running the `.cmd` must regenerate the `.out` (SC-015).
- A proof taken again later carries a suffix (`-default`, `-us4`, `-final`)
  so it never overwrites the capture an earlier gate rested on
  (`specs/004-srv6-service-requests/quickstart.md`).
- A criterion whose proof did not regenerate is marked not met.
- SC-011 includes the `q17-*` proofs (T593).

## Acceptance criteria

| Criterion | Outcome | Proofs | Verdict |
| --- | --- | --- | --- |
| SC-001 | Recipe spike records "proven" or "not achievable" for each of the four items; an unattended replay on a freshly brought-up lab reproduces every "proven" verdict from the recorded commands alone. | | |
| SC-002 | Default bring-up yields four switches with four distinct identities, underlay sessions on four of four fabric links, each locator reachable from the three others. | | |
| SC-003 | All four existing constructs provision, verify, update and delete on the default lab, and 100% of the existing suites pass there. | Proofs: `q3-fabric`, `q3-traffic`, `q3-idempotence`, `q3-drift`, `q3-update`, `q3-teardown`, `q3-mtu`, `q3-invalid-yang`, `q3-parity`, `q3-observability`, `q3-agents`, `q3-go` (T223-T234); `p4-vlan-provision`/`p4-vlan-update`/`p4-vlan-delete`, `p4-macvrf-provision`/`p4-macvrf-update`/`p4-macvrf-delete`, `p4-ipvrf-provision`/`p4-ipvrf-update`/`p4-ipvrf-delete`, `p4-macvrf-gw-provision`/`p4-macvrf-gw-update`/`p4-macvrf-gw-delete`, `p4-acl-provision`/`p4-acl-update`/`p4-acl-delete` (construct CRUD through the intent tier, T189-T218); `p4-vs-fabric_verify`, `p4-vs-evpn_traffic`, `p4-vs-idempotence`, `p4-vs-drift_preservation`, `p4-vs-update_delete_survivability`, `p4-vs-teardown_suite`, `p4-vs-mtu_ecmp`, `p4-vs-failure_recovery_invalid_yang`, `p4-vs-topology_parity`, `p4-vs-observability_suite` (sonic-vs regression after the plan changes, T235-T245). The `q3-*-default` proofs taken after the default flip are added to this row by the acceptance-index task. Receipts under `.wiggum/features/004-srv6-service-requests/gates/proofs/`. | |
| SC-004 | For each supported service type, a twice-confirmed plain-language request yields exactly one SRv6 service reaching Ready, readable from both leaves. | | |
| SC-005 | For each supported service type, client-to-client traffic passes and a fabric-link capture shows SRv6 encapsulation carrying the service's identifier; Ready is never True before this holds at first activation. | | |
| SC-006 | Ready is never True while a per-node check fails; a check broken on one leaf turns Ready False naming that leaf within one re-verification interval. | | |
| SC-007 | A steered service carries 100% of traffic through the preferred spine while usable; failure moves it to the alternate and restoration returns it, each within 5 seconds and at most 2 consecutive losses after the switch. | | |
| SC-008 | Of the four named SRv6 phrasings and every SRv6 corpus phrasing, zero produce a VXLAN service, at every delivered increment. | | |
| SC-009 | A resource applied directly, tier stopped, meets SC-004 to SC-007 with zero hand-typed identifiers. | | |
| SC-010 | 100% of identifiers trace to a claim carrying the request's correlation id; after delete, zero such claims and zero service-owned items remain on any node, other services unchanged. | | |
| SC-011 | Re-applying an unchanged request writes nothing; out-of-band removal on one leaf is restored within one re-verification interval; a changed mutable field converges, verifies, and leaves nothing of the previous version on any node. | | |
| SC-012 | The chat page offers at least one runnable SRv6 example per supported type; the status views list every SRv6 service with type and Ready state. | | |
| SC-013 | On the container profile, 100% of direct SRv6 resources are refused with a capability reason and 100% of chat SRv6 requests refused with zero identifiers claimed, while the four existing constructs still provision. | | |
| SC-014 | On the SONiC VM profile the gate executes the encapsulation and SID-list checks; on any profile, passed equals ran-and-passed, skips counted separately. | | |
| SC-015 | Every acceptance proof regenerates by re-running the command stored next to it on the live lab; zero approvals rest on a proof that fails this. | | |
| SC-016 | The existing phrasing corpus maps identically before and after this feature, and the vocabulary guard passes with no entry relaxed. | | |
| SC-017 | An operator following the documentation's SRv6 section on the live lab reaches every stated outcome, and every stated verify command returns what the text says. | | |
| SC-018 | While an SRv6 service carries traffic, every panel of the SRv6 dashboard shows data, and disabling a steered service's preferred path raises the existing alert. | | |

## Review records

### R1 — interim SRv6 refusal and classifier routing (T597, phase 2, 2026-10-11)

What changed and why (FR-003, FR-003a, FR-015; contracts/operator-phrasings.md §3): before this
feature's own service type exists, a request naming SRv6 must not be answered with a generic
unsupported text, a clarification, or — worst — a silent fold into a VXLAN service. The mapper now
recognizes SRv6 (case-insensitive: `srv6`, `segment routing v6`, `segment routing over ipv6`) and
flags it as the unsupported property `srv6Transport`; the supervisor's mapper node renders the
official interim refusal R1 for it; the classifier routes a request naming SRv6 to the provisioning
path so R1 — not a diversion — is what the operator sees.

Texts before / after:

- Classifier (prompts/system.py, decision order) — BEFORE: a request naming SRv6 with a known
  construct (e.g. "ip-vrf over SRv6") classified PROVISIONABLE only by construct-word accident, and
  a bare "SRv6 service" fell through to INFORMATIONAL ("here is what I can do" — no refusal). AFTER:
  decision-order rule 2 — any request naming SRv6 is PROVISIONABLE, so the provisioning path's
  official R1 refusal is what the operator sees.
- Mapper — BEFORE: `srv6Transport` unknown; "ip-vrf over SRv6" mapped to `ip-vrf`; "SRv6 + a legacy
  service alias" folded through the alias to `ip-vrf` (a VXLAN-equivalent claim for an SRv6
  request). AFTER:
  the request is terminal with `unsupported_properties=["srv6Transport"]` and empty
  `missing_fields`; nothing is mapped, allocated, or claimed.
- Operator-facing refusal — BEFORE: generic `I can't do that. unsupported properties: … (no
  equivalent in the fabric). …` (or no refusal at all). AFTER (R1, composed by the supervisor
  template): `I can't do that. SRv6 services are not available yet. This request names SRv6, so it
  is not provisioned as a VXLAN service. This tier never opens a device session, issues a device
  command, or writes device configuration. Every change to the fabric flows only through declarative
  service intent submitted to the cluster API, which the control plane reconciles. Try instead:
  nothing was provisioned and nothing was claimed — SRv6 has no supported service type on this tier
  yet. If you want a VXLAN service today, ask for it explicitly as its own request — e.g. 'extend
  vlan 100 as a mac-vrf across <siteA> <portA> and <siteB> <portB> for tenant <tenant>' — and I will
  map that request through the same two confirmations. (correlation id: <id>)`

Proofs this record rests on: `gates/proofs/q10-srv6.out` (the five-case interim SRv6 corpus —
mapper-level unsupported result and graph-level R1 refusal for each), `gates/proofs/q10-baseline.out`
(existing corpus replay identical to the snapshot — nothing else moved), `gates/proofs/q10-guard.out`
(vocabulary guard, no entry relaxed), `gates/proofs/p1-agents.out` (whole agents suite green after
the change). The refusal text itself is pinned in `agents/tests/unit/test_phrasings_srv6.py` and
`agents/tests/unit/test_refusal_paths.py` (`TestSRv6InterimRefusal`).

### R2 — plain-language ip-vrf over SRv6 end to end, client /24 claims (T515, phase 6, 2026-10-17)

What changed and why (US4 scenario 1, spec.md line 217+; contracts/intent-srv6.md §4;
contracts/srv6service-crd.md A9; data-model.md §8.1; SC-010): a plain-language request — "Give
tenant blue an ip-vrf over srv6 carrying 10.60.0.0/24 between leaf01 wan1 and leaf02 wan1" — now
completes the full two-confirmation pipeline to a Ready SRv6Service with the controller's data
path verified, without any VXLAN construct being created. Two production gaps had to close first:

1. The ip-vrf branch of the allocator's SRv6 intent builder DROPPED the endpoints' client
   prefixes. The Go translator maps `endpoints[].prefixes` to `spec.attachments[].gateway`
   (intent-srv6.md §4) and the CRD's rule A9 rejects ip-vrf attachments without a gateway prefix,
   so the tier dry-ran into a 422 ("ip-vrf attachments need a gateway prefix") at confirmation 1.
   The allocator now claims each endpoint's client /24 from the `srv6-client-v4` pool BEFORE apply
   (`KUIDClient.allocate_client_prefix`, claim spec mirrors the Go controller's:
   `{index: srv6-client-v4, createPrefix: true, prefixLength: 24}`) and derives the gateway as the
   first usable host of the claimed prefix. VXLAN identifiers remain zero-claimed on the SRv6 path;
   the client /24s are the one claim an SRv6 request makes.
2. The python claim name has to byte-match the Go controller's `ClaimName`+`sanitize`
   (63-character truncation, then `Trim(v, "-.")`) or the controller cannot reuse the allocator's
   claim and carves a SECOND /24 for the same attachment (measured: a 65-character name 500'd the
   claim API on attempt 3). `_claim_name` now mirrors the Go rules and is unit-tested against
   them.
 3. A THIRD defect, found after the first "green" receipt, invalidated that receipt's central
    claim and had to be fixed before the evidence below could be recorded: the correlation id was
    minted PER STREAM (`uuid.uuid4().hex` in the supervisor's `handle_stream_prompt`), while the
    claims key on it across turns. The allocator's claims therefore carried the ALLOCATION turn's
    id, the created `SRv6Service` carried the SUBMIT turn's id, and the controller neither reused
    the claims nor released them on decline/delete — attempts 6-8 each leaked a pair of /24
    ipclaims (attempt 6: `e597912f…`; attempt 7: `bcace394…`; attempt 8: `5fcfacd9…`, all
    deleted by hand from the lab). The earlier statement in this record that "the controller
    REUSED them via the shared correlation label" described the attempt-6 receipt and was WRONG —
    the attempt-6 receipt's claim-existence check was vacuous (it grep'd for a family the label
    filter never matched). The fix (SC-010, recorded in PROGRESS.md §7): the correlation is
    thread-stable (continuing turns reuse the checkpointed id; only new threads mint), and the
    supervisor passes it EXPLICITLY inside the fenced allocation payload as an additive
    `correlationId` key (OTel trace context does not survive the A2A boundary into the worker;
    the allocator pops the key before validating, so the published schema is unchanged).

Evidence: `gates/proofs/q10-live-ip-vrf-vpn.out` (exit 0, the FINAL receipt, recorded after the
fix) — both confirmation points offered and answered, SRv6Service/1b0f23f18f92450 Ready with
"data path verified", probe result=pass, exactly one SRv6Service, no Network for the service id,
bring-up sample restored Ready + pass after the receipt. The receipt's claim-existence check
lists BOTH ipclaims BY NAME under the thread's one correlation id
(`srv6-client-v4-claim-dbb74343fe9f4381b6aca561e2c39d51-leaf01-wa` / `-leaf02-wa`), the created
service's message carries the same id, and after the receipt service's deletion the claims are
GONE from the cluster (release witnessed). Attempts 6-8's interim receipts were overwritten by
this final one; their defect history lives in PROGRESS.md §7 and in the gate evidence.

Disclosed, not reworked: the client pool carves FIFO (192.168.0.0/24 first) while the lab's
physical clients sit on 192.168.1.0/24 (leaf01) and 192.168.0.0/24-unrelated 192.168.2.0/24
(leaf02), so the dataPath probe's "pass" witnesses reachability of the PEER attachment's claimed
client address under the claimed addressing, not the physically-wired client path of this lab
instance. The drift compounds across runs: after this session's release/re-claim cycles the
sample holds 192.168.0.0/24 + 192.168.9.0/24 — the ipam server re-uses arbitrary free /24s
rather than strict FIFO once ranges have been freed — and its probe still reports pass; same
witness-strength caveat.

Also recorded: a SLIM-tier operational note — restarting ONE agent pod (the allocator) leaves the
other agents publishing to a stale SLIM session (~60s "timer failed on channel endpoint", the
orphaned confirm turn then re-classifies fresh and the mapper fallback refuses it). The receipts'
runs restart all four tier agents together when a redeploy happens; recorded here because any
future one-pod restart will reproduce it.

### R3 — the phase's changed refusal and confirmation texts (T515, phase 6, 2026-10-18)

What changed and why (FR-003a, FR-005, FR-013; contracts/operator-phrasings.md §3; spec KL-001):
once the first SRv6 type is supported, every SRv6-named request must get the official per-variant
answer instead of the phase-2 interim refusal R1 ("SRv6 services are not available yet. …"), and
the confirmation/decline surfaces must say what is actually being deployed. Texts before / after,
and the proofs each rests on:

- R2, supported-list form — BEFORE: interim R1 for every SRv6 request. AFTER: for a variant
  outside the supported set, "`<variant>` is not supported on this image. Supported SRv6
  services: `<list>`." Proof: `gates/proofs/q10-r2-ip-vrf-evpn.out` (live through the tier, exit
  0 — the ip-vrf/evpn variant named with the supported list, no SRv6Service, no Network, no
  claim) and the corpus-tier replay `gates/proofs/q10-srv6-us4.out`.
- R2, bridged gloss form — BEFORE: interim R1. AFTER: "`mac-vrf over srv6` (bridged EVPN over
  SRv6) is not supported on this image." — the ONE gloss allowed beside the FR-013 wording
  (KL-001), with no supported list for this variant. Proof:
  `gates/proofs/q10-r2-mac-vrf-evpn.out` (live, exit 0); pinned by
  `agents/tests/unit/test_refusal_paths.py` (`test_r2_bridged_variant_uses_the_kl001_gloss`),
  `agents/tests/unit/test_capability_reader.py::test_r2_bridged_gloss_is_the_kl001_wording`,
  and the vocabulary guard (`gates/proofs/q10-guard-us4.out`).
- R4, capability not proven — NEW: "SRv6 is not available on this lab profile: the capability
  has not been proven here." rendered BEFORE the mapper when the `fabric-compat-pins` read fails
  or `srv6-supported` is not exactly "true". Witnessed at unit level only
  (`agents/tests/unit/test_capability_refusal.py` — zero allocator/deployer calls, and a
  non-SRv6 request never triggers the read); this lab's capability IS proven, so no live receipt
  renders R4 here.
- R3/R5 conflicts and C1/C2 clarifications — NEW: "The request names both SRv6 and VXLAN. …",
  "SRv6 applies to ip-vrf and mac-vrf. …", "Which SRv6 service: …?", "Routed (…) or bridged
  (…)?" — the latter list ONLY supported variants. Proofs: the tier-level corpus runs
  (`unsupported/srv6_conflict.yaml`, `srv6_clarify.yaml` cases) in `gates/proofs/q10-srv6-us4.out`
  and `agents/tests/unit/test_phrasings_srv6.py`.
- Confirmation and decline — BEFORE: the two confirmation points existed for VXLAN constructs
  only, with no transport wording. AFTER: the same two points for an SRv6 request —
  "Confirm this interpretation? Reply 'confirm' to proceed to allocation, or 'decline' to
  cancel." then "Deploy this service? Reply 'confirm' to submit it to the cluster, or 'decline'
  to cancel." — with the deployer card stating the qualified service ("Deploy an ip-vrf over
  srv6 with vpn signalling between two leaf attachments." / "… with evpn signalling …" / the
  bridged mac-vrf form). Proofs: `gates/proofs/q10-live-ip-vrf-vpn.out` (both points offered and
  answered; the Deployed line), `gates/proofs/q10-decline-ip-vrf-vpn.out` (decline at point 1:
  "refused: confirmation_1 declined by operator"; the receipt asserts no SRv6Service, no
  Network, no claim).

### R4 — the TE exception: a preferred spine is path steering, not a TE policy (T628, phase 7, 2026-10-18)

What changed and why (US5; contracts/operator-phrasings.md §3 R6 + §4; contracts/intent-srv6.md
rule V8; spec FR-026; plan 10-08): with steering delivered, the ONE TE-adjacent phrasing family
that names a preferred spine on an SRv6 request became provisionable end to end — while every
other TE form stays refused with the same `tePolicy` property as before. This record reviews the
refusal-surface texts before and after, per the TE-exception review obligation (tasks.md T628).

Texts before / after:

- Classifier (`agents/supervisors/provisioning/prompts/system.py`, UNSUPPORTED_CLASSIFICATION_PROMPT,
  lines 129-133) — BEFORE: "names a construct with no fabric equivalent: traffic engineering (TE)
  policies, pseudowire OAM / control words, multicast VPN, service chaining, complex QoS, or raw
  CLI as a service property" with no exception, so a steering phrasing risked classification as an
  out-of-contract TE ask. AFTER: the same bullet extended in place (lines 129-133): "Naming a
  PREFERRED SPINE on an SRv6 service is not a TE policy — it is path steering, and it is
  provisionable; TE policies remain out of contract". (Committed at the phase-6 gate, 5dbaf1b4,
  ahead of the steering increment.)
- Mapper (`agents/provisioning/mapper/agent.py`) — BEFORE: `_UNSUPPORTED_FEATURES` matched
  `traffic engineering|te-policy|te-path` only; `preferredSpine` was parsed (US4) but no path
  preference existed to render, and a preferred spine on a NON-SRv6 request produced no refusal.
  AFTER: `_parse_alternate_spine` (lines 184-190) parses the contract's single alternate form;
  `alternateSpine` rides the interpretation for validation only
  (`agents/common/schemas/interpretation.py` lines 191-196, `alternate_spine` field, popped when
  absent like its siblings); and a preferred spine on a request that is NOT SRv6 appends `tePolicy`
  (`agent.py` lines 821-827, "a preferred spine on a request that is NOT
  SRv6 is traffic engineering (R6)").
- Supervisor (`agents/supervisors/provisioning/graph/graph.py`) — BEFORE: TE patterns covered
  `traffic engineering|te-policy|te-path` only, so the contract's remaining R6 phrasings ("explicit
  path", "SID list", "pin the flow") fell through unmatched. AFTER: all three added to
  `UNSUPPORTED_FEATURE_PATTERNS` under the same `tePolicy` property (lines 211-213), and the
  alternate spine gets R7 validation naming the field ("alternateSpine: unknown …", lines
  1898-1908).
- Contract tables unchanged (they specified this exact shape): operator-phrasings.md §3 R6 —
  "traffic engineering other than a preferred spine → the existing `tePolicy` refusal, unchanged" —
  and §4's Path preference rows; intent-srv6.md V8 — `unsupported.tePolicy` set together with
  `preferredSpine` is still refused as `tePolicy`.
- The provisionable side is real, not just unrefused: the renderer pins the peer /64 via the
  preferred spine's leg (`pkg/fabricplan/srv6.go`, T516/T517) and the controller reads the DEVICE
  pin into `status.activePath`, treats an alternate-leg pin as FAILOVER rather than drift (FR-026)
  and refuses `PathDown` when neither leg serves the pin
  (`controllers/srv6service/path.go`, T520/T521).

Proofs this record rests on: `gates/proofs/q11-te.out` (exit 0: 69 passed — every TE corpus case
still refused, the steering corpus mapping through, at unit level) and `gates/proofs/q11-path.out`
(exit 0, LIVE: the steered service's pin reads `via 2001:db8:1::3 dev Ethernet0` naming spine01 —
`spec.path.preferredSpine` — and the wire witness counts 12 SRH packets on the spine01 leg and 0
on the spine02 leg). The failover/return/both proofs (q11-failover/q11-return/q11-both) witness
that the exception's provisionable side survives an operator-directed path change and a
both-paths-down; they are cited in the SC-007 row by the acceptance-index task.

### R4 (capability not proven) and R9 (no registered probe host) — first live refusal surface (T630, phase 9, 2026-10-18)

What changed and why (FR-003a; contracts/operator-phrasings.md §3 R4 + R9; plan A-18 — this
record blocks nothing): phase 9 turns the lab to the sonic-vs profile, whose capability gate
cannot prove SRv6 encapsulation (`H.Encaps.Red` and `SID-list` exit SKIP 77 — kernel seg6
lwtunnel unavailable), so `cap-sai-srv6` is `"false"` and `srv6-supported` is not `"true"`.
The refusal texts themselves are unchanged; what changed is that R4 is now rendered LIVE, on
both entry points, where before it existed only as a unit-level sentence. This record reviews
both texts before and after, per the review obligation (tasks.md T630).

Texts before / after:

- R4 — "SRv6 is not available on this lab profile: the capability has not been proven here."
  BEFORE: unchanged sentence since the phase-6 record above, witnessed at unit level only
  (`agents/tests/unit/test_capability_refusal.py`); that record stated "this lab's capability
  IS proven, so no live receipt renders R4 here", because the sonic-vm lab's gate proved
  `ip-vrf`/`vpn` end to end. AFTER: the SAME sentence now renders live on the sonic-vs profile —
  a chat request naming SRv6 is refused with it before the mapper (one ConfigMap read, T623;
  no confirmation point offered, no resource, no claim), and the controller twin refuses a
  directly applied SRv6Service with the terminal `CapabilityMissing` reason naming the key
  ("SRv6 is not proven on this site (key cap-sai-srv6 is not \"true\"; configmap
  agentic-netops-system/fabric-compat-pins)") before any allocation.
- R9 — "`<port>` on `<node>` has no client to verify traffic from, so an SRv6 service there
  cannot reach Ready. Attachments that can be verified: `<list>`." BEFORE: the interim R1
  refusal covered an unverifiable attachment (phase-6 record). AFTER: the T624 sentence,
  decided from `capability.py` before any claim (plan A-16). It remains witnessed at unit level
  only (`agents/tests/unit/test_refusal_paths.py`, the R9 case asserting no claim): on this
  sonic-vs lab R4 fires earlier in the same turn for every SRv6 request, and on sonic-vm the
  registered probe hosts cover the lab's attachments (`srv6-probe-attachments:
  leaf01/wan1,leaf02/wan1`), so no live receipt renders R9 on either profile. No live R9
  receipt exists; none is claimed.

Proofs this record rests on: `gates/proofs/q13-chat.out` (exit 0, LIVE through the tier: the
exact R4 sentence, `confirmation_points=0`, no correlation-id claim — the SRv6 chat driver's own
trailing "no SRv6Service after confirmation" line is its confirm-path assertion, expected on a
refusal and annotated in the receipt), `gates/proofs/q13-direct.out` (exit 0, LIVE: the direct
apply ends at `CapabilityMissing`), `gates/proofs/q13-claims.out` (exit 0: no claim of any kind
for either request; the refused object carries empty `status.allocations` and
`status.correlationId`), and `gates/proofs/q13-capability-source.out` (exit 0: `"false"` because
nothing was proven — the two encapsulation checks skip — not because of a name: the EVPN checks
ran under their final names and the five runnable SRv6 checks passed). The non-SRv6 surface is
unaffected on the same lab: `gates/proofs/q13-vlan.out` (exit 0, LIVE: the vlan 130 request
provisions as today).
