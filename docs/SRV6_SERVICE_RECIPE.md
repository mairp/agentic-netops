# SRv6 Service Recipe (feature 004)

**Status: measured on the pinned sonic-vm lab (sonic image 202505, ASIC `vs`).
Every verdict below cites recorded proofs; nothing is invented.** The
as-built dataplane for a routed VPN service is the Linux kernel `seg6`/
`seg6local` on the guest (the `vs` ASIC makes the kernel the forwarding
plane); BGP carries the underlay and the locators, not the service SID.

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

Verdict vocabulary for the tables: `proven` or `not achievable` — the two
verdicts `srv6-supported.yaml` carries (tasks T110). Owner decision 1 permits
deferring bridged EVPN; the deferral is recorded as `not achievable` here
(the measured outcome is the same: the bridged service does not forward on
the as-built lab), and requests for any unproven item are refused by name.

## 1. Underlay and locators

**Status: proven on the pinned sonic-vm lab.** The underlay (per-node
identity, fabric addressing, IPv4+IPv6 BGP) and one locator per node are
bootstrap-owned (`scripts/spike/identity-assert.sh`, `underlay-apply.sh`,
`locator-node.sh`); a service never touches them (FR-006).

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
| per-node identity (loopbacks v4/v6, ASN, router-id) | proven | `spike-identity-spine01`, `spike-identity-spine02`, `spike-identity-leaf01`, `spike-identity-leaf02` | replaces the image default (Loopback0 10.1.0.1/32, AS 65100); idempotent re-assert |
| fabric link addressing (/31 v4 + /127 v6, 4 links) | proven | `spike-underlay-v4`, `spike-underlay-v6`, `spike-underlay-v4-leaf01` … per node | measured addresses match §7 of data-model.md |
| underlay BGP IPv4 + IPv6 unicast established | proven | `spike-underlay-apply-leaf01` … per node, `spike-underlay-v4`, `spike-underlay-v6` | 2 sessions per family per leaf, 3 per spine; loopback reachability both families |
| one locator per node via GCU (CONFIG_DB) + FRR | proven | `spike-locator-spine01`, `spike-locator-spine02`, `spike-locator-leaf01`, `spike-locator-leaf02` | `fcbb:bbbb:<node>::/48`, `loc-<node>` Up in the FRR locator table and in CONFIG_DB |
| locator end-to-end reachability | proven | `spike-locator-reach` | 12/12 ordered pairs pass (test address inside each /48) |
| `seg6_enabled` + `net.vrf.strict_mode` | proven | `spike-kernel-seg6`, `spike-kernel-strict-mode` | knobs are 0 on the factory image; write path is `/proc/sys` (no sysctl binary on the guest) |
| `vrf` kernel module | proven | `spike-kernel-vrf-module` | not loaded on a fresh boot; auto-loads on first VRF device |
| seg6 lwtunnel witness on a real interface | proven | `spike-kernel-seg6` | `Loopback0` works; `dev lo` silently drops the encap (false negative confirmed) |
| guest port map (EthernetN ↔ launcher iface) | proven | `spike-portmap-leaf01`, `spike-portmap-spine01`, `spike-portmap-spine02`, `spike-portmap-leaf02` | recorded for captures and failure actions |

### 1a. As-built locator recipe

- Locator row: GCU add onto `/SRV6_MY_LOCATORS` —
  `locator_name: loc-<node>`, `prefix: fcbb:bbbb:<node>::/48` — plus the FRR
  half under `router bgp <asn>`: `segment-routing srv6 locator loc-<node>`,
  and the /48 advertised (`ipv6 route fcbb:bbbb:<node>::/48 Loopback0` +
  `network fcbb:bbbb:<node>::/64`… as measured in the locator proofs:
  the /48 origination is a kernel static + BGP `network`).
- Read-back: `redis-cli -n 4 --scan --pattern 'SRV6_MY_LOCATORS*'` (CONFIG_DB),
  `show segment-routing srv6 locator` (FRR), `ip -6 route show` (the /48 as a
  `proto 196` static).
