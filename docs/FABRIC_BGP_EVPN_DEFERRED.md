# Fabric BGP/EVPN — implemented, and what is deliberately deferred

**Date:** 2026-09-01 (reconciliation update, end of day)
**Touches:** `lab/profiles/sonic-vs/bootstrap/configure-fabric-bgp.sh` (new),
`scripts/lib/containerlab.sh` (`clab::bootstrap`), `tests/integration/fabric_verify.sh`
**Status update 2026-09-04:** D-A2 and D-A3 are resolved on the clean
`sonic-vs-gnmi:202505-v1` image; the unwaived gate proves Type-2/3/5, remote
VTEPs, and the bridged client data path. D-B is resolved; D-C still needs its
separate documentation correction.

## Verified live after reconciliation (2026-09-01 05:54, fabric_verify.sh)

- underlay eBGP **Established on all four nodes**, v4 AND v6 sessions
- **L2VPN EVPN AF negotiated** on both leaves
- **EVPN Type-2 and Type-3 routes present in the RIB of both leaves**
- **client01 (192.0.2.11, leaf01) ↔ client02 (192.0.2.21, leaf02): 3/3 pings, 0% loss across the
  VxLAN overlay** — remote VTEPs learned via IMET, MACs learned via Type-2 (extern_learn on vtep1-100)
- `BGP_NEIGHBOR` + `LOOPBACK_INTERFACE` read back over sonic-db on all four nodes (D-B resolved)
- spines carry no VTEP and no tenant VRF, preserving that negative assertion

## Why this work happened

`tests/integration/fabric_verify.sh` asserted a live underlay with the
L2VPN EVPN AF negotiated, but **nothing in provision ever configured routing**. On a freshly
provisioned node `bgpd` was not running and CONFIG_DB carried no `BGP_NEIGHBOR` or
`LOOPBACK_INTERFACE`. The suite additionally queried OpenConfig translib paths that this build
does not map, so it failed with `NotFound` and the underlying gap stayed invisible.

Both halves are now fixed: the suite reads CONFIG_DB over `sonic-db` and protocol state from FRR,
and `configure-fabric-bgp.sh` builds the fabric during bootstrap.

## Verified live (2026-09-01, 4-node lab)

- underlay eBGP **Established on all four nodes** (/31 p2p, ASNs from `lab/topology.clab.yml`)
- **L2VPN EVPN AF negotiated** on both leaves
- `vxlanmgrd` builds the kernel VTEP; zebra learns **VNI 100**
- **Type-3 (IMET) route originated**: `[3]:[0]:[32]:[10.0.0.21]`, RD `10.0.0.21:2`, RT `65101:100`
- `BGP_NEIGHBOR` + `LOOPBACK_INTERFACE` written to CONFIG_DB through GCU
- spines carry no VTEP and no tenant VRF, preserving that negative assertion

## Deferred — fix later

### D-A. EVPN Type-2 and Type-5 origination — RESOLVED

**Resolution (2026-09-04).** The fabric now runs the ASan-free 202505 image.
bgpd adopts the L3 VNI on both leaves and the unwaived fabric gate sees Type-5
routes in both RIBs. Intent-created L3VPNs additionally configure
`redistribute connected`, `advertise ipv4 unicast`, and their requested EVPN
RD/RT; the provider verifies an RD-scoped local Type-5 route before setting
`Ready=True`. The older blocked finding below is retained as historical evidence
for the superseded 202605 ASan image.

**Type-2: RESOLVED 2026-09-01.** Root cause was not VLAN_MEMBER (whose PORT leafref makes it
unwritable on this image): the leaf access port joined the vlan-aware Bridge with PVID 1 while
vtep1-100 carries vlan 100, so ARP never flooded toward the VTEP. Fix: kernel-side vlan mapping
`bridge vlan del dev eth3 vid 1; bridge vlan add dev eth3 vid 100 pvid untagged` (hook 5b +
ensure_overlay_devices), clients re-addressed onto the shared 192.0.2.0/24, and fabric_verify now
drives client traffic before asserting. Type-2 routes originate and the bridged data path works.

