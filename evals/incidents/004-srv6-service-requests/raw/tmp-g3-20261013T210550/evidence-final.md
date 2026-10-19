# GATE3 Evidence — Phase 3: US1 Feasibility gate (T040–T124)

Phase question: can the pinned sonic-vm image carry an SRv6 VPN service at all? Every verdict
below was measured by running commands directly on the four sonic-vm guests (never through the
controllers, FR-003a: no second person, no manual intervention), recorded with
`scripts/proof.sh <name> -- <command>` into `.wiggum/features/004-srv6-service-requests/gates/proofs/`
(stored exact command in `<name>.cmd`, combined output + exit code in `<name>.out`, order in
`.record-order`).

**Verdicts (the supported set, `lab/profiles/sonic-vm/srv6-supported.yaml`)**

| variant | verdict |
| --- | --- |
| `ip-vrf` / `vpn` | **proven** — client-to-client v4 and v6, default and 8900-byte DF, both directions; wire capture shows the SRH carrying the service SID; clean rollback |
| `ip-vrf` / `evpn` | **not-achievable** — EVPN sessions establish; zebra→bgpd L3VNI handoff dead (0 L3 VNIs); no vpnv4/vpnv6 AF in this bgpd; 100% client loss in every dataplane attempt |
| `mac-vrf` / `evpn` | **not-achievable** — Type-3 IMET signals, no Type-2 MAC learning, no bridged forwarding |
| `steering` | **proven** — explicit per-service pin through the preferred spine; traffic observed only on the preferred leg; failover/return LOSS-BOUNDED (≤10 lost 1 Hz probes; the SC-007 5 s bound is NOT met — honest negative) |

**Reproduction (the Independent Test)**: `scripts/proof.sh replay spike-<item>` re-runs every
stored `.cmd` of the item in recorded order, unattended, and byte-compares each output with its
`.out`; destructive proofs are skipped unless `--all`. The five `spike-rerun-*` proofs (T105–T109)
are the recorded receipts; each ends `… no difference`. The lab the replays run on is brought up
by `./scripts/provision.sh --profile sonic-vm` alone (T104, rc=0 receipt
`proofs/p3-t104-fresh-redeploy.txt`); every service-chain proof body chains
`ensure-fabric.sh` (fast-path probe, silent) or `vpn-setup.sh` so a replay is self-contained on a
freshly provisioned lab — see the slice `proofs/p3-script-ensure-fabric.txt`.