- **Persistence caveat (measured, `spike-persistence`)**: after
  `config reload -y` the locator survives in CONFIG_DB and FRR, but ALL
  kernel state is lost and the FRR locator line is not restored by the image;
  the bootstrap must re-run after any reload. This is an honest
  negative — the recipe treats the fabric as rebuilt-by-builder, not
  persisted-on-device.

## 2. `ip-vrf` / `vpn` (routed service over SRv6)

**Status: proven on the pinned sonic-vm lab** — the routed service forwards
client-to-client (0% loss at default size and at 8900-byte DF,
`spike-vpn-ping`), with SRH encapsulation witnessed on the fabric
(`spike-vpn-capture`) and a clean rollback (`spike-vpn-rollback`). One leg of
this variant is recorded not-achievable on this bgpd build: BGP vpnv4/vpnv6
signalling of the service SID — the address-family commands do not exist in
this image, so the dataplane is the as-built kernel encap (see the table and
§2a).

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
| Vrf1 create + client-port attach (CONFIG_DB) | proven | `spike-vrf-apply-leaf01`, `spike-vpn-state-leaf02` | field-level GCU adds; a whole-table `/INTERFACE` replace WIPES the fabric links (measured) — never remove what the service does not own |
| per-service End.DT46 decap | proven | `spike-vpn-state-leaf01`, `spike-vpn-state-leaf02`, `spike-vpn-readback-leaf01` | kernel route `fcbb:bbbb:<n>:11::/64 encap seg6local action End.DT46 vrftable 1001 count dev Vrf1 metric 1024`; the `count` flag (T560) turns on the kernel's per-SID counters — `ip -s -6 route show` then reports `packets N bytes M errors 0` on the route line |
| ingress encapsulation toward the peer SID | proven | `spike-vpn-capture`, `spike-steering-path` | kernel route in Vrf1: `<peer-subnet> encap seg6 mode encap segs 1 [ fcbb:bbbb:<peer>:11:: ] dev Ethernet0` |
| wire format witness (SRH on the fabric) | proven | `spike-vpn-capture` | tcpdump shows IPv6 + Routing header dst = the peer service SID; decap witnessed on the egress leaf's kernel route |
| client-to-client traffic (acceptance bar) | proven | `spike-vpn-ping`, `spike-vpn-clients` | 0% loss both directions at default size AND 8900-byte payload DF |
| BGP-signalled service SID (vpnv4/vpnv6) | not achievable | `spike-vpn-readback-leaf01`, `spike-vpn-readback-leaf02` | this bgpd build does not carry the `address-family vpnv4/vpnv6 unicast` commands at all; the dataplane is the as-built kernel encap |
| CONFIG_DB `SRV6_MY_SIDS` write class | proven — accepted, then reverted (not used as-built) | `spike-sid-write` | see §2c; the image YANG accepts a YANG-valid row and its `decap_vrf` leafref enforces integrity, but a bounded reproduction of its programming effect did not reproduce → not relied on |
| rollback to factory service state | proven | `spike-vpn-rollback` | routes, `/INTERFACE` attach, `/VRF` row removed (own-process GCU removes); CONFIG_DB read-back shows no VRF/attach/SID rows, 0 seg6local routes, clients flushed; locator untouched |
| persistence across `config reload -y` | not achievable | `spike-persistence` | locator survives; every piece of service kernel state is lost; rebuild = re-run the builder (see §1a caveat) |

### 2a. As-built service recipe (`ip-vrf` / `vpn`)

Device commands, in order (builders: `scripts/spike/vrf-apply.sh`,
`vpn-setup.sh`; replayed as `spike-vpn-*` proofs):

1. **VRF + attachment** (GCU `config apply-patch` over SSH, CONFIG_DB class):
   `/VRF/Vrf1` (whole-table add is safe on a factory node; on any node that
   already has VRFs use field-level adds), `Ethernet12 vrf_name=Vrf1`
   (field-level add onto the existing `/INTERFACE` table — a whole-table
   replace destroys the fabric link rows), access prefix `192.168.1.1/24` via
   JSON-pointer `~1` escaping.
