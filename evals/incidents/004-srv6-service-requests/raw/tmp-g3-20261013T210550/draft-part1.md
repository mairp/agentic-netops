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
  daemon cmdlines; timer-shaped fields normalized per FR-039). Recorded on the T104 fresh lab
  BEFORE any spike change (seed = the partial qualify-seeded underlay; see
  `proofs/p3-baseline-fresh.txt`).
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