Device-under-test identity: pinned image per `versions.lock.yaml` `sonic_images.sonic_vm`
(`local/sonic-vm:202505`, asserted against the pinned digest at bring-up), kernel
`6.1.0-29-2-amd64`, ASIC `vs` (kernel dataplane). All device commands go through `node_run` from
`tests/integration/lib/node_exec.sh` (SSH into the guest VM; the launcher container is never
exec'd for device commands) — `scripts/spike/spike-env.sh` lines 1–14.

---

## Baseline, per node (T040–T047)

- **T040–T043 baseline captures** — proof `spike-baseline-spine01` / `spine02` / `leaf01` /
  `leaf02`, body `scripts/spike/baseline-capture.sh <node>` (read-only: running config, interface
  status, kernel addresses, FRR running-config, FRR+kernel routes, BGP summaries, SRv6 state,
  daemon cmdlines; timer-shaped fields normalized per FR-039). Capture basis (pass 18): the four
  proofs are re-recorded on the **seed-restored lab** — `scripts/spike/seed-restore.sh` rebuilds
  the EXACT provision seed the first captures recorded (verified: CONFIG_DB BGP_NEIGHBOR /
  INTERFACE / LOOPBACK key sets re-checked after every patch; v4+v6 established-session counts
  gated before capture; the spike's kernel Vrf1 device deleted — the image keeps the device after
  its rows are removed, the factory seed has none; `Bridge`/`dummy` are platform devices, present
  on a fresh spine too). Beyond the elapsed-time normalizers, three classes of **redeploy-volatile
  bytes** are masked at capture time, all hardware identity rather than recipe state (FR-039/SC-15):
  the MAC-derived EUI-64 prefixes kernels auto-add per interface (`fe80::…/64` → `fe80::LL/64`),
  the VM NIC MACs (→ `MAC`), and the down-session State token of neighbors that cannot establish
  in the seed (spine02's iBGP rows point at a peer with no matching rows; `timers connect 10`
  flips the State column Connect/Active every retry — a timing artifact, masked `→ DOWN`;
  established sessions keep their real PfxRcd numbers). See `proofs/p3-baseline-fresh.txt`.
- **T044–T047 guest-port map** — proof `spike-portmap-spine01` / `spine02` / `leaf01` /
  `leaf02`, body `scripts/spike/portmap-capture.sh <node>`: icmp6 tcpdump per launcher link while
  the peer pings `ff02::1`; result on all four nodes launcher `eth1..eth4` → guest `eth1..eth4` →
  SONiC `Ethernet0/4/8/12` (leaf01: eth1↔spine01, eth2↔spine02, eth3↔client01, eth4↔
  srv6-client01; leaf02 mirror). The map is what later proofs use for captures (launcher `eth1`/
  `eth2` = the two spine legs) and failure actions.

## Factory clean + per-node identity (T048–T055)

- **T048–T051 factory rows removed** — proof `spike-factory-spine01` / `spine02` / `leaf01` /
  `leaf02`, body `scripts/spike/factory-clean.sh <node>`: removes the factory `BGP_NEIGHBOR`
  (32 rows) and `INTERFACE` (64 rows) tables through the GCU and reads back that only the
  declared rows remain (CONFIG_DB `--scan` + kernel addresses + FRR summary read-backs in the
  same `.out` — the mutation response is not the witness).
- **T052–T055 identity asserted** — proof `spike-identity-spine01` / `spine02` / `leaf01` /
  `leaf02`, body `scripts/spike/identity-assert.sh <node>`: DEVICE_METADATA (hostname, `bgp_asn`
  65000/65101/65102, `bgp_router_id`, `bgp_adv_lo_prefix_as_128=true`) + LOOPBACK_INTERFACE
  (§7: `10.0.0.<11,12,21,22>/32`, `2001:db8:ff::<11,12,21,22>/128`), read back from CONFIG_DB and
  the kernel. Plan `data-model.md` §7 table (lines 152–155).

## Underlay (T056–T065)

- **T056–T059 IPv4 /31 + sessions per node** — proof `spike-underlay-v4-spine01` / `-spine02` /
  `-leaf01` / `-leaf02`, body `scripts/spike/underlay-node.sh v4 <node>`: GCU rows
  (`INTERFACE|Ethernet0|10.1.0.{0,2,1,3}/31`, `INTERFACE|Ethernet4|…/31`), `BGP_NEIGHBOR` per
  §7, bounded establishment wait, read-back (BGP summary + kernel addresses).
- **T060 IPv4 underlay total** — proof `spike-underlay-v4`, body
  `scripts/spike/underlay-verify.sh v4`: 4 of 4 sessions Established
  (leaf↔spine ×2 per leaf + spine↔spine iBGP over loopbacks) and **TOTAL REACHABILITY v4: 12/12**
  ordered pairs (loopback-sourced pings).
- **T061–T064 IPv6 /127 + sessions per node** — proof `spike-underlay-v6-<node>`; **T065** proof
  `spike-underlay-v6`: 4 of 4 v6 sessions Established, **TOTAL REACHABILITY v6: 12/12**, /128
  loopbacks originated (requires DEVICE_METADATA `bgp_adv_lo_prefix_as_128=true` — without it
  202505 bgpd masks the v6 loopback to /64; measured, recorded in `docs/SRV6_SERVICE_RECIPE.md`
  §1 approaches).
- Applied-state receipts: `spike-underlay-apply-<node>` (the one-shot GCU apply per node).

## Kernel prerequisites and locators (T066–T073)

- **T066 seg6_enabled** — proof `spike-kernel-seg6`, body `scripts/spike/kernel-seg6.sh`:
  factory value 0; set via `/proc/sys/net/ipv6/conf/{all,default,Ethernet0,Ethernet4,
  Loopback0}/seg6_enabled` (no sysctl binary on the guest); decap dependency measured live:
  `DECAP-DEPENDENCY seg6=1:PASS seg6=0:FAIL` (End.DT46 decap needs `seg6_enabled=1` on the
  actual ingress ports; the ECMP hash can pick either fabric leg, so both are set).
- **T067 vrf module** — proof `spike-kernel-vrf-module`: not loaded on fresh boot; auto-loads on
  the first VRF device create (measured).
- **T068 strict mode** — proof `spike-kernel-strict-mode`: factory 0; End.DT46 decap into a VRF
  needs `net.vrf.strict_mode=1`; write path `/proc/sys/net/vrf/strict_mode`.
- **T069 locator write-class trial (leaf01)** — the recorded proof is `spike-locator-leaf01`
  (`scripts/spike/locator-node.sh leaf01`): `APPLIED`, redis read-back `fcbb:bbbb:3::`, FRR
  locator table row `loc-leaf01 … fcbb:bbbb:3::/48 Up`. The class the trial settled on and the
  classes that did not work are recorded in the trial script's own header,
  `scripts/spike/locator-leaf01.sh` (S1–S6 sections): the FRR **file** class
  (`/etc/sonic/frr/zebra.conf`) is wiped by bgpcfgd at the next bgp container start and leaves
  the FRR locator table empty — rejected; the **GCU** CONFIG_DB `SRV6_MY_LOCATORS` class lands
  in CONFIG_DB AND lists Up in the FRR locator table (prefix stored as the address
  `fcbb:bbbb:3::`; the /48 is derived from block-len 32 + node-len 32) and survives restarts —
  accepted, and it is the class every other node then uses (T070–T072). Recipe §1a carries the
  as-built statement; `spike-locator-all` is the four-node batch receipt.
- **T070–T072 locators on the other nodes with the leaf01 class** — proofs
  `spike-locator-leaf02` / `-spine01` / `-spine02` (same body, per node): APPLIED + redis + FRR
  read-backs.
- **T073 locator reachability** — proof `spike-locator-reach`, body
  `scripts/spike/locator-reach.sh`: every node pings every other node's locator test address —
  **12 of 12 ordered pairs pass**.

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

## Verdict + documentation deliverables (T110–T124)

- **T110** `lab/profiles/sonic-vm/srv6-supported.yaml` — machine verdict file, 4 entries
  (`ip-vrf/vpn` proven, `ip-vrf/evpn` not-achievable, `mac-vrf/evpn` not-achievable,
  `steering` proven) + `honest_negatives` list; header states the refusal contract
  (`UnsupportedVariant`, never half-delivered) and the consumers
  (`scripts/lib/capability.sh`, `scripts/provision.sh`, `pkg/compat/pins.go`).
- **T111** data-model §8.1 (line 168) per-service claim profile: what a service request may claim
  per variant, keyed to the measured verdicts.
- **T112** §8.2 (line 185) locator block/format: uSID-shaped block, CLASSIC dataplane (SRH one
  segment — the `RT6 … segleft=0 [0]fcbb:bbbb:4:11::` capture line), /48 origination facts,
  reachability 12/12.
- **T113** §8.3 (line 201) device state per variant incl. the write-class column and the three
  "NOT achievable (measured)" rows.
- **T114** §8.4 (line 221) read-backs per variant (the exact commands the proofs run).
- **T115** §8.5 (line 240) rollback per variant (vpn teardown recipe + evpn3/evpn2 restore
  recipes, with the /INTERFACE guard).
- **T116** §8.6 (line 257) steering: pin commands, ECMP self-loop hazard, SLO note (SC-007 not
  met; loss classes ≤10), raw probe tables, counter conclusion.
- **T117** §8.7 (line 278) client-side requirements (addresses/routes/gateways per
  `spike-vpn-clients`).
- **T118** §8.8 (line 291) baseline prerequisites (seg6_enabled per-interface, strict_mode, vrf
  module, the `dev lo` false-negative rule).
- **T119** fabricplan contract §3 intro + **T120** §3.1 (line 44) `ip-vrf`/`vpn` per-leaf items;
  **T121** §3.2 (line 57) steering items (ingress leaf only); **T122** §3.3 (line 68) no-recipe
  variants (`ip-vrf`/`evpn`, `mac-vrf`/`evpn` — refuse-by-name mapping).
- **T123** spec KL-001..KL-003 replaced with the measured verdicts (~lines 694–721 of
  `specs/004-srv6-service-requests/spec.md`).
- **T124** `docs/SRV6_SERVICE_RECIPE.md` §6 exit-gate review: the 4-variant verdict table + the
  six-entry honest-negative register + the replay-stability statement (slice
  `proofs/p3-recipe-s6-exitgate.txt`).

## Replay receipts (T105–T109) — recorded this pass, see PROGRESS.md pass 18

Method: the stored `.out` of every group proof was refreshed FIRST (the pass-12/18 script fixes
postdate the old captures; re-recording uses each group's canonical order and self-provisioning
bodies), then each receipt records a full clean replay of its group. Receipt body:
`scripts/proof.sh replay <group>` — the receipt `.out` is the per-proof `ok` / `differ` listing
plus the `… checked, no difference` trailer; the replay re-runs every proof's recorded command
line against the live lab and byte-compares with the stored `.out` under the pass's normalizers.

- **T106** `spike-rerun-vpn` — `scripts/proof.sh replay spike-vpn`: 8 proofs in canonical order
  (state-leaf01, state-leaf02, ping, capture, readback-leaf01, readback-leaf02, clients,
  rollback — the group ends with its rollback), `RECEIPT-VPN`, exit `RECEIPT-VPN-RC`.
- **T107** `spike-rerun-evpn3` — replay of the 6 routed-EVPN proofs in recorded order
  (state-leaf01, state-leaf02, ping, capture, kl006, rollback), `RECEIPT-EVPN3`,
  exit `RECEIPT-EVPN3-RC`.
- **T108** `spike-rerun-evpn2` — replay of the 5 bridged-EVPN proofs in recorded order
  (state-leaf01, state-leaf02, ping, capture, rollback), `RECEIPT-EVPN2`, exit `RECEIPT-EVPN2-RC`.
- **T109** `spike-rerun-steering` — replay of the 5 steering proofs in recorded order
  (path, failover-launcher, failover-guest-if, failover-bgp, return), `RECEIPT-STEERING`,
  exit `RECEIPT-STEERING-RC`.
- **T105** `spike-rerun-baseline` — `scripts/spike/seed-restore.sh` first restores the EXACT
  provision seed (partial/asymmetric BGP_NEIGHBOR topology, locators/VRF/pins/vtysh-only state
  removed, kernel Vrf1 deleted, bgp restarted; every stage verified against CONFIG_DB — pass 18
  fixed three silent no-op bugs in this script, see PROGRESS.md), the dry `replay spike-baseline`
  verifies rc=0, then the receipt records the same replay: 4 proofs (spine01, spine02, leaf01,
  leaf02), `RECEIPT-BASELINE`, exit `RECEIPT-BASELINE-RC`.

## Gate-command sweep re-verified this pass (T124 exit gate)

Every gate command re-executed on the phase-3 worktree (all rc=0):

| Command | Result |
| --- | --- |
| `go build ./...` | ok |
| `go test ./...` | ok (envtest + unit suites, cached) |
| `make test-envtest` | ok (control-plane assets absent → SKIP recorded, `p2-envtest.txt` documents the same accepted state) |
| `make verify-pins` | ok — "intent_tier: 5 images all pinned by immutable digest" |
| `bash scripts/proof.sh selftest -- true` | ok — proof recorded, exit 0 |
| `bash scripts/proof.sh replay selftest` | ok — "1 proof(s) checked, no difference (0 skipped)" |
| `agents: uv run pytest tests/unit/test_phrasings_baseline.py tests/unit/test_phrasings_srv6.py tests/unit/test_vocabulary_guard.py -q` | 3 passed |
| `agents: uv run pytest -q` | 304 passed, 4 skipped, 5 deselected |
| `scripts/proofs/run-q10-baseline.sh` | rc=0 |
| `scripts/proofs/run-q10-guard.sh` | rc=0 |
| `scripts/proofs/run-q10-srv6.sh` | rc=0 |
| `scripts/proofs/run-p1-agents.sh` | rc=0 |