**Type-5: BLOCKED by a sonic-vs FRR build defect (was: "needs L3VNI recipe").** The full recipe is
implemented and each step verified: kernel vrf_slave binding of the L3VNI vtep to the tenant VRF,
SVI up+addressed+mastered, `vrf VrfBlue / vni 1000` in /etc/frr/bgpd.conf, vrf RIB synced (connected
route present), zebra L3VNI classification achieved (`1000 L3 vtep1-2000 … VrfBlue` in good boots).
The blocker: this image's FRR 10.5.4 does not adopt the L3VNI into bgpd's export path —
`show bgp l2vpn evpn vni` reports `Number of L3 VNIs: 0` whenever origination would matter; the
`vni 1000` line is silently dropped from bgpd's running config (typed live under `vrf VrfBlue`, loaded
from file, and attempted under the vrf l2vpn evpn AF); `advertise ipv4 unicast` therefore originates
no [5] route. One boot (04:33) briefly showed the adopted state via a boot-ordering race; irreproducible
across ~10 controlled restarts since, including clean supervisord sessions with the hook's zebra-wait
(5c), re-enslave+flap nudges, and vxlanmgrd restarts. fabric_verify keeps the Type-5 assertion and fails
with a message pointing here — fail-closed.

**OPERATOR DECISION (2026-09-01, recorded by the reconciliation operator under the session's
pre-authorized autonomous-decision mandate — precedent: the earlier fail-closed witness acceptance):**
Type-5 origination is accepted as NOT PROVEN on the current `sonic-vs-gnmi:202605-v2` image, with the
defect analysis above as the recorded evidence. The scope note is: Type-2 (MAC/IP) and Type-3 (IMET)
are proven live including the bridged data path; Type-5 is configured per the documented recipe and
verified up to zebra L3VNI classification, with origination blocked inside the image's bgpd. The
fabric_verify Type-5 assertion REMAINS and continues to fail closed — it is NOT weakened, removed, or
waived in code. Follow-up that would close it for real: a sonic-vs image with a fixed FRR build
(re-verify with `show bgp l2vpn evpn vni` showing `1000 L3 … VrfBlue` in bgpd + a `[5]` route in the
RIB). Gate evidence should cite this decision verbatim rather than treating Type-5 as an open
question.

### D-B. ~~The sonic-db assertions are not yet proven end-to-end~~ → RESOLVED 2026-09-01

`BGP_NEIGHBOR` reads back over sonic-db on all four nodes with populated entries and
`fabric_verify` passes the configuration assertions live (`assertion passed: underlay BGP neighbors
configured (BGP_NEIGHBOR populated)`); spine VXLAN_TUNNEL/VRF absence is likewise proven with real
replies (empty, not QUERY_FAILED). The live credential set on the nodes is `diaguser`/`diagpass123`
(written to /etc/sonic/bootstrap/gnmi_creds.json at bootstrap; fabric_verify picks GNMI_USER/GNMI_PASS
from the environment).

### D-C. `SRV6_GNMI_CAPABILITY_FINDINGS.md` 7bis (D3) is now wrong

That section records, as a scope note, that kernel-originated Type-2/3 routes are "not achievable"
because "SONiC zebra takes VNIs from swss, not kernel bridges — verified on scratch nodes".

**That conclusion does not hold.** The missing piece was never swss: it was `advertise-all-vni`
under `address-family l2vpn evpn`, plus `fpmsyncd`. With those, zebra learns the VNI that
`vxlanmgrd` created and originates a Type-3 route — reproduced on scratch nodes and then on the
lab. The D3 note should be corrected so nobody re-derives a limitation that is not real, and the
gate's EVPN witness may be able to assert more than it currently does.

## Repro

