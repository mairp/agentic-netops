# SRv6 Service Recipe (feature 004)

**Status: skeleton. Nothing in this file is proven.** The Phase 0 spike fills it
on the live sonic-vm lab; until then every verdict cell below is empty.

This file records the device recipe for one SRv6 VPN service on the pinned
SONiC image, per the spike task (`specs/004-srv6-service-requests/tasks.md`,
plan 0-02) and the evidence base `roadmap/srv6-enablement-research.md`.

## How this file is used

- Each section below starts with an **Approaches to try** list that is written
  **before the first attempt**, so the spike tests candidates instead of
  rationalising whatever happened. Approaches are candidates to confirm or
  refute; none is a proven device command. Device commands and read-backs are
  recorded only from the live lab, never invented.
- A verdict is `proven` or `not achievable` (spec SC-001). A `proven` verdict
  must be reproducible by replaying the recorded commands alone on a freshly
  brought-up lab (`scripts/proof.sh replay <prefix>`).
- `proofs` cites proofs by name, as recorded by
  `scripts/proof.sh <name> -- <command>` under
  `.wiggum/features/004-srv6-service-requests/gates/proofs/` (FR-039, SC-015).
- The supported set this file decides is what
  `lab/profiles/sonic-vm/srv6-supported.yaml` may declare; an item without a
  `proven` verdict is refused by name, never half-delivered (spec FR-005,
  tasks rule on `(V:x)` tags).
- A service never creates, changes or removes a node locator (FR-006); the
  locator work below belongs to the bootstrap, not to any service.

Verdict vocabulary for the tables: `proven`, `not achievable`, `deferred`
(owner decision 1 allows deferring bridged EVPN; requests for a deferred or
unproven item are refused by name).

## 1. Underlay and locators

**Status: empty — no attempt recorded.**

Approaches to try (written before the first attempt):

- Per-node identity at boot first: per-node IPv4 and IPv6 loopbacks, the ASNs
  already in the topology labels (65000 spines, 65101/65102 leaves), router
  ids, IPv6 addressing or unnumbered peering on the four fabric links, and
  underlay BGP for IPv4 and IPv6 unicast — replacing the image default where
  every guest boots as `Loopback0 10.1.0.1/32`, AS 65100 (research addendum,
  item 4). No locator is reachable until this holds (SC-002).
- One locator per node from a common block, uSID style
  (`fcbb:bbbb:<node>::/48` as the candidate block), matching the `uN`/`uDT46`
  rows the gate already writes through GCU; owned by the bootstrap and
  advertised into the IPv6 underlay (research addendum, item 6).
- Locator rows written via GCU `config apply-patch` over SSH — the write path
  the 202505 YANG already accepts — then read back over TLS gNMI, as the gate
  does today; not gNMI Set.
- FRR `segment-routing srv6` locator configured per node so
  `show segment-routing srv6 locator` lists it (FRR answers with an empty
  table today; the daemon supports SRv6 and nothing is configured).
- `seg6_enabled=1` on the fabric interfaces
  (`net.ipv6.conf.all.seg6_enabled` is 0 on the guest today), and
  `net.vrf.strict_mode=1` if `End.DT46` needs it — a kernel requirement stated
  from general knowledge, to confirm or refute in the spike (data-model §8.8).
- Classic (non-uSID) `End`/`End.DT46` behaviour as a fallback if uSID rows
  accept but do not forward.
- Kernel seg6 lwtunnel witness installed on a real interface (`Loopback0`),
  never on `dev lo`: on the guest `dev lo` returns 0 but silently drops the
  encap, which is the false negative that made the gate record two skips as
  passes (research addendum).

| item | verdict | proofs | note |
| --- | --- | --- | --- |
|  |  |  |  |

## 2. `ip-vrf` / `vpn` (routed service over SRv6)

**Status: empty — no attempt recorded.**

Approaches to try (written before the first attempt):

- Per-VRF `End.DT46` SID with `decap_vrf` set to the customer VRF (the gate
  writes `decap_vrf: default` today; a non-default `decap_vrf` is not yet
  exercised anywhere).
- Per-service SID function value allocated from the node locator's function
  block; VRF name derived from the service id — the identifier candidates in
  data-model §8.1, to be confirmed with real ranges.
- BGP signals the per-VRF SRv6 SID to the remote PE (routed service over
  SRv6, vpn signalling in FRR on 202505 — presence and shape to be confirmed
  by the spike; nothing here is verified).
- Encapsulation by the ingress leaf toward the remote locator's `uN` SID: with
  ASIC `vs`, the Linux kernel is the forwarding plane, so a kernel `seg6`
  route encapsulation is the dataplane candidate (research addendum).
- Client attachment: `srv6-client01` on `leaf01` and `srv6-client02` on
  `leaf02` (the `eth4` attachments the research names) placed in the customer
  VRF; client-to-client traffic is the acceptance bar (owner decision 2,
  SC-005).

| item | verdict | proofs | note |
| --- | --- | --- | --- |
|  |  |  |  |

## 3. `ip-vrf` / `evpn` (routed EVPN over SRv6)

**Status: empty — no attempt recorded.**

Approaches to try (written before the first attempt):

- EVPN Type-5 (IP-prefix) routes carrying the per-VRF SRv6 SID, reusing the
  iBGP L2VPN EVPN AF session the gate already reaches Established across
  leaf-spine-leaf; the session today asserts no route of any type.
- Per-VRF `End.DT46` decapsulation as in §2, with the SID learnt through EVPN
  signalling instead of VPN signalling.
- Ingress encapsulation as in §2 (kernel `seg6` on the `vs` ASIC).
- Same client attachment and traffic bar as §2, so the two routed variants
  differ only in signalling.

| item | verdict | proofs | note |
| --- | --- | --- | --- |
|  |  |  |  |

## 4. `mac-vrf` / `evpn` (bridged EVPN over SRv6)

**Status: empty — no attempt recorded.** The owner allows deferring this
variant (owner decision 1); if deferred or unproven, requests are refused by
name.

Approaches to try (written before the first attempt):

- EVPN Type-2/3 MAC/IP routes over SRv6 with a per-EVI or per-(EVI, VLAN)
  End.DX2-style SID — the SRv6 equivalent of the VXLAN bridged service; SID
  scope per EVI or per VLAN is a spike question.
- The operator-supplied VLAN tag (as in feature 003) carried on the attachment
  ports, bridged into the EVI.
- Kernel bridging plus `seg6` encapsulation on the `vs` ASIC as the dataplane
  candidate, as in §2.

| item | verdict | proofs | note |
| --- | --- | --- | --- |
|  |  |  |  |

## 5. Steering

**Status: empty — no attempt recorded.**

Approaches to try (written before the first attempt):

- Two spines give two equal paths; preference expressed on the ingress leaf
  only (the renderer never emits ops for a spine —
  `specs/004-srv6-service-requests/contracts/fabricplan-srv6.md` §1), by
  either an explicit SID list through the preferred spine or a lower path
  preference/metric — which of the two the image supports is a spike question.
- Failover to the alternate spine and return on restoration, bounded by 5
  seconds with at most 2 consecutive losses after the switch (SC-007,
  FR-026a); measured with 1 Hz probes from the client attachments, as
  `tests/integration/srv6_failover_path_change.sh` does today.
- Detection via BFD or fast BGP timers if passive convergence misses the 5 s
  bound (timers are a data-model §8.8 baseline question).
- The read-back that shows the active path (data-model §8.6), recorded as the
  per-node check that backs any steering verdict.

| item | verdict | proofs | note |
| --- | --- | --- | --- |
|  |  |  |  |