2. **Kernel prerequisites**: `vrf` module auto-loads; `seg6_enabled=1` on
   `all/default/Ethernet0/Ethernet4/Loopback0`; `net.vrf.strict_mode=1`
   (`/proc/sys` is the only write path — no sysctl binary on the guest).
3. **Service SID (per node)**: originate the locator /48
   (`ipv6 route fcbb:bbbb:<n>::/48 Loopback0` + BGP `network`), then assert
   the decap: `ip -6 route replace fcbb:bbbb:<n>:11::/64 encap seg6local
   action End.DT46 vrftable 1001 count dev Vrf1` (the Vrf1 table id is 1001
   for leaf01 / 1002 for leaf02 — read from the device, do not assume;
   `count` is the seg6local per-behavior counter flag, T560, and sits
   INSIDE the encap clause — before `dev`).
4. **Ingress steering (per node, in Vrf1)**: `ip route replace
   <peer-subnet> vrf Vrf1 encap seg6 mode encap segs 1 [ fcbb:bbbb:<peer>:11:: ]
   dev Ethernet0` — the underlay route toward the peer locator /48 is pinned
   (`metric 5` kernel static) so zebra keeps a consistent nhg; without the
   pin zebra refuses to install the encap from an IPv4-mapped IPv6 nexthop
   (measured).
5. **Clients**: the two srv6-client containers get their /24 on `eth1`.

Read-backs (all recorded in `spike-vpn-readback-leaf01/leaf02`): the decap
kernel route per node, the steering route per node, the client addressing,
the FRR locator table, and the honest negatives (no vpnv4/vpnv6 AFs; no BGP
/48 in the table — the /48 travels as a kernel static + BGP `network`).

### 2b. Rollback

`scripts/spike/vpn-rollback.sh` (proof `spike-vpn-rollback`): remove the
kernel routes first (loop-del until gone — the as-built decap and any zebra
static are separate routes for the same prefix), remove `/INTERFACE` and
`/VRF` in their own processes (GCU wedge semantics; removals in the same
process as adds raise), restore the fabric `/INTERFACE` rows, flush the
client ports, assert: no VRF/attach/SID rows, 0 seg6local routes, locator
untouched. The kernel `Vrf1` device itself lingers after row removal (image
behaviour — only a re-provision clears it); recorded honestly.

### 2c. The `SRV6_MY_SIDS` CONFIG_DB write class (measured, not used as-built)

`spike-sid-write` proves the write class end to end on the live image:

- A payload with a `prefix_len` field is REJECTED
  (`All Keys are not parsed in SRV6_MY_SIDS … exceptionList:["'prefix_len'"]`)
  — the 202505 `sonic-srv6.yang` models composite key `locator|ip_prefix`
  (e.g. `loc-leaf01|fcbb:bbbb:3:11::/64`) with `action` + `decap_vrf` only.
- `decap_vrf` is a YANG leafref into `/VRF`: a row naming an unknown VRF is
  rejected, and while a valid row exists `/VRF` cannot be removed
  (`VRF-REMOVE-REJECTED ValueError`) — the row is live, integrity-checked
  config, not a no-op.
- The YANG-valid row is ACCEPTED on both leaves and reads back from
  CONFIG_DB with `action=uDT46`, `decap_vrf=Vrf1`.
- **Not relied on as-built**: during one earlier lab session the row's SRv6
  orchestration programmed a uDT46 decap through zebra (kernel
  `proto 196 metric 20`); bounded reproduction attempts (60 s polls on add)
  did not reproduce it, so the as-built dataplane does not depend on it —
  the builder asserts the kernel route directly (§2a step 3) and the write
  class is proven + reverted in the same proof.

## 3. `ip-vrf` / `evpn` (routed EVPN over SRv6)

