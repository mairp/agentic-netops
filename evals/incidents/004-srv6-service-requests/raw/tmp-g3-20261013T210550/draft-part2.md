
## Service chain: `ip-vrf` / `vpn` (T074–T081)

All proofs replay self-contained: each body re-establishes whatever it needs
(`scripts/spike/ensure-fabric.sh` fast probe, `vrf-apply.sh`, `vpn-setup.sh`) before asserting.

- **T074 Vrf1 + attachment on leaf01** — proof `spike-vpn-state-leaf01`, body
  `scripts/spike/vrf-apply.sh leaf01`: GCU field-level adds — `/VRF/Vrf1` + `INTERFACE|Ethernet12`
  (`vrf_name=Vrf1`, access prefix 192.168.1.1/24) — then CONFIG_DB + kernel read-backs
  (`ip -br link show Vrf1`, `ip -br addr show Ethernet12`, redis `VRF|Vrf*`,
  `INTERFACE|Ethernet12*`) and `APPLIED`. Write class measured on this image: **field-level adds
  onto the EXISTING /INTERFACE table** (a whole-table replace wipes the fabric /31 /127 rows);
  VRF rows need `{}` (no `admin_status`).
- **T075 same on leaf02** — proof `spike-vpn-state-leaf02` (192.168.2.1/24).
- **T076 decap + steering routes leaf01** — proof `spike-vpn-readback-leaf01`, body
  `bash scripts/spike/vpn-readback.sh leaf01`: service SID `fcbb:bbbb:3:11::/64 encap seg6local
  action End.DT46 vrftable 1001 dev Vrf1` + ingress steering
  `192.168.2.0/24 vrf Vrf1 encap seg6 mode encap segs 1 [fcbb:bbbb:4:11::] dev Ethernet0`,
  plus locator/VRF/attachment read-backs. (The `dev lo` encap false negative and the
  `dev <physical>` EINVAL were measured on the way; the working form is `dev Vrf1` /
  `dev Loopback0`-class devices only.)
- **T077 leaf02** — proof `spike-vpn-readback-leaf02` (mirror: decap `fcbb:bbbb:4:11::`, steering
  toward `fcbb:bbbb:3:11::`).
- **T078 client-side** — proof `spike-vpn-clients`, body `bash scripts/spike/vpn-clients.sh`:
  builder re-asserts client addresses/routes (srv6-client01 192.168.1.2/24 gw .1,
  srv6-client02 192.168.2.2/24 gw .1, v6 pairs 2001:db8:1::2/64 gw ::1 style) on the two
  srv6-client containers (`client_run`), reads them back, and pings each gateway from its client.
- **T079 dataplane** — proof `spike-vpn-ping`, body `scripts/spike/vpn-ping.sh` (normalized per
  FR-039): client01→client02 and client02→client01, v4 AND v6, default size and **8900-byte DF**
  — `3 received, 0% packet loss` in all eight runs; marker `probe size confirmed: 8900-byte
  payload DF passes both directions`.
- **T080 wire witness** — proof `spike-vpn-capture`, body `scripts/spike/vpn-capture.sh`:
  tcpdump on the leaf uplink during the probe — outer IPv6 + **Routing header type 4** with
  segment `[0]fcbb:bbbb:4:11::` over the 8900-byte DF payload; the FIB line
  `fcbb:bbbb:4:11::/64 encap seg6local action End.DT46 vrftable 1001 dev Vrf1` is printed next to
  the capture as the programmed SID (`--- the service SID carried on the wire: …`).
- **T081 rollback** — proof `spike-vpn-rollback`, body `bash scripts/spike/vpn-rollback.sh`:
  removes service routes/steering, Vrf1 + Ethernet12 rows (GCU), client config; asserts
  CONFIG_DB + kernel absence AND that the fabric underlay rows survived (2× `INTERFACE-RESTORED`
  markers — the earlier silent wipe of /INTERFACE by a whole-table replace is fixed and its
  guard is part of the proof); dataplane then fails (expected 100% loss, exit 0). Honest note:
  the post-rollback negative ping is EXPECTED to fail — the proof asserts the failure.

Recipe written up: `docs/SRV6_SERVICE_RECIPE.md` §2 + §2a (as-built details) + §2b (rollback) +
§2c (the `SRV6_MY_SIDS` write class) — **T082**.

### 2c write-class investigation (embedded in T076/T082 evidence)

Proof `spike-sid-write` (T076 companion, body `bash scripts/spike/sid-write.sh`): the CONFIG_DB
`SRV6_MY_SIDS` row (`loc-<n>|fcbb:bbbb:<n>:11::/64`, `action=uDT46`, `decap_vrf=Vrf1`) is
ACCEPTED by the 202505 YANG (its `decap_vrf` leafref even rejects a bogus VRF) but a bounded
reproduction of its programming effect did not reproduce → not relied on; the as-built decap is
the kernel route (§8.3 table row "Alternative decap write class").

## Negative variants (T083–T095)

