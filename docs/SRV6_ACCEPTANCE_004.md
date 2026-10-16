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