**Status: not achievable on this image.** The EVPN control-plane session
forms and EVPN AF configuration is accepted, but no EVPN-derived forwarding
state can be produced for a L3VNI service, and every honest attempt at an
EVPN-signalled dataplane shows 100% client loss.

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
| L2VPN EVPN AF session across leaf-spine-leaf | proven (session only) | `spike-evpn3-state-leaf01`, `spike-evpn2-state-leaf01` | 3/3 peers Established — but pfxRcd 0 for any L3VNI attempt |
| L3VNI → bgpd handoff (Type-5 precondition) | not achievable | `spike-evpn3-state-leaf01`, `spike-evpn3-state-leaf02` | zebra knows the kernel L3VNI (`vxlan-1001`, tenant Vrf1) but bgpd's VNI view reports `Number of L3 VNIs: 0` — the zebra→bgpd VNI ZAPI handoff never delivers the L3VNI, so no Type-5 route can be generated |
| IPv6 Type-5 export knobs in `vrf Vrf1` AF6 | not achievable | `spike-evpn3-kl006` | `sid vpn export auto` / `rd vpn export` / `rt vpn both` stick, but `network <prefix>` is `% Unknown command` inside the VRF IPv6 AF; the EVPN table stays empty (KL-006 recorded as upstream-moot here) |
| dataplane without BGP state (RT-leak attempt) | not achievable | `spike-evpn3-ping` | 100% loss both with only leaked default-table state and with ONLY EVPN signalling standing (knobs removed); the leaked subnets are a config smell the honest attempt also exposes |
| restore of the §2 as-built after the attempts | proven | `spike-evpn3-ping` (leg C), `spike-evpn3-rollback` | steering routes + decap back, client traffic 0% loss again |
| verdict for the renderer | **not achievable** | all of the above | `srv6-supported.yaml` refuses `ip-vrf`+`evpn` by name |

## 4. `mac-vrf` / `evpn` (bridged EVPN over SRv6)

**Status: not achievable on the as-built lab (owner decision 1 separately
permits deferring bridged EVPN; the recorded attempts are here either way).**
Bridged (L2VNI) signalling between the leaves works; the bridged service
itself is not deliverable on the as-built lab.

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
| L2VNI + Type-3 IMET signalling | proven (signalling only) | `spike-evpn2-state-leaf01`, `spike-evpn2-state-leaf02` | kernel+zebra see `vxlan-100` (L2) and `vxlan-1001` (L3); the EVPN table exchanges exactly the 2 expected IMETs (`Displayed 2 out of 4 total prefixes`) |
| bridged dataplane (MAC learning, L2 forwarding) | not achievable on the as-built lab | `spike-evpn2-ping` | 0 MAC entries learnt after client traffic; no Type-2 routes; client traffic only passes via the §2 routed encap, not any bridged path |
| rollback of the L2VNI attempt | proven | `spike-evpn2-rollback` | full EVPN teardown re-uses the evpn3 rollback; §2 as-built restored |
| verdict for the renderer | **not achievable** (owner decision 1 separately permits deferral) | all of the above | `srv6-supported.yaml` declares it not-achievable; requests are refused by name |

## 5. Steering

**Status: proven for an explicit pinned path; the SC-007 failover SLO
(≤2 lost probes within 5 s) is NOT met, with measured per-action loss
classes: launcher-link-down and BGP-shutdown failovers are loss-bounded at
`missed<=10, longest-run<=10` lost 1 Hz probes, while guest-if-down failover
and the return-on-restoration leg each EXCEED the 10-probe bound (recorded
`LOSS-BOUNDED: NO`).** Steering exists as an explicit per-service pin on
the ingress leaf; nothing is ever emitted for a spine (contract §1).

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
| explicit per-service path pin through a chosen spine | proven | `spike-steering-path` | kernel FIB on leaf01: `fcbb:bbbb:4:11:: from :: via 2001:db8:1::3 dev Ethernet0 proto 196 metric 20` (spine01 leg); SRH packets seen ONLY on the preferred leg's uplink, 0 on the alternate |
| steering read-back (the §8.6 check) | proven | `spike-steering-path`, `spike-steering-failover-bgp` | the kernel FIB line above IS the read-back; captured per node |
| failover on a failure action (link down / iface down / BGP shutdown) | proven with honest SLO misses | `spike-steering-failover-launcher`, `spike-steering-failover-guest-if`, `spike-steering-failover-bgp` | the switch to the alternate spine happens and traffic resumes on all three actions; measured loss at 1 Hz: launcher-link-down `LOSS-BOUNDED: yes (missed<=10, longest-run<=10)`, BGP-shutdown `LOSS-BOUNDED: yes`, guest-if-down `LOSS-BOUNDED: NO (exceeds the 10-probe bound)` — the SC-007 ≤2-loss/5 s bound is met by NO action (no BFD; passive detection only) |
| return on restoration | proven with an honest SLO miss | `spike-steering-return` | preferred path returns in the FIB; measured loss EXCEEDS the 10-probe bound (recorded `LOSS-BOUNDED: NO (exceeds the 10-probe bound)`) |
| BFD / fast-timer detection | not attempted | — | out of scope for the pinned-path mechanism; recorded as the reason the 5 s bound is unmet |
| steering removal leaves no residue | proven | `spike-steering-failover-bgp`, `spike-steering-return` | `LEFTOVER-PINS: 0`; as-built client traffic 0% loss both directions afterwards |