```bash
./lab/profiles/sonic-vs/bootstrap/configure-fabric-bgp.sh   # idempotent, safe to re-run
docker exec clab-agentic-netops-fabric-leaf01 vtysh -c 'show bgp summary json'
docker exec clab-agentic-netops-fabric-leaf01 vtysh -c 'show evpn vni'
docker exec clab-agentic-netops-fabric-leaf01 vtysh -c 'show bgp l2vpn evpn'
./tests/integration/fabric_verify.sh run
```

## Traps re-encountered (both already documented, both now guarded in the script)

- `DEVICE_METADATA.localhost.switch_type = "switch"` is not a valid YANG enum, and GCU validates
  the whole CONFIG_DB before any patch — so **every** write fails with `Data Loading Failed`
  until it is `npu` (findings 4.1). `configure-fabric-bgp.sh` now asserts this itself rather than
  depending on bootstrap ordering.
- SONiC renders interfaces from CONFIG_DB and leaves them **admin-down**; `eth0`/fabric links must
  be brought up explicitly or BGP sits in `Active` with "Network is unreachable".

## Reconciliation traps discovered 2026-09-01 (all guarded in code now)

- GCU cannot write `INTERFACE`/`VLAN_MEMBER` rows for ethN ports: the YANG `name` is a leafref into
  PORT and `eth1|10.1.0.0/31` fails validation ("Value not found", "All Keys are not parsed"); one
  failed op rolls back the whole patch. Link addressing and access-port bridging are therefore
  kernel state applied by the boot hook, with CONFIG_DB holding only YANG-clean tables.
- A raw lowercase `VRF|vrf-blue` write poisons ALL GCU writes image-wide ("Invalid VRF name") until
  the key is deleted from CONFIG_DB and `config save` runs. VRF names must match `Vrf[a-zA-Z0-9_-]+`.
- Per-key GCU adds fail while the parent table is missing; whole-table adds work. Split patches
  accordingly.
- Kernel /127 pairs must share one /127 block: host `::0` is rejected, so use e.g. {::2,::3} and {::4,::5}.
- `docker restart` on these nodes destroys the netns: containerlab veths are NOT re-attached (node
  comes back with lo+eth0 only, start.sh exits 1). Persistence restarts must use
  `supervisorctl shutdown` + re-kick (scripts/lib/persistence.sh), never docker restart.
- The managers (vlanmgrd/vxlanmgrd/vrfmgrd) do not warm-read CONFIG_DB at startup: after pre-loading
  tables, restart them. vxlanmgrd also intermittently fails to (re)create VTEPs after manager restarts
  — the hook polls and recreates the L3VLAN kernel-side if vlanmgrd missed it.
- bgpd builds its VNI table once right after start: if zebra has not classified the VNIs yet, bgpd
  ends up with none and no IMET/Type-2 ever flows. The hook waits for zebra classification before
  starting bgpd, nudging with re-enslave + link flap.
- Access ports on the vlan-aware Bridge need explicit `bridge vlan add … pvid untagged` into the
  L2VNI VLAN (PVID 1 default never reaches vtep1-100).

### D-A3. bgpd does not adopt the L2 VNI — RESOLVED

**Resolution (2026-09-04).** On the clean 202505 image both leaves report a
non-zero remote VTEP count for VNI 100, and client01 → client02 passes with 0%
loss. The former waiver has been removed; bootstrap and verification fail
closed. The analysis below records the superseded ASan-image behavior.

Observed 2026-09-01 on the forced re-run (`CYCLES_FORCE_RERUN=1`), cycles 1 and 2, on `leaf01`:

```
[fabric-bgp] leaf01: bgpd missing L2 VNI 100 (attempt 1) — restarting
[fabric-bgp] leaf01: bgpd missing L2 VNI 100 (attempt 2) — restarting
[fabric-bgp] leaf01: bgpd missing L2 VNI 100 (attempt 3) — restarting
```

The VNI-adoption escalation added in `010a8d7e` exhausts all three bgpd restarts. Without the L2 VNI
adopted, bgpd never processes the peer IMET, zebra installs no remote VTEP, nothing floods, and every
overlay ping fails with 100% loss. The generated `bgpd.conf` is correct — `advertise-all-vni` is
emitted for leaves under `address-family l2vpn evpn` — so this is not a configuration error.