- **T083–T088 `ip-vrf`/`evpn`** — proofs `spike-evpn3-state-leaf01`, `-state-leaf02`,
  `-ping`, `-capture`, `-kl006`, `-rollback` (bodies `scripts/spike/evpn3-*.sh`):
  EVPN AF sessions establish (`peer … state Established pfxRcd 0`), the VRFsNI devices and
  export knobs (rd/rt/sid vpn export) all apply, but `Number of L3 VNIs: 0` on BOTH leaves —
  the zebra→bgpd L3VNI ZAPI handoff never delivers — and this bgpd has **no vpnv4/vpnv6 AF**
  (`% Unknown command` / missing AF), so `spike-evpn3-ping` shows 100% client loss in every
  EVPN dataplane phase (the only passing pings are the underlay/locator sanity probes).
  `spike-evpn3-kl006` adds the KL-006 probe: even the synthetic IPv6 Type-5 route cannot exist
  (unknown `network` in the VRF IPv6 AF), so the limitation is upstream-moot here.
  `spike-evpn3-rollback` restores the §2 as-built state (assert block prints both leaves'
  End.DT46 + steering lines) and drops the EVPN AF/knobs/devices.
- **T090–T094 `mac-vrf`/`evpn`** — proofs `spike-evpn2-state-leaf01/-leaf02`, `-ping`,
  `-capture`, `-rollback` (bodies `scripts/spike/evpn2-*.sh`): L2VNI 100 programs in zebra
  (`100 L2 vxlan-100`), bgpd sees `Number of L2 VNIs: 1`, Type-3 IMET routes exchange
  (`[3]:[0]:[32]:…` local + remote) — but after client traffic the EVPN MAC table holds
  **0 entries** (`MAC-ENTRIES: 0`, no Type-2 learning) and the bridged dataplane never
  forwards (client ping 100% loss). Rollback restores.
- **T089/T095 write-ups** — `docs/SRV6_SERVICE_RECIPE.md` §3 (`ip-vrf`/`evpn` negative chain,
  per-item verdicts) and §4 (`mac-vrf`/`evpn`); honest-negative register in
  `lab/profiles/sonic-vm/srv6-supported.yaml` (`honest_negatives` list).

## Steering (T096–T101)

- **T096 explicit path** — proof `spike-steering-path`, body `bash scripts/spike/steering-path.sh`:
  pins the /64 toward the peer service SID via the chosen spine leg on each leaf (kernel
  `fcbb:bbbb:<peer>::/48 via <spine link v6> dev Ethernet0 metric 5` — REQUIRED: zebra refuses
  the encap nexthop-group without it, the v4-mapped nexthop otherwise wins the ECMP); FIB
  read-back both directions + SRH capture on BOTH uplinks: preferred leg NONZERO, alternate leg 0.
- **T097–T099 failure actions** — proofs `spike-steering-failover-launcher` /
  `-guest-if` / `-bgp` (body `bash scripts/spike/steering-failover.sh <launcher|guest|bgp>`):
  fail the active launcher link / the leaf guest port / the BGP session for probes 7–14 of a
  20-probe 1 Hz run; each prints the loss classifiers only (FR-039: raw probe rows live in
  §8.6 of data-model): `PROBES: 20 at 1 Hz`, `LOSS-BOUNDED: yes (missed<=10, longest-run<=10)`.
  **Honest negative**: loss is bounded but the SC-007 "5 s" bound is NOT met (reconvergence
  takes seconds-to-tens-of-seconds; no BFD on this image) — recorded in
  `srv6-supported.yaml` (steering verdict note) and data-model §8.6.
- **T100 return** — proof `spike-steering-return` (failover body `return`): preferred path
  restored, FIB re-read, `LOSS-BOUNDED: yes`.
- **T101 write-up** — `docs/SRV6_SERVICE_RECIPE.md` §5 (+ §5a as-built: the pinned /48
  requirement, the pin commands, the classifier-only proof output rule).

## Counters, persistence, fresh redeploy (T102–T104)

- **T102 counters** — proof `spike-counters`, body `scripts/spike/vpn-counters.sh`: COUNTERS_DB
  SRv6 tables on both leaves show `SRV6_MY_LOCATORS|loc-<n>` in db4 (SAI_PROGRAMMABLE table
  present); kernel `nstat Seg6*` has **no** entries on this kernel build
  (`NO-SEG6-NSTAT-ENTRIES`) → the honest dataplane substitute is the client probe
  (`3 received, 0% packet loss`) recorded in the same proof. Data-model §8.6 documents the
  counter conclusion.
- **T103 persistence** — proof `spike-persistence`, body `bash scripts/spike/persistence.sh`:
  `config reload -y` on leaf01 keeps the locator in CONFIG_DB + FRR (`LOCATOR-VTYSH: 1`) but
  loses ALL kernel state (decap/steering/pins → 0) and is NOT rebuilt by the image; the
  as-built answer is builder-rebuild (`vpn-setup.sh` after reload). Recorded as an honest
  negative in recipe §1a and §2b.
- **T104 fresh redeploy** — `./scripts/provision.sh --profile sonic-vm` from scratch: receipt
  `proofs/p3-t104-fresh-redeploy.txt` (attempt 2 rc=0; attempt 1 rc=1 documented in PROGRESS.md
  pass 10 — capability-gate EVPN-Type2 witness miss, fixed in the gate's witness, not in the
  lab). All spike baselines were recorded on this fresh lab.
