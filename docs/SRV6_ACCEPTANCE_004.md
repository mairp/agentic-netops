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
| SC-003 | All four existing constructs provision, verify, update and delete on the default lab, and 100% of the existing suites pass there. | | |
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

(empty — filled at T593, plan 12-25, alongside the proofs column above)
