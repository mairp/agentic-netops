# Can a different SONiC image fix D-A2 and D-A3?

**Date:** 2026-09-04
**Question:** `docs/FABRIC_BGP_EVPN_DEFERRED.md` accepts EVPN Type-5 origination
(D-A2) and L2 VNI adoption (D-A3) as NOT PROVEN on
`sonic-vs-gnmi:202605-v2`, and says both close only on "a different SONiC
image". Is that true, which image, and what has to be redeployed?

**Answer:** Yes — and the diagnosis in D-A3 is incomplete in a way that makes
the fix much cheaper than the doc implies. The lab is not running a defective
SONiC build. **It is running an AddressSanitizer build**, which upstream
publishes as an explicitly optional debug variant. A clean build of the same
lineage is already sitting on this host.

## Resolution update — completed 2026-09-04

The swap proposed below has now been completed. The fabric is pinned to
`localhost:5000/sonic-vs-gnmi:202505-v1@sha256:d1043aed28c98071c997a46d7e9e47823abacb06c31c068183541f8b5b5529e8`.

- `vlanmgrd`, `vxlanmgrd`, `vrfmgrd`, and `orchagent` are ASan-free and running
  on both leaves; both syslogs contain zero `AddressSanitizer` entries.
- D-A3 close criteria pass: each leaf reports one remote VTEP for VNI 100 and
  client01 → client02 succeeds with 0% packet loss.
- D-A2 close criteria pass without a waiver: bgpd adopts L3 VNIs and both
  leaves carry Type-5 routes. The full unwaived `fabric_verify.sh run` passed.
- The follow-up for intent-created L3VPNs is also closed: `pkg/fabricplan`
  enables `redistribute connected` and `advertise ipv4 unicast`, applies the
  requested RD/RT in the EVPN AF, and verifies the service-scoped local Type-5
  route before allowing `Ready=True`.
- `Network/migr-6cf2d23d9991475` now has `Ready=True/ApplySucceeded` and
  `Degraded=False/NoFailuresObserved`; VNI 10018 is adopted on both leaves and
  both self-originate `10.0.0.0/24` with RD/RT `65000:18`.

The remainder of this document is the pre-swap diagnosis and execution plan,
retained as the investigation record.

---

## 1. The finding: the image is an ASan build

Every SONiC state-management daemon on the running lab is linked against
`libasan`:

```
$ docker exec clab-agentic-netops-fabric-leaf01 sh -c \
    'for b in vlanmgrd vxlanmgrd vrfmgrd orchagent portsyncd intfmgrd \
              neighsyncd fpmsyncd teammgrd buffermgrd nbrmgrd; do
       ldd $(which $b) | grep -q asan && echo "ASAN  $b" || echo "clean $b"; done'
ASAN  vlanmgrd
ASAN  vxlanmgrd
ASAN  vrfmgrd
ASAN  orchagent      <-- the central SONiC daemon
ASAN  portsyncd
ASAN  intfmgrd
ASAN  neighsyncd
ASAN  fpmsyncd
ASAN  teammgrd
ASAN  buffermgrd
ASAN  nbrmgrd
```

Direct confirmation on `vlanmgrd`:

```
libasan.so.8 => /lib/x86_64-linux-gnu/libasan.so.8
```