### 5a. As-built steering recipe

- Pin: `ip -6 route replace fcbb:bbbb:<peer>:11:: from :: via <spine-link-v6>
  dev Ethernet0 metric 20` on the ingress leaf — a per-service /64 host route
  through the preferred spine's link address (this is what the proofs record;
  it also carries the SRC pinning `from ::` that zebra needs to keep the nhg
  usable).
- Failover action = delete the pin and install the same route via the
  alternate spine's link address; return = the reverse. The service-level
  steering route (`vrf Vrf1 … encap seg6`) is untouched by steering.
- Read-back: `ip -6 route show | grep 'fcbb:bbbb:<peer>:11'` per node; the
  wire witness is the tcpdump leg check in `spike-steering-path`.

## 6. Exit-gate review (phase 3, T124)

| variant (port-vrf × overlay) | verdict | refused-by-name behaviour | proofs |
| --- | --- | --- | --- |
| `ip-vrf` / `vpn` | **proven** — end-to-end client traffic, replay-stable proofs, clean rollback | n/a | §2 table |
| `ip-vrf` / `evpn` | **not achievable** (zebra→bgpd L3VNI ZAPI breakage; no vpnv4/vpnv6 AFs in this bgpd) | requests refused by name (`srv6-supported.yaml`) | §3 table |
| `mac-vrf` / `evpn` | **not achievable** (owner decision 1 separately permits deferral; L2VNI signalling works, bridged service not deliverable) | requests refused by name | §4 table |
| steering | **proven** with explicit per-action SLO misses recorded (SC-007 unmet: launcher-link-down and BGP-shutdown bounded at ≤10 lost 1 Hz probes; guest-if-down and return `LOSS-BOUNDED: NO` — above 10) | n/a | §5 table |

Honest-negative register (all measured, none hidden):

1. `config reload -y` loses ALL service kernel state and the FRR locator
   binding; only CONFIG_DB survives (`spike-persistence`). The fabric is
   rebuilt by builders, never persisted on the device.
2. This bgpd build has no `address-family vpnv4/vpnv6 unicast`
   (`spike-vpn-readback-leaf01`), closing the classic vpn-signalled routed
   service path.
3. EVPN L3VNI handoff zebra→bgpd is broken on this image
   (`spike-evpn3-state-*`), closing routed EVPN.
4. Bridged EVPN signals but does not forward (`spike-evpn2-ping`).
5. Failover SLO: passive convergence misses SC-007's 5 s / ≤2-loss bound
   (≤10 lost 1 Hz probes measured).
6. The `SRV6_MY_SIDS` CONFIG_DB write class is accepted and leafref-checked,
   but its programming effect could not be reproduced in bounded polls
   (`spike-sid-write`); the as-built recipe does not depend on it.

Replay-stability: `scripts/proof.sh replay spike-vpn|spike-evpn3|
spike-evpn2|spike-steering` regenerate every cited proof byte-identically on
the live lab (`.record-order` ordering; the vpn group ends with its rollback).
The five `spike-rerun-*` proofs (T105–T109) record the same replays on a
freshly re-provisioned lab as the fresh-lab evidence.
