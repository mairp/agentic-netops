# SRv6 + gNMI capability findings

**Feature:** `001-ainetops-sonic-evpn-fabric`, phase 8 (SC-013 and related SRv6 conformance)
**Date:** 2026-08-31
**Status:** gNMI read path **working and verified**; gNMI write path **blocked at one specific
layer**; four SRv6 criteria are **untestable as currently written** because the tables they query
do not exist in SONiC's schema.

Every claim below was executed against a live node running the pinned image. Commands are in
[Appendix A](#appendix-a--reproduction) so any statement here can be re-checked rather than trusted.

---

## 1. Summary

| Capability | State | Evidence |
|---|---|---|
| gNMI server present and serving | **works** | `supervisorctl status telemetry` RUNNING, listening `:8080` |
| gNMI Capabilities | **works** | gNMI 0.7.0; OpenConfig acl/lldp/platform/system + `sonic-db` |
| gNMI Get (`sonic-db` origin) | **works** | `DEVICE_METADATA`, `TELEMETRY`, `SRV6_MY_LOCATORS`, `SRV6_MY_SIDS` all served |
| SRv6 config readable over gNMI | **works** | wrote a `uN` SID, read it back over gNMI with `action: uN` |
| SRv6 YANG model on box | **present** | `/usr/local/yang-models/sonic-srv6.yang` (144 models total) |
| gNMI Set | **blocked** | reaches GCU, then `Failed to apply patch on the following scopes:` |
| Config write via GCU directly | **works** | `config apply-patch` applied an SRv6 locator and a SID, twice |
| OpenConfig translib Get | **unavailable** | `No entry found in xYangSpecMap for URI - /openconfig-interfaces:interfaces` |
| translib path form `/sonic-srv6:sonic-srv6/...` | **unavailable** | `Node sonic-srv6:sonic-srv6 not found` |
| EVPN Type2/3/5 over OpenConfig | **unavailable** | same xYangSpecMap miss (network-instance paths) |

---

## 2. The image

Pinned in `versions.lock.yaml` as `sonic_images.sonic_vs`:

```
localhost:5000/sonic-vs-gnmi:202605@sha256:c04b9edd49bb0037ac9d01fde8715d4c37eb45d7a68710ba9d64ac27b1870768
```

| Component | Source |
|---|---|
| base | `localhost:5000/sonic-vs:202605@sha256:097d1551…` (netreplica/docker-sonic-vs:20220111), kept as `sonic_vs_base` |
| telemetry (gNMI server) | built from `github.com/sonic-net/sonic-gnmi` @ `dd99be1`, linked against the base image's own libswsscommon/libnl/libyang |
| recipe | `lab/images/sonic-vs-gnmi/` (Dockerfile, telemetry.sh, telemetry.conf, README) |

### Why not the previously pinned image, and why not upstream

- **The old pin** (`sonic_vs_base`, frozen since 2022-01) ships **no gNMI server at all**. The
  capability gate failing closed against it was correct behaviour, not a misconfiguration — SC-013
  was simply unprovable with it.
- **Upstream community `docker-sonic-vs`** (sonic.software, branches 202405/202411/202505/202511) does
  **not** close the gap either. Downloaded and audited the 202505 build (build 1207609):
  `sonic-srv6.yang` present, but `/usr/sbin/telemetry` **absent** and zero `program:telemetry`
  entries — upstream ships gNMI as a separate `docker-sonic-telemetry` container, which the
  single-container artifact does not include.

So the pinned image is the only variant on this host that can serve gNMI at all.

---

## 3. What works, precisely

Against a node running the pinned image (`admin`/`admin`, TLS with `--skip-verify` in ad-hoc probes;
the lab bootstrap installs real certs):

- **Capabilities** → gNMI 0.7.0, models: `openconfig-acl`, `openconfig-lldp`,
  `openconfig-platform`, `openconfig-system`, `ietf-yang-library`, `sonic-db`.
- **Get on the `sonic-db` origin** → serves CONFIG_DB tables, both forms:
  `--path /SRV6_MY_SIDS --target CONFIG_DB` and `--path sonic-db:/CONFIG_DB/SRV6_MY_SIDS`.
- **SRv6 round trip** → a locator (`loc1`, `fc00:0:1::`) and a SID
  (`loc1|fc00:0:1:1::/64`, `action: uN`) written through GCU are **read back over gNMI** with their
  values intact. This is the strongest single piece of evidence that the SRv6 data path over gNMI is
  real on this image.
- **FRR** → 10.5.4 with SRv6 support (`show segment-routing srv6 locator` answers).

---

## 4. What is blocked, and exactly where

### 4.1 gNMI Set — the one open item

`Set` gets all the way to SONiC's generic config updater and then fails:

```
rpc error: code = Unknown desc = Error: Failed to apply patch on the following scopes:
```

The scope list in that message is **empty**. The identical patch applied directly through
`config apply-patch -f CONFIGDB` **succeeds**, so this is the gNMI→GCU bridge in this sonic-gnmi
build, not the config layer, not the schema, and not the patch. It fails for keys with a `/`
(SRv6 SIDs, which always carry a prefix) *and* for keys without one (a locator), so it is not a
path-escaping problem either.

Reaching that point required fixing three prerequisites, all of which are real gaps in the current
lab, each verified by the error disappearing:

1. **`dbus-daemon` is installed but never started.** Without it: `dial unix
   /var/run/dbus/system_bus_socket: connect: no such file or directory`. Needs a supervisord program
   (or a bootstrap step).
2. **`sonic-host-server` and `host_modules/` are absent from the base image.** Without them:
   `The name org.SONiC.HostService.gcu was not provided by any .service files`. The upstream 202505
   image carries both, and they drop into our image cleanly — our image is Python 3.11.2 with the
   same `dist-packages` path, and `dbus`, `sonic_py_common` and `swsscommon` all import.
3. **`DEVICE_METADATA.localhost.switch_type` is `"switch"`, which is not a valid enum value**
   (`chassis-packet|fabric|npu|voq|dpu|dummy-sup`). GCU validates the *entire* CONFIG_DB before
   applying any patch, so while this is wrong **every** write fails with `Data Loading Failed`,
   whatever the patch contains. Setting it to `npu` makes the base config validate.

Items 1 and 2 are image changes; item 3 is a bootstrap/config change.

### 4.2 OpenConfig translib surface is advertised but not mapped

`Capabilities` lists OpenConfig models, but `Get /openconfig-interfaces:interfaces` returns
`No entry found in xYangSpecMap for URI`, and `/sonic-srv6:sonic-srv6/...` returns
`Node sonic-srv6:sonic-srv6 not found`. On this build, SONiC data is reachable through the
**`sonic-db` origin only**. Any test written against translib/OpenConfig path forms will fail
regardless of how the fabric is configured.

---

## 5. The trap: tests that cannot fail

**This is the most important finding in this document.**

On the `sonic-db` origin, a Get against a table that does not exist returns an empty body and
**exit code 0**:

```
$ gnmic ... get --path /TOTALLY_FAKE_TABLE --target CONFIG_DB
"TOTALLY_FAKE_TABLE": {}      # rc=0
```

`tests/integration/sonic_gnmi_suite.sh` and `evpn_srv6_suite.sh` decide pass/fail purely on gnmic's
exit code. So **converting the path forms alone would produce a suite that always passes** — ten
green capability tests that assert nothing, indistinguishable from a node with no SRv6 support at
all. That is the same class of evidence the critic has been rejecting since 2026-08-29 ("cited
evidence files absent"/unfalsifiable claims), so a mechanical conversion would make phase 8 *look*
solved while proving less than it does today.

Any conversion must therefore add **content assertions**, not just new paths.

### 5.1 Set is the exception, and that makes it valuable

Unlike Get, `Set` is YANG-validated: writing to `AINETOPS_PROBE` is rejected with
`Data Loading Failed`, while a schema-valid SRv6 write is accepted. A write→read-back→delete cycle is
therefore the one gNMI operation that **cannot** pass vacuously, which is why the Set decision in §7
matters more than it looks.

---

## 6. Schema reality vs. the current tests

SONiC 202605 models exactly two SRv6 tables (`/usr/local/yang-models/sonic-srv6.yang`):

| Table | Key | Fields |
|---|---|---|
| `SRV6_MY_LOCATORS` | `locator_name` | `prefix` (ipv6-address), `block_len` (32), `node_len` (16), `func_len` (16), `arg_len` (0), `vrf` |
| `SRV6_MY_SIDS` | `locator ip_prefix` | `action` enum **`uN` \| `uDT46`**, `decap_vrf`, `decap_dscp_mode` enum `uniform\|pipe` |

Note `ip_prefix` is an ipv6-**prefix**: `fc00:0:1:1::/64` validates, a bare address does not.

What the suites currently query:

| Test | Path queried | Exists? |
|---|---|---|
| `sonic-srv6` (gate) | `/sonic-srv6:sonic-srv6/SRV6_GLOBAL/SRV6_GLOBAL_LIST[name=default]` | **no** — no `SRV6_GLOBAL` table, and the translib form does not resolve |
| `SRv6-Underlay` | `SRV6_GLOBAL` | **no** |
| `H.Encaps.Red` | `SRV6_POLICY` | **no** |
| `End` | `SRV6_LOCATOR` | **no** (real name is `SRV6_MY_LOCATORS`) |
| `End.DT46` | `SRV6_END_DT46` | **no** (it is an `action` value, not a table) |
| `SID-list` | `SRV6_SID_LIST` | **no** |
| `Decapsulation` | `SRV6_DECAPSULATION` | **no** (it is `decap_vrf`/`decap_dscp_mode` on a SID) |
| `Counters` | `SRV6_COUNTERS` | **no** (counters live in COUNTERS_DB; the binary does carry `COUNTERS_SRV6_NAME_MAP`) |
| `Get` | `/openconfig-interfaces:interfaces` | path form unavailable on this build |
| `EVPN-Type2/3/5` | `/openconfig-network-instance:network-instances/...` | path form unavailable on this build |

Every one of these currently passes vacuously.

---

## 7. Pending decisions

These are choices about what the gate should assert, not debugging tasks. Recommendations are mine;
the decision is the operator's because two of them touch what FR-003 / SC-013 mean.

### D1 — What should the gate's `Set` test assert? *(recommend: option B)*

| | Option | Cost | Claim it supports |
|---|---|---|---|
| A | Bake image v2 (dbus + host service), then keep debugging the gNMI→GCU scope error until Set works over gNMI | open-ended debug | full gNMI Set conformance |
| **B** | **Bake image v2, and have the gate assert the write path that provably works: write an SRv6 SID via GCU, read it back over gNMI, delete it** | bounded — image v2 is ~1 build cycle | "config is programmable and observable over gNMI", with the gNMI-Set limit recorded honestly |
| C | Drop Set from the gate entirely | none | weakest; loses the only non-vacuous check available |

Option B keeps a falsifiable write→read-back assertion while leaving the bridge bug documented
rather than blocking the phase on it. Image v2 is needed for A and B alike.

### D2 — The four SRv6 tables that do not exist *(recommend: re-express)*

Re-express each behaviour against a witness that exists:

| Criterion | Proposed witness |
|---|---|
| End | `SRV6_MY_SIDS` entry with `action: uN` (gNMI) |
| End.DT46 | `SRV6_MY_SIDS` entry with `action: uDT46` + `decap_vrf` (gNMI) |
| SRv6 underlay | `SRV6_MY_LOCATORS` entry with expected `prefix`/`block_len`/`node_len` (gNMI) |
| H.Encaps.Red | FRR: `vtysh -c "show segment-routing srv6 locator"` / policy state |
| Ordered SID-list steering | FRR: segment-list / policy output (BGP/pathd programmed, not a CONFIG_DB table) |
| Counters | `COUNTERS_DB` (`COUNTERS_SRV6_NAME_MAP`) over gNMI |

This changes what FR-003 asserts — from "these table paths answer" to "these behaviours are
present and observable" — which is a stronger claim, but it is a spec-level edit and needs your
sign-off.

### D3 — EVPN Type2/3/5 *(recommend: FRR witness)*

OpenConfig network-instance paths are unavailable on this build. Options: assert route types via
FRR `show bgp l2vpn evpn` through `docker exec` (idiomatic here — `fabric_verify.sh` and
`mtu_ecmp.sh` already reach nodes this way), assert EVPN/VXLAN configuration tables over gNMI
(proves configuration, not route exchange), or record the criteria as unsupported on this image.

### D4 — Image v2 contents (needed for D1-A and D1-B)

```
lab/images/sonic-vs-gnmi/Dockerfile   (v2)
  + /usr/local/bin/sonic-host-server            from upstream docker-sonic-vs 202505
  + /usr/local/lib/python3.11/dist-packages/host_modules/
  + [program:dbus]         supervisord
  + [program:host-server]  supervisord
lab/profiles/sonic-vs/bootstrap/
  + DEVICE_METADATA.localhost.switch_type = npu   (currently "switch" -> every GCU write fails)
```

Then re-pin the new digest in `versions.lock.yaml` (`sonic_vs` + the `sonic_yang.compatibility`
row), `lab/topology.clab.yml`, and `lab/profiles/sonic-vs/profile.yaml`, and re-run
`scripts/lib/verify_pins.sh`.

---

## 8. Recommended order of work

1. **Build image v2** (D4) — unblocks any write-side assertion at all.
2. **Fix `switch_type` in the profile bootstrap** — one line, and without it every GCU write fails
   regardless of image.
3. **Convert the two suites** with content assertions (D1-B, D2, D3), so no test can pass on an
   empty result.
4. **Re-run the capability gate** (`scripts/lib/qualify.sh`) against the lab and capture
   `qualify.report.json` as phase-8 evidence.
5. **Decide FR-003/SC-013 wording** — either accept the re-expressed witnesses, or record the
   unreachable criteria as ENV-BLOCKED with this document as the justification.

Steps 1–3 are engineering. Step 5 is the only one that genuinely needs a human decision.

---

## Appendix A — reproduction

Node used below: the running smoke container (`ainetops-smoke-sonic`, `172.17.0.5`). Substitute a
lab node IP for a fabric run.

```bash
# capabilities (proves the gNMI server, and the model list)
gnmic -a 172.17.0.5:8080 --skip-verify -u admin -p admin capabilities

# read SRv6 config (both accepted path forms)
gnmic -a 172.17.0.5:8080 --skip-verify -u admin -p admin get --path /SRV6_MY_SIDS --target CONFIG_DB
gnmic -a 172.17.0.5:8080 --skip-verify -u admin -p admin get --path sonic-db:/CONFIG_DB/SRV6_MY_LOCATORS

# the vacuous-pass demonstration: a table that does not exist, rc=0
gnmic -a 172.17.0.5:8080 --skip-verify -u admin -p admin get --path /TOTALLY_FAKE_TABLE --target CONFIG_DB

# image feature audit
docker run --rm --entrypoint bash localhost:5000/sonic-vs-gnmi:202605 -c 'ls -l /usr/sbin/telemetry; grep -c "program:telemetry" /etc/supervisor/conf.d/supervisord.conf; ls /usr/local/yang-models/sonic-srv6.yang'

# the three write prerequisites (run inside the node)
mkdir -p /var/run/dbus && dbus-daemon --system --fork          # 1. dbus
/usr/local/bin/sonic-host-server &                             # 2. GCU dbus provider
redis-cli -n 4 hset "DEVICE_METADATA|localhost" switch_type npu # 3. valid enum

# write path that works today (GCU), then read it back over gNMI
python3 -c 'import jsonpatch; from generic_config_updater.generic_updater import GenericUpdater, ConfigFormat; GenericUpdater().apply_patch(jsonpatch.JsonPatch([{"op":"add","path":"/SRV6_MY_SIDS","value":{"loc1|fc00:0:1:1::/64":{"action":"uN"}}}]), ConfigFormat.CONFIGDB, False, False, False, [])'
gnmic -a 172.17.0.5:8080 --skip-verify -u admin -p admin get --path /SRV6_MY_SIDS --target CONFIG_DB

# write path that is blocked (gNMI Set) — fails on any key, with or without a slash
gnmic -a 172.17.0.5:8080 --skip-verify -u admin -p admin --encoding JSON_IETF set --update-path 'sonic-db:/CONFIG_DB/SRV6_MY_LOCATORS/loc2' --update-value '{"prefix":"fc00:0:2::"}'
```

**Note on the smoke container:** it was mutated during this investigation (host service installed and
started, `switch_type` corrected, one locator and one SID written). It is a scratch container; treat
its CONFIG_DB as dirty and rebuild it from the image for any clean measurement.

---

## Appendix B — related records

- `/root/wiggum/INCIDENT-2026-08-31-ainetops-phase8.md` — the loop-side incident (why phase 8 burned
  passes; issues #9/#10/#11), including the finding that the missing gNMI capability gated
  everything downstream.
- `lab/images/sonic-vs-gnmi/README.md` — image provenance and rebuild steps.
- `versions.lock.yaml` — `sonic_vs` (capable image) and `sonic_vs_base` (2022 base, kept for
  provenance).