The crashes are live on the current lab, not historical — which closes the
caveat D-A3 left open ("the ASan timeline should be re-confirmed on a freshly
created lab"):

```
$ grep -c AddressSanitizer /var/log/syslog
3401
Sep  3 20:26:56 leaf01 INFO #supervisord: orchagent AddressSanitizer:DEADLYSIGNAL
Sep  3 20:26:56 leaf01 INFO #supervisord: message repeated 176 times: [...]
```

FRR is **not** ASan-instrumented (`/usr/lib/frr/bgpd`, `zebra` — both clean).

### Why this matters

ASan is not how SONiC ships. Upstream's `docker-sonic-vs` pipeline
([sonic-sairedis `build-docker-sonic-vs-template.yml`](https://github.com/sonic-net/sonic-sairedis/blob/master/.azure-pipelines/build-docker-sonic-vs-template.yml))
declares it optional and off by default:

```yaml
- name: asan
  type: boolean
  default: false
```

and encodes the choice in the artifact name:

```
docker-sonic-vs:$(Build.DefinitionName).$(Build.BuildNumber).asan-${{ parameters.asan }}
```

`ENABLE_ASAN` is likewise a build-variant parameter in `sonic-buildimage`
([Dockerfile.j2](https://github.com/sonic-net/sonic-buildimage/blob/master/platform/vs/docker-sonic-vs/Dockerfile.j2)).

**So this is not an image defect. It is the wrong build variant** — an
`asan-True` artifact picked up as if it were the standard one. A memory-error
detector deliberately aborts the process on the first fault
(`DEADLYSIGNAL`); a daemon set built this way is expected to die under load.
D-A3's conclusion — "Nothing in this repo can fix a crashing manager binary"
— is correct, but the remedy is a build flag, not vendor support.

## 2. D-A2 is probably a symptom of D-A3, not a second defect

The deferral doc treats these as independent, and says Type-5 needs "a sonic-vs
image with a fixed FRR build". The evidence does not support a broken FRR:

- `bgpd` and `zebra` are clean binaries (no ASan).
- The L3VNI path depends on kernel devices that `vxlanmgrd`, `vrfmgrd` and
  `vlanmgrd` create — **all three are ASan and crashing**.
- zebra classifies L3VNIs from those devices; bgpd builds its VNI table once,
  shortly after start, from zebra's classification. The doc already records
  this ordering ("bgpd builds its VNI table once right after start: if zebra
  has not classified the VNIs yet, bgpd ends up with none").
- The doc also records that **one boot briefly showed the adopted state**, via
  a boot-ordering race, irreproducible across ~10 restarts. A race that
  occasionally wins is the signature of a timing-dependent dependency, not of
  a build that structurally cannot express the feature.

A crashing `vxlanmgrd`/`vrfmgrd` explains an empty/late zebra classification,
which explains `Number of L3 VNIs: 0`, which explains no `[5]` route — without
requiring an FRR bug at all.

This is a hypothesis, not a proven claim. It is falsifiable by the test in §5.

## 3. Pre-swap state of the fabric (measured 2026-09-04)

| Check | Result |
|---|---|
| `show bgp l2vpn evpn vni` (L3) | `Number of L3 VNIs: 0` — D-A2 signature, verbatim |
| `show evpn vni 100` remote VTEPs | empty on **both** leaves — D-A3 waived state |
| MACs known for VNI 100 | 0 on both leaves |
| VRF in FRR | present (`Vrf-6cf2d23d99 id 28 table 1010`) |
| VRF + L3VNI in CONFIG_DB | present on both leaves (`{'vni': '10018'}`) |

The intent tier's own claims are accurate at their stated scope: config is
written and read back on every node. Nothing forwards.

## 4. The candidate image — already on this host

`/root/sonic-images/docker-sonic-vs-202505.gz` (228 MB, community artifact):

```
branch:       '202505'
build_number: 1207609
build_date:   Mon Aug 31 2026

vlanmgrd  clean        vxlanmgrd clean        vrfmgrd   clean
orchagent clean        portsyncd clean        intfmgrd  clean

/usr/sbin/telemetry:  ABSENT
bgpd version:         10.3
```

**Clean of ASan across the board.** Two deltas to weigh:

- **No gNMI server.** Expected, and already documented in
  `lab/images/sonic-vs-gnmi/README.md`: upstream ships gNMI as a separate
  `docker-sonic-telemetry` container, so the community `vs` artifact has no
  `/usr/sbin/telemetry`. This is exactly why the `sonic-vs-gnmi` layer exists.
  The tier needs it: the provider's device ops are `gcu` / `redis` / `shell`,
  and GCU rides the gNMI write path.
- **FRR 10.3 vs 10.5.4.** A downgrade. If §2 is right this is irrelevant; if
  the FRR-bug theory is right instead, 10.3 may behave differently in either
  direction. Unknown until tested.

For comparison, the current base — `/root/docker-sonic-vs-202605-1205344.gz`,
build 1205344, matching the running `build_number` — is the ASan artifact.

## 5. Validate before committing to the rebuild

The gNMI re-layer is the expensive step (§6), and it is wasted if a clean base
does not actually fix anything. Test the base **first**, standalone — it costs
one container and no changes to the lab:

```bash
docker run -d --rm --privileged --name asan-test docker-sonic-vs:latest
sleep 90

# 1. Do the managers stay up?
docker exec asan-test supervisorctl status | grep -E "vlanmgrd|vxlanmgrd|vrfmgrd|orchagent"
docker exec asan-test grep -c AddressSanitizer /var/log/syslog   # expect 0

# 2. Does zebra classify an L3VNI, and does bgpd adopt it?
#    (apply the documented L3VNI recipe from FABRIC_BGP_EVPN_DEFERRED.md D-A2)
docker exec asan-test vtysh -c "show evpn vni"
docker exec asan-test vtysh -c "show bgp l2vpn evpn vni"   # want: L3 VNIs != 0
```

- Managers stable + L3VNI adopted → **§2 confirmed**, both deferrals close on a
  clean build, proceed to §6.
- Managers stable + still `L3 VNIs: 0` → D-A3 closes, D-A2 is a genuine FRR
  issue after all; the deferral doc stands for Type-5 and the next lever is an
  FRR version, not a SONiC one.
- Managers still crashing → the artifact is not what it appears; stop and
  re-source.

Note this single-container test cannot prove the *overlay data path* (that
needs two leaves and clients). It proves the daemon-stability and
VNI-adoption preconditions, which is what both deferrals turn on.

## 6. What a full swap requires

Ordered, with the honest cost of each.

### 6.1 Rebuild the gNMI layer on the clean base — the real work

> **Resolution update:** the implementation did not relink telemetry against
> 202505. It copied the already-qualified telemetry binary, schema, and exact
> 202605 shared-library closure into `/opt/agentic-netops/telemetry/lib`, then
> applied that `LD_LIBRARY_PATH` only to telemetry. This keeps the clean base's
> manager daemons untouched. The reproducible assembly driver is now tracked at
> `lab/images/sonic-vs-gnmi/build-compat.sh`; the speculative recompile plan in
> this subsection is retained for history.

The layer cannot be re-tagged onto a new base: `build4.sh` compiles the
telemetry binary **against the base image's own libraries**
(`libswsscommon`, `libyang`, `hiredis`, boost), by design — "the binary is
linked against the runtime it will execute in". A 202505 base ships different
library versions, so this is a genuine recompile.

Everything needed is present:

| Input | Location |
|---|---|
| driver script | `.wiggum/features/001-agentic-netops-sonic-evpn-fabric/build-gnmi/build4.sh` |
| sources | `/root/build-sonic-telemetry/{sonic-telemetry,sonic-mgmt-common}` |
| staged libs | `.wiggum/.../build-gnmi/libs/` |
| layer Dockerfiles | `lab/images/sonic-vs-gnmi/Dockerfile`, `Dockerfile.v2` |
| clean base | `/root/sonic-images/docker-sonic-vs-202505.gz` |

Change `PINNED`/`BASE` in `build4.sh` to the new base digest and re-run. Budget
real time: build4.sh's header documents four cgo blockers that had to be solved
(`pam_appl.h`, `libyang.h`, ygot-generated `ocbinds`, `cfg_schema.h`), each
resolved against the *202605* runtime. A different base can reopen any of them.

Then re-apply `Dockerfile.v2` (dbus + `sonic-host-server` supervisord programs
— required for `org.SONiC.HostService.gcu`, i.e. the GCU write path).

> **Historical risk (closed):** `.wiggum/` was **untracked** (`git ls-files` returned
> nothing for it). The only copy of the build driver for the lab's most
> load-bearing image was not in version control. The supported compatibility
> assembly is now tracked alongside `Dockerfile.compat`, and its smoke build
> has been verified. The older experimental source-build scripts remain ignored
> investigation artifacts, not the supported rebuild path.

### 6.2 Push and re-pin

```bash
docker push localhost:5000/sonic-vs-gnmi:202505-v1
docker inspect --format '{{index .RepoDigests 0}}' localhost:5000/sonic-vs-gnmi:202505-v1
```

Update the digest in **all four** places that carry it:

- `versions.lock.yaml` → `sonic_images.sonic_vs` (image, digest, tag, notes)
- `versions.lock.yaml` line ~159 (the second occurrence in the pin list)
- `lab/topology.clab.yml` (line 19)
- `lab/profiles/sonic-vs/profile.yaml` (line 4)

Also refresh `sonic_images.sonic_vs_base` — its metadata is currently
inconsistent (`tag: 20220111`, notes describing the January-2022 netreplica
build, while the running device reports `branch: 202605`, build 1205344,
2026-08-28). Whatever else happens, that entry misdescribes reality today.

`make verify-pins` / `verify-intent-pins` gate on these; run them after editing.

### 6.3 Rebuild and redeploy the fabric

The image change only affects the containerlab fabric, not the Kubernetes
control plane. **The intent tier does not need rebuilding** — supervisor,
mapper, allocator, deployer and UI are image-independent.

```bash
make off CLUSTER=agentic-netops          # scripts/off.sh
make provision PROF=sonic-vs CLUSTER=agentic-netops
```

`provision.sh` re-runs preflight → pins → CRDs → Kind → intent tier
(`intent::install`) → `containerlab.sh bootstrap` → capability gate
(`qualify.sh`). Both the gate and `configure-fabric-bgp.sh` run against the new
image.

Existing `Network` objects in `agentic-netops-intent` are re-reconciled against
a fresh fabric — expect the controller to re-apply and the Ready conditions to
re-transition. The 14 Networks currently in the namespace are test residue;
consider pruning first.

### 6.4 Re-qualify, and only then relax the waivers

```bash
./tests/integration/fabric_verify.sh run
make lab-qualify
```

Both keep their Type-5 and peer-arrival assertions failing closed by design.
`AGENTIC_NETOPS_WAIVE_L2VNI_ADOPTION=1` was **removed** after `fabric_verify`
passed unwaived. The deferral doc's
own close criteria are the bar:

- D-A3: non-zero remote VTEP count for VNI 100 on both leaves, and
  client01 → client02 pings across the overlay succeed.
- D-A2: `show bgp l2vpn evpn vni` shows the L3 VNI against the tenant VRF in
  bgpd, plus a `[5]` route in the RIB.

Then update `FABRIC_BGP_EVPN_DEFERRED.md`: the operator decisions of 2026-09-01
were recorded against a specific image and should be closed with evidence, not
silently dropped.

### 6.5 Fallback if the 202505 artifact does not work out

- Other community branches (202411, 202511) from the same source — cheapest
  next try, same procedure.
- Build from source: `scripts/build-sonic-vs.sh` already exists, clones
  `sonic-buildimage` (`BRANCH`, default `202405`) and builds
  `target/docker-sonic-vs.gz` with no ASan flags. Slow (hours) but fully
  controlled, and it removes the dependency on someone else's artifact naming.
- `sonic_vm` (vrnetlab, full VM) is already contemplated in `versions.lock.yaml`
  as the fallback "when sonic_vs fails the capability gate". Heavier — needs
  KVM — but it sidesteps the vs-image daemon problems entirely.

Disk is not a constraint: 1.4 TB available.

## 7. Bottom line

- The lab runs an **ASan debug build**; that is the whole of D-A3 and very
  likely most of D-A2. This is a wrong-artifact problem, not a vendor problem.
- A **clean 202505 artifact is already on this host** and is ASan-free.
- The blocking work is **recompiling the gNMI telemetry layer** against the new
  base, because the community `vs` image ships no gNMI server.
- **Test the clean base standalone first (§5).** It is one container, and it
  decides whether the rebuild is worth starting and whether D-A2 is real.
- **Back up `.wiggum/build-gnmi/` into git today**, independently of any of
  this.

## Sources

- [sonic-sairedis `build-docker-sonic-vs-template.yml`](https://github.com/sonic-net/sonic-sairedis/blob/master/.azure-pipelines/build-docker-sonic-vs-template.yml) — asan defaults false; artifact name encodes `asan-<bool>`
- [sonic-buildimage `platform/vs/docker-sonic-vs/Dockerfile.j2`](https://github.com/sonic-net/sonic-buildimage/blob/master/platform/vs/docker-sonic-vs/Dockerfile.j2) — `ENABLE_ASAN` build variant
- [SONiC Image Azure Pipelines](https://sonic-build.azurewebsites.net/ui/sonic/pipelines) — artifact source
- [containerlab — SONiC (container) kind](https://containerlab.dev/manual/kinds/sonic-vs/)
- `docs/FABRIC_BGP_EVPN_DEFERRED.md` — D-A2 / D-A3 operator decisions, close criteria
- `lab/images/sonic-vs-gnmi/README.md` — why the gNMI layer exists