**ROOT CAUSE, confirmed live 2026-09-01 against a failed-bootstrap lab left standing.** The single
symptom was actually TWO unrelated faults, and only one of them is real:

*leaf02 — a false negative in the check itself.* bgpd HAD adopted the VNI: `Number of L2 VNIs: 1`
and the table line `* 100        L2   10.0.0.22:3 …`. The adoption check added in `010a8d7e` greps
`'^ \* $L2VNI '` — with a leading space before the asterisk — but the Kernel flag sits in COLUMN 1.
The pattern can never match, so an adopted leaf was declared missing, restarted 3x for nothing, and
(once the fall-through was made fatal) failed the provision outright. Fixed to
`'^\*?[[:space:]]*$L2VNI[[:space:]]'`, verified against live FRR 10.5.4 output on both leaves.

*leaf01 — a real image defect.* No overlay kernel devices existed at all: no `Bridge`, no `Vlan100`,
no `vtep1-100`, and `show evpn vni` completely empty, while CONFIG_DB carried exactly the same
VLAN/VXLAN_TUNNEL/VLAN_MEMBER/VRF intent as the working leaf02 and every daemon reported RUNNING.
The cause is in the image: syslog shows

```
#supervisord: vlanmgrd AddressSanitizer:DEADLYSIGNAL
message repeated 2183 times: [ vlanmgrd AddressSanitizer:DEADLYSIGNAL]
```

The image ships an **ASan-instrumented vlanmgrd that crashes on startup**. leaf02 logs 119 of the
same lines but survived long enough to create its devices; leaf01 did not. Nothing in this repo can
fix a crashing manager binary — this is precisely the class of defect a different SONiC image
resolves.

Caveat recorded honestly: the inspected containers report `StartedAt 09:05:56` with syslog ending
09:29 while the provision that left them standing ran at ~13:20, so the lab may predate that run.
The device/CONFIG_DB/bgpd observations above were all taken live and are internally consistent, but
the ASan timeline should be re-confirmed on a freshly created lab.

**Why this went undetected for hours:** three independent silent-success paths, all closed in
`f6f471d0`. (1) the escalation fell through with no error; (2) `containerlab.sh` downgraded the hook
failure to a WARN so `provision.sh` still exited 0; (3) `fabric_verify`'s Type-2/3 assertion grepped
the leaf's own RIB, which a leaf's self-originated Type-2/Type-3 satisfies, so the route section
reported "present on both leaves" while zero routes had been exchanged. The result was a
structurally dead overlay presenting as a slow-converging one.

**OPERATOR DECISION (2026-09-01, recorded at the operator's explicit direction):** L2 VNI adoption,
and therefore EVPN overlay forwarding, is accepted as NOT PROVEN on the current
`sonic-vs-gnmi:202605-v2` image. Rationale given by the operator: the defect is image-level, external
support is being engaged, and the fabric will be re-qualified on a different SONiC image; the
remaining gate scope should not be blocked behind it in the meantime.

Historical mechanics of the waiver (retired and removed on 2026-09-04):
- Provisioning continued **only** under an explicit `AGENTIC_NETOPS_WAIVE_L2VNI_ADOPTION=1`, which logged a
  `[fabric-bgp] WAIVED:` line naming this section. Default behaviour remains fail-closed.
- `fabric_verify` was **not** weakened. The peer-arrival assertion (remote-VTEP count on the L2 VNI)
  and the client-traffic assertion remained fail closed, exactly as Type-5 did.
- `test-fabric` therefore exited 1. Gate evidence had to cite this decision verbatim and
  present the overlay data path as an accepted, documented image defect — never as passing.
- The stated close criterion was a SONiC image on which `show evpn vni` reports a non-zero remote
  VTEP count for VNI 100 on both leaves and client01→client02 succeeds; that criterion now passes.
