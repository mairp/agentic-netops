# SRv6 request enablement: research

Date: 2026-10-11. Branch: `feat/sonic-vm-conformance` at `0720c4e2`. Read-only research; no code,
lab or cluster was changed.

Conventions: every code claim carries `file:line`. Anything not read directly from the repo or
the proof logs is tagged **(inferred)**. Paths under `specs/` and `.wiggum/` are untracked and
were read from disk.

## Summary

- **The SONiC image was never the only blocker, and it is no longer the main one.** An SRv6
  request fails in every layer above the device: the agent tier has no SRv6 construct, the Go
  translator can only emit a Kubenet `Network`, and the `SRv6Service` controller is a scaffold
  that sets `Ready=False / WaitingDependencies` forever and never renders or writes anything
  (`controllers/srv6service/controller.go:43-50,84-89`).
- **Two SRv6 phrasings are silently mis-provisioned today.** "SRv6 L3VPN ..." matches the
  `l3vpn` pattern and becomes a VXLAN `ip-vrf`; "EVPN over SRv6 ..." matches `evpn` and becomes
  a VXLAN `mac-vrf` (`agents/provisioning/mapper/agent.py:67-82`). The word "SRv6" is dropped
  without a refusal. Only a bare "SRv6 service" is refused.
- **The only working southbound cannot reach a sonic-vm guest.** Device writes go through the
  host fabric-executor using `docker exec` (`cmd/fabric-executor/main.go:9-18,653-675`); on
  sonic-vm the container is a QEMU launcher without `config`/`redis-cli`/`vtysh`
  (`tests/integration/lib/node_exec.sh:4-9`). So on the SRv6-capable profile nothing, including
  the existing four constructs, can be provisioned by the controllers **(inferred)**.
- **The sonic-vm gate proves SRv6 control-plane tables only**: `SRV6_MY_LOCATORS` /
  `SRV6_MY_SIDS` (uN, uDT46) written by GCU over SSH and read back over TLS gNMI. It proves no
  SRv6 VPN service, no BGP SRv6 signalling, no SRv6 forwarding, and two of its 17 checks
  (H.Encaps.Red, SID-list) pass by skipping on this profile.
- **Three entry points, one foundation.** Direct `SRv6Service` submission is blocked at the stub
  controller and carries most of the work; the agent path adds the construct across mapper,
  schemas, allocator and translator; the UI is chat-only and inherits the agent path, needing
  only a suggested prompt and status listing. `sonic-vs` stays the default profile; the
  recommendation is capability-based refusal rather than switching the default to `sonic-vm`.
- **Size**: 17 work items across 10 layers (3 L, 9 M, 5 S), 11 owner decisions, and
  acceptance that needs a live lab. **Recommendation: a new spec (004), not a prompt.** A spec
  seed is drafted at the end. The 001 reconciliation already called for exactly this spec
  (candidate C2, `specs/001-agentic-netops-sonic-evpn-fabric/reconciliation-2026-09-19.md:259`).

## Current state (what works)

### Implemented and tested

| Piece | Evidence | Note |
| --- | --- | --- |
| `SRv6Service` CRD installed by provision | `config/crd/bases/agentic-netops.io_srv6services.yaml:105-113` (5 CEL rules); applied at `scripts/provision.sh:282` | Admission-time shape checks only |
| CRD envtest | `tests/envtest/srv6service_crd_envtest_test.go:23`, skipped without `KUBEBUILDER_ASSETS` (`:38`); `Makefile:125-126` | Tests the CRD, not a reconcile |
| srv6-controller binary, deploy, RBAC | `cmd/srv6-controller/main.go:68-77`; `scripts/provision.sh:134-164`; `deploy/rbac/srv6-crd-rbac.yaml:4-23` | Runs, but see next table |
| Deployer allow-list accepts `SRv6Service` | `agents/provisioning/deployer/submit.py:41-44`; RBAC `deploy/agents/namespace-rbac.yaml:87`; unit tests `agents/tests/unit/test_deployment_transaction.py:91,260-279` | The apply/rollback/watch transaction is kind-agnostic and already ordered Network before SRv6Service |
| KUID SRv6 pools | `deploy/kubenet/srv6-pools.yaml:3-61` (locator /48, SID /64, service-id range); applied at `scripts/provision.sh:288` | Three static sample claims; nothing consumes them |
| Lab topology with SRv6 clients on both profiles | `lab/topology.sonic-vm.clab.yml:86-102,127-129`; `lab/topology.clab.yml:86-102,127-129` | `srv6-client01/02` on `leaf01/02:eth4` |
| Capability gate, 17/17 on sonic-vm | `scripts/lib/qualify.sh:57,79,90`; `.wiggum/features/001-agentic-netops-sonic-evpn-fabric/gates/proofs/qualify.report.json` (written 2026-10-11 14:56) | See caveats section |
| Compat pin resolution | `pkg/compat/pins.go:82-122`; `tests/unit/compat_fullvalidate_test.go` | Site ConfigMap generated at `scripts/provision.sh:229-275` |

### Implemented but unreachable from a request

| Piece | Evidence | Why unreachable |
| --- | --- | --- |
| `pkg/render` SRv6 renderers | `pkg/render/srv6.go:7-20`; `pkg/render/evpn_advanced.go:39-63` | Called only from unit tests (`tests/unit/render_evpn_srv6_test.go:31-36`, `tests/unit/register_guard_test.go:33`, `tests/unit/render_register_positive_test.go:26`). No controller imports them; the provider uses only `render.CanonicalHash` (`controllers/sonicprovider/controller.go:207`) |
| `pkg/model` SRv6 structs | `pkg/model/types.go:70-94`; `pkg/model/normalize.go:64-66` | Same: test-only callers |
| Register entries for SRv6 paths | `pkg/register/oc_vs_sonic.yaml:26-45` | Registers the placeholder paths the renderers emit |
| SRv6 observability | `deploy/observability/dashboards/srv6-service-path.json:6-8`; alert `deploy/observability/rules/agentic-netops.rules.yaml:38-42` | No Go or Python code emits `agentic_netops_srv6_active_path`; `sonic_srv6_mysid_packets_total` would have to come from gNMIc (**inferred**: I did not trace `deploy/gnmi/gnmic.yaml`) |
| Live SRv6 service tests | `tests/integration/srv6_capture_counters.sh:1-14`; `tests/integration/srv6_failover_path_change.sh:1-9` | Assume a converged `example-srv6` and `docker exec` into nodes; cannot pass while the controller is a stub |

### Missing

- An SRv6 construct anywhere in the request path (mapper, schemas, supervisor, allocator, Go
  `ServiceInput`, translator). Details in the next section.
- A reconciler that turns an `SRv6Service` into device operations, verifies them, sets
  `Ready=True`, and rolls back on delete.
- A device recipe for an SRv6 VPN service on SONiC 202505 that has been proven on any profile.
- A write path from the controllers into a sonic-vm guest.
- An underlay/BGP bootstrap for the sonic-vm fabric
  (`lab/profiles/sonic-vm/bootstrap/README.md:28-30`).

## Where SRv6 requests are blocked

"Deliberate" means a guard written to refuse; "unfinished" means the feature was never built;
"side effect" means a rule written for something else that catches SRv6 by accident.

| # | Layer | file:line | Behavior | Why |
| --- | --- | --- | --- | --- |
| 1 | Mapper (deterministic) | `agents/provisioning/mapper/agent.py:67-96` | Only four constructs are detectable. `l3vpn` and `vrf` map to `ip-vrf` (`:80`), `evpn` maps to `mac-vrf` (`:73`). "SRv6 L3VPN" and "EVPN over SRv6" therefore become VXLAN services with no warning | Side effect of the 003 legacy-alias folding. Not tied to the image. This is the first thing to fix |
| 2 | Mapper | `agents/provisioning/mapper/agent.py:507-519` | A request with no recognised construct gets `unsupported_properties = ["constructs: vlan, mac-vrf, ip-vrf, acl"]` and is terminal | Deliberate (002 FR-004 / 003 vocabulary), not image-related |
| 3 | Mapper | `agents/provisioning/mapper/agent.py:98-105` | `traffic engineering` / `te-policy` / `te-path` are refused as `tePolicy` | Deliberate; SRv6 explicit-path requests hit this |
| 4 | Interpretation schema | `agents/common/schemas/interpretation.py:25-56,199-208` | `ServiceType` enum has four members; any other string raises `unsupported service_type` | Deliberate closed vocabulary (003) |
| 5 | Normalized intent | `agents/common/schemas/normalized_intent.py:144-145,422-423` | `type` outside the four constructs yields `type: unsupported` | Deliberate; mirrors Go |
| 6 | Supervisor | `agents/supervisors/provisioning/graph/graph.py:235-238,451-452` | Clarification hint and construct tokeniser list only the four constructs | Unfinished for SRv6 |
| 7 | Suggested prompts / UI | `agents/supervisors/provisioning/suggested_prompts.json` (no SRv6 entry); `ui/src/App.tsx:93` | No SRv6 example is offered; `grep -i srv6` over `ui/src`, `ui/index.html` and `prompts/` returns nothing | Unfinished. The UI has no gate of its own |
| 8 | Allocator | `agents/provisioning/allocator/kuid.py:49-63,456-523` | Claims only L2VNI, L3VNI, VLAN and extended-community indexes | Unfinished: no locator, SID or service-id claim |
| 9 | Go intent validation | `pkg/migration/input.go:318-319`; `pkg/migration/constructs.go:50-57` | `type: unsupported '<x>' (constructs: ...)` | Deliberate closed vocabulary |
| 10 | Go translator | `pkg/migration/translate.go:183-185` | Always emits `kind: Network`; there is no branch that emits `SRv6Service` | Unfinished. 002 assumed "supported service types follow feature 001" (`specs/002-agntcy-intent-tier/spec.md:469-470`) but 001's translator never covered SRv6 |
| 11 | Deployer | `agents/provisioning/deployer/submit.py:482` and `:313-315` | ACL conflict check and `list_networks` are Network-only | Not a gate; an `SRv6Service` would pass through. Service status listing would not show it |
| 12 | SRv6 controller | `controllers/srv6service/controller.go:43-50,84-89` | Sets `Ready=False`, reason `WaitingDependencies`, requeues every 10 s. No render, no write, no verify, no `Ready=True` path, no finalizer; deletion is a no-op (`:33-35`) | Unfinished scaffold (001 T026a). 001's task list has scaffold, deploy and test tasks for SRv6 but no task that implements the reconcile (`specs/001-agentic-netops-sonic-evpn-fabric/tasks.md:104-106,151-153,168-171`) |
| 13 | Provision | `scripts/provision.sh:293-295` | Applies the sample `example-srv6` and waits for Ready with `\|\| true` | The wait can never succeed; the failure is swallowed |
| 14 | Renderers | `pkg/render/srv6.go:9-10,19`; `pkg/render/evpn_advanced.go:43,51,58` | Emit `/sonic-srv6:sonic-srv6/SRV6_GLOBAL`, `MYSID`, `BEHAVIORS`, `SID_LIST`, `POLICY` | Unfinished placeholders ("MySID entries simplified", `srv6.go:10`). These tables do not exist in the SONiC schema: only `SRV6_MY_LOCATORS` and `SRV6_MY_SIDS` do (`tests/integration/evpn_srv6_suite.sh:6-9`) |
| 15 | Register guard | `pkg/register/oc_vs_sonic.yaml:26-45`; embedded copy `pkg/sdc/validate.go:73-106` | Whitelists the same non-existent paths; the embedded default lacks `BEHAVIORS` and the l3vni/type5/irb entries | Unfinished; the guard currently certifies paths the device rejects |
| 16 | API types | `api/v1alpha1/srv6service_types.go:19-20,27-28` | Self-described "narrow placeholder"; two kubebuilder CEL markers use a typographic quote (`”`) instead of `''`. The shipped CRD YAML was hand-written with 5 of the 13 marker rules (`config/crd/bases/agentic-netops.io_srv6services.yaml:105-113`) | Unfinished. Regenerating the CRD from the markers would break or change validation |
| 17 | Compat gate | `pkg/compat/compat.go:34-35,41`; used at `controllers/srv6service/controller.go:73-82` and `controllers/sonicprovider/network_controller.go:164` | `requiresSRv6()` returns `true` unconditionally, so `cap.sai.srv6 != "true"` blocks every object, Network included, with `CapabilityMissing` | Deliberate guard tied to the old image. Currently open because provision hard-codes `"cap-sai-srv6": "true"` (`scripts/provision.sh:272`) for every profile |
| 18 | Compat pins | `scripts/provision.sh:240` | The `sonic-image` pin is taken by a regex that only matches `localhost:5000/sonic-vs-gnmi:`; on `--profile sonic-vm` the cluster still records the sonic-vs image | Tied to the old single-profile assumption |
| 19 | Southbound | `cmd/fabric-executor/main.go:9-18,173,235-252,653-675`; `pkg/fabricplan/plan.go:3-19` | All device writes are `docker exec` (GCU, `redis-cli`, shell, `vtysh`) into the node container. No SRv6 op exists in `pkg/fabricplan` (`grep -i srv6` returns nothing) | Unfinished for SRv6, and structurally unable to reach a sonic-vm guest (**inferred** from `tests/integration/lib/node_exec.sh:4-9`, which had to add an SSH path for exactly this reason) |
| 20 | sonic-vm bootstrap | `lab/profiles/sonic-vm/bootstrap/README.md:28-30`; `lab/profiles/sonic-vm/README.md:17-18` | No underlay/BGP/EVPN bootstrap on sonic-vm: "Fabric configuration is gNMI-driven by qualification" | Deliberate scope limit of the profile; means the VM fabric has no routed underlay outside the gate's temporary witnesses |
| 21 | Docs | `TUTORIAL.md:33` vs `TUTORIAL.md:93`; `docs/DEMO_TUTORIAL.md:117-158` | The loop diagram says agents submit an `SRv6Service`; the table says they submit a `Network`. The demo tutorial tells the reader to apply an `SRv6Service` and verify with `docker exec ... vtysh -c 'show segment-routing srv6 locator'` | The CR will sit at `Ready=False` and the verify command cannot work on a sonic-vm launcher |

Mapper behavior in rows 1-2 was confirmed by replaying the `_SERVICE_PATTERNS` regexes outside
the agent on five SRv6 phrasings; I did not run the agent itself, and the supervisor's LLM
classification step (`agents/supervisors/provisioning/prompts/system.py:113-162`) runs before
the mapper and may refuse some of these first (**not verified**).

A constraint to keep in mind when naming the new construct: the vocabulary guard fails the
suite if `l3vpn`, `vpls`, `vpws`, `e-line` or `l2l3-irb` appears on an operator surface
(`agents/tests/unit/test_vocabulary_guard.py:24-33`).

## The three entry points

SRv6 enablement has to hold for each way a service can enter the system. They share most of
the stack: (b) is a thin front end to (a), and (a) ends by creating the resource that (c)
submits directly. So (c) is the foundation and carries most of the cost.

| Entry point | How it enters | First block today | Further blocks | Own work | Shared work it needs |
| --- | --- | --- | --- | --- | --- |
| (c) Direct `SRv6Service` CR | `kubectl apply` of the CR (sample: `config/samples/agentic-netops_v1alpha1_srv6service.yaml:1-24`; tutorial: `docs/DEMO_TUTORIAL.md:126-152`) | Accepted by admission, then parked: controller sets `Ready=False / WaitingDependencies` and requeues forever (`controllers/srv6service/controller.go:43-50,84-89`) | No plan rendering for SRv6 (row 14, 19); no device recipe; no write path into sonic-vm (row 19); no VM fabric baseline (row 20); delete is a no-op (`controller.go:33-35`); identifiers in the CR are typed by hand, nothing claims them from KUID (`srv6service_types.go:54-55`) | Items 1-7, 15, 16: **3 L + 4 M + 1 S** | none: this is the base |
| (a) Agent / natural language | Supervisor classifies, mapper interprets, allocator claims, deployer calls the Go translator and applies | Mapper: SRv6 is either downgraded to a VXLAN construct or refused (rows 1-2) | Schemas (rows 4-5), supervisor vocabulary (row 6), allocator (row 8), Go contract and translator (rows 9-10). The deployer's apply/watch already accepts the kind (`submit.py:41-44`) | Items 8-13: **5 M + 1 S** | all of (c) |
| (b) UI | Chat only. The page posts free text to the supervisor at `/agent/prompt/stream` (`ui/src/hooks/useAgentAPI.ts:71`) from a composer form or a suggested-prompt dropdown (`ui/src/components/Chat/Chat.tsx:231,242`). There is no service form, no construct picker and no direct Kubernetes call | None of its own. It inherits every block of (a) | No SRv6 suggested prompt: the served list comes from `/suggested-prompts` (`ui/src/App.tsx:102`) and the offline fallback is hard-coded (`ui/src/App.tsx:91-96`) and guarded against drifting from the served list (`ui/src/App.tsx:85-89`). "Show the status of my services" lists `Network` objects only (`submit.py:313-326`) | Item 14 plus the status half of item 13: **S** | all of (a) and (c) |

Notes per entry point:

- **(c)** is the only entry point that can be enabled and accepted on its own, and it is where
  the feasibility risk sits (item 1). Until the controller is real, `provision.sh` hides the
  failure (`scripts/provision.sh:293-295`) and the demo tutorial describes an outcome that does
  not occur (`docs/DEMO_TUTORIAL.md:152-158`).
- **(a)** has one defect that should not wait for the feature: SRv6 phrasings that are
  provisioned as VXLAN today. It also needs a decision the CR path does not: where the CR's
  hand-typed fields (`locatorPrefix`, `servicePrefix`, `client`/`server` addresses, `path`,
  `topologyRef`; `srv6service_types.go:49-70`) come from when the operator gives only tenant,
  attachments and a prefix.
- **(b)** needs no architecture work if the owner is content with chat as the UI. If "UI
  enablement" means a structured SRv6 form, that is new scope (M) and a new decision; nothing
  in `ui/src` supports structured submission today. I did not read the component files beyond
  the lines cited, so richer status rendering needs are **inferred**.

## Lab profile selection

**How it is selected.** `sonic-vs` is the default in three places: `scripts/provision.sh:15`,
the topology fallback in `scripts/lib/containerlab.sh:14-15` (anything other than `sonic-vm`
resolves to the fast topology), and `Makefile:71` (`PROF ?= sonic-vs`). `sonic-vm` is chosen
with `./scripts/provision.sh --profile sonic-vm` (`scripts/provision.sh:20-23,40`). The choice
is a provision-time shell variable only: no agent, controller, executor or `pkg/` file reads
the profile (a search for `sonic-vm` / `AGENTIC_NETOPS_PROFILE` across `agents/`,
`controllers/`, `cmd/`, `pkg/` returns no file), and the one cluster-visible trace, the
`sonic-image` pin, is wrong on sonic-vm (row 18).

**SRv6 on sonic-vs: what is and is not supported.**

- Works: the same GCU-written locator/SID tables readable over gNMI
  (`lab/profiles/sonic-vs/profile.yaml:18-22`), the kernel seg6 witnesses for H.Encaps.Red and
  ordered SID lists (`tests/integration/evpn_srv6_suite.sh:210-216`), the executor's
  `docker exec` write path, and a bootstrapped BGP/EVPN fabric
  (`scripts/lib/containerlab.sh:166-174`).
- Blocked or unproven: gNMI Set (`docs/SRV6_GNMI_CAPABILITY_FINDINGS.md:24`); OpenConfig and
  `/sonic-srv6:` translib paths (`:27-28`); no SRv6 VPN service, BGP SID signalling or
  client-to-client SRv6 traffic has been demonstrated, exactly as on sonic-vm.
- It is not a real SONiC OS: the kernel witnesses exercise the container host's kernel, not a
  SONiC dataplane (`tests/integration/evpn_srv6_suite.sh:210-213`). That is the reason 001
  named sonic-vm as the conformance profile (`spec.md:420`).
- Nothing in the repo shows SRv6 failing on sonic-vs for a reason that sonic-vm fixes. The
  message "this profile is not SRv6-qualified" at `scripts/provision.sh:335-336` predates the
  2026-09-04 qualification and now contradicts `versions.lock.yaml:79-83`.

**Cost of running sonic-vm.**

| Cost | Evidence |
| --- | --- |
| KVM and nested virtualization, privileged containers with `/dev/kvm` | `lab/profiles/sonic-vm/README.md:9-12`; enforced by `scripts/lib/preflight.sh:118-122` |
| At least 8 cores, 16 GB RAM, 40 GB disk (four VMs) | `lab/profiles/sonic-vm/README.md:11`. Preflight's generic minimum disk is 20 GB (`scripts/lib/preflight.sh:26`); I did not check whether it is raised for sonic-vm |
| Operator-built image, not pullable; the source artifact is about 23 GB zipped | `TUTORIAL.md:241-246`; `scripts/build-sonic-vm.sh:71-72,183` |
| Slower boot | Stated qualitatively only (`lab/profiles/sonic-vm/README.md:16`). No measured boot time is recorded in the repo; the gate run itself took about 14 minutes by proof-file timestamps (14:42 to 14:56) |
| No controller write path, no fabric bootstrap, `docker exec` based suites and docs do not work | rows 19-21 |
| No kernel seg6 dataplane witness | `lab/profiles/sonic-vm/README.md:20-22` |

**Should requests detect the profile, or should sonic-vm become the default?** My
recommendation, for the owner to confirm:

1. **Do not make sonic-vm the default now.** Today it would break provisioning of the four
   working constructs (row 19, inferred), needs an image no one can pull, and raises the host
   bar for every user of the lab. Revisit after items 2 and 3 land and the existing suites pass
   on it.
2. **Gate on a capability, not on the profile name.** The mechanism already exists:
   `cap.sai.srv6` flows from the site ConfigMap into the controllers
   (`pkg/compat/pins.go:52,97-101`; `controllers/srv6service/controller.go:73-82`). Make
   provision set it from the gate result for the active profile and from whether the service
   recipe was proven there, instead of the constant at `scripts/provision.sh:272`, and apply it
   only to SRv6 objects (today `requiresSRv6()` applies it to everything,
   `pkg/compat/compat.go:41`). The CR path (c) then refuses with `CapabilityMissing` on a
   profile that cannot carry the service.
3. **Refuse early in the tier as well.** A CR that sits at `Ready=False` is a poor answer to a
   chat request. Give the supervisor or mapper read access to the same capability (the
   ConfigMap, or an environment value stamped at intent-tier install) so (a) and (b) answer
   "SRv6 is not available on this lab profile" before any claim is made. This is a small
   addition to items 10-11 but needs RBAC for the read, so it is a decision (question 9).
4. Which profile ends up SRv6-capable is an output of the spike (item 1), not an input. If the
   recipe only works on sonic-vs, the capability is true there and the tier needs no profile
   knowledge at all.

## What the sonic-vm profile proves and its caveats

**Image and path.** `local/sonic-vm:202505` built by `scripts/build-sonic-vm.sh` (vrnetlab,
KVM), four SONiC VMs (`lab/topology.sonic-vm.clab.yml:34-57`). TLS gNMI on `:8080` enabled via
the `GNMI` CONFIG_DB table (`lab/profiles/sonic-vm/bootstrap/README.md:20-26`). Node-side
operations run over SSH into the guest (`tests/integration/lib/node_exec.sh:22-33`).

**What the 17 checks assert.**

| Check | What is actually asserted | file:line |
| --- | --- | --- |
| Capabilities, Get, Subscribe | gNMI RPCs answer over TLS | `scripts/lib/qualify.sh:57` |
| Set | Not gNMI Set. A GCU `config apply-patch` (over SSH) of an SRv6 locator and SID, then gNMI read-back, then GCU delete | `tests/integration/sonic_gnmi_suite.sh:73-76,146-151` |
| sonic-srv6 | GCU-written locator readable over gNMI | `tests/integration/sonic_gnmi_suite.sh:177-201` |
| persistent | Value survives a guest `config reload` | `lab/profiles/sonic-vm/README.md:24` |
| SRv6-Underlay | `SRV6_MY_LOCATORS` row with the prefix reads back. No IPv6 underlay routing is tested | `tests/integration/evpn_srv6_suite.sh:143-153` |
| End | A `uN` SID row reads back | `tests/integration/evpn_srv6_suite.sh:156-166` |
| End.DT46 | A `uDT46` row with `decap_vrf` reads back (`decap_vrf` is `default`, `:97`) | `tests/integration/evpn_srv6_suite.sh:169-181` |
| Decapsulation | `decap_dscp_mode=uniform` reads back. No packet is decapsulated | `tests/integration/evpn_srv6_suite.sh:184-195` |
| Counters | `COUNTERS_SRV6_NAME_MAP` is queryable; empty is accepted | `tests/integration/evpn_srv6_suite.sh:254-268` |
| H.Encaps.Red, SID-list | Kernel `ip -6 route ... encap seg6`. **Skipped on sonic-vm** and recorded as pass | `tests/integration/evpn_srv6_suite.sh:210-229`; last line of `gates/proofs/qualify.H.Encaps.Red.out.log` and `qualify.SID-list.out.log` |
| EVPN-Type2/3/5 | One iBGP session with the L2VPN EVPN AF reaches Established across leaf-spine-leaf; Type-5 additionally checks the EVPN RIB is valid JSON. No route of any type is asserted | `tests/integration/evpn_srv6_suite.sh:349-393,396-429` |
| YANG-Paths | Required path list | `scripts/lib/qualify.sh:90` |

**So the profile proves:** micro-SID style locator and SID rows (`uN`, `uDT46`) are accepted by
the 202505 YANG via GCU, persist, and are readable over TLS gNMI on a real SONiC VM.

**It does not prove:** gNMI Set (still the GCU witness), L3VPN or EVPN over SRv6, BGP SRv6 SID
signalling, FRR `segment-routing srv6` state, an IPv6 underlay, any encapsulation or
decapsulation of a packet, classic (non-uSID) `End`/`End.DT46` behaviors, or a non-default
`decap_vrf`.

**Documented caveats.**

- The profile README says the guest kernel has no seg6 lwtunnel
  (`lab/profiles/sonic-vm/README.md:20-22`; `TUTORIAL.md:258-261`). **This is wrong; see the
  addendum at the end.** The guest kernel has seg6 built in and the gate's probe is a false
  negative. End-to-end SRv6 forwarding through the VM is still not exercised by any test.
- Every guest boots with `Loopback0=10.1.0.1/32`, bgpd AS 65100, router-id 10.1.0.1
  (`lab/profiles/sonic-vm/README.md:22-23`). The code comment at
  `tests/integration/evpn_srv6_suite.sh:346-348` says `10.2.0.1` instead; the README value is
  the consistent one.
- The profile README says the tests "program configuration via gNMI"
  (`lab/profiles/sonic-vm/README.md:17-18`); the suites write through GCU over SSH
  (`tests/integration/evpn_srv6_suite.sh:69-73`).
- The image pin is inconsistent: `versions.lock.yaml:99-100` records `local/sonic-vm` plus a
  digest, the topology uses the tag `local/sonic-vm:202505`
  (`lab/topology.sonic-vm.clab.yml:35`), and the compat list uses `local/sonic-vm@sha256:...`
  (`versions.lock.yaml:162`).
- The operator must build the image locally (`TUTORIAL.md:241-246`).

**Default profile and switching.** The default is still `sonic-vs`
(`scripts/provision.sh:15`). Switching is `--profile sonic-vm`, which selects the other
topology (`scripts/lib/containerlab.sh:14-15`) and bootstrap (`:59-60`), and requires KVM plus
the local image. It is a full lab redeploy, not an in-place change. At research time
`docker ps` showed the running lab on `local/sonic-vm:202505`.

**The premise needs a correction.** `sonic-vs` has claimed SRv6/gNMI qualification since
2026-09-04 (`lab/profiles/sonic-vs/profile.yaml:18-22`; `versions.lock.yaml:79-88`), with the
same GCU-witness approach, and it is the only profile where the kernel seg6 witnesses run
(`TUTORIAL.md:261`). The device-side evidence for SRv6 table programming is therefore the same
on both profiles; sonic-vm adds a real SONiC OS and removes the kernel dataplane witness.

## Required work

Ordered by dependency. Size: S under half a day, M one to two days, L several days or
live-lab iteration.

| # | Item | Files | Size | Depends on |
| --- | --- | --- | --- | --- |
| 1 | **Spike: prove a device recipe** for one SRv6 VPN service by hand on the target profile: locator and SID rows, FRR `segment-routing srv6` locator, BGP VPN SID export per VRF, IPv6 underlay reachability of locators, client-to-client ping. Record exact commands and read-back witnesses | new notes under the spec; `docs/SRV6_GNMI_CAPABILITY_FINDINGS.md` | L (live lab) | Q1, Q2 |
| 2 | **Southbound into sonic-vm**: give the fabric-executor an SSH-to-guest backend selected per node kind, mirroring `node_exec.sh` | `cmd/fabric-executor/main.go:173,653-675`; executor node map in `scripts/provision.sh:170-220` | M-L | Q2 |
| 3 | **sonic-vm fabric bootstrap**: per-node loopbacks, ASNs, router-ids, underlay BGP (IPv4 and IPv6), replacing the image defaults | new `lab/profiles/sonic-vm/bootstrap/configure-fabric-bgp.sh`; `scripts/lib/containerlab.sh:54-141` | M | 2 |
| 4 | **API**: settle the service resource (rework `SRv6Service` or extend `Network`), fix the CEL markers, regenerate CRD and deepcopy, update the sample | `api/v1alpha1/srv6service_types.go:21-39`; `config/crd/bases/agentic-netops.io_srv6services.yaml`; `config/samples/agentic-netops_v1alpha1_srv6service.yaml`; `tests/envtest/srv6service_crd_envtest_test.go` | M | Q3, 1 |
| 5 | **Plan rendering**: SRv6 ops, checks and rollback in the executor's vocabulary; delete or rewrite the placeholder renderers and register entries | `pkg/fabricplan/plan.go` (new `renderSRv6`), `pkg/fabricplan/plan_test.go`; `pkg/render/srv6.go`, `pkg/render/evpn_advanced.go:38-63`; `pkg/register/oc_vs_sonic.yaml:26-45`; `pkg/sdc/validate.go:73-106`; `tests/unit/render_evpn_srv6_test.go`, `tests/unit/register_guard_test.go` | L | 1, 4 |
| 6 | **Controller**: real reconcile with finalizer, plan, executor apply and verify, `Ready=True` from verified state, delete rollback, `configHashes`, periodic re-verify. Reuse the Network reconciler's structure | `controllers/srv6service/controller.go`; `controllers/sonicprovider/network_controller.go:100-250` as the model; `cmd/srv6-controller/main.go:68-77`; `deploy/agentic-netops/manifests/srv6-controller.yaml` | L | 2, 5 |
| 7 | **Compat pins**: make `sonic-image` and `cap-sai-srv6` profile-aware and derived from the gate result; reconcile the sonic-vm pin forms; decide whether `requiresSRv6` should gate non-SRv6 objects | `scripts/provision.sh:240,272`; `pkg/compat/compat.go:34-41`; `versions.lock.yaml:98-101,162` | S | none |
| 8 | **Go intent contract**: add the construct to `ServiceInput`, validation, and a translator branch that emits the chosen resource | `pkg/migration/constructs.go:50-90`; `pkg/migration/input.go:199-320`; `pkg/migration/translate.go:83-205`; `cmd/intent-translator/main.go` | M | 4, Q4 |
| 9 | **Python schema parity** | `agents/common/schemas/interpretation.py:25-56`; `agents/common/schemas/normalized_intent.py:137-427`; `agents/tests/unit/test_schemas.py` | M | 8 |
| 10 | **Mapper**: detect SRv6 before the `l3vpn`/`evpn`/`vrf` patterns, parse what the construct needs, and until the feature lands refuse SRv6 explicitly instead of downgrading to VXLAN | `agents/provisioning/mapper/agent.py:67-116,494-611`; `agents/provisioning/mapper/catalogue.json`; `agents/tests/unit/test_mapper_agent.py`; new corpus file under `agents/tests/corpus/phrasings/` | M | 9 |
| 11 | **Supervisor**: construct tokens, clarification hint, classification prompt, suggested prompts | `agents/supervisors/provisioning/graph/graph.py:235-238,451-452`; `agents/supervisors/provisioning/prompts/system.py`; `agents/supervisors/provisioning/suggested_prompts.json`; `agents/tests/unit/test_suggested_prompts_*.py` | S-M | 10 |
| 12 | **Allocator**: claim locator, SID and service-id per request from the existing pools, stamp correlation id, release on decline/rollback | `agents/provisioning/allocator/kuid.py:281-291,456-523`; `agents/provisioning/allocator/agent.py`; `agents/config/config.py`; `deploy/kubenet/srv6-pools.yaml` | M | 4, Q5 |
| 13 | **Deployer**: status listing and service-status resolution for the new kind; skill tags | `agents/provisioning/deployer/submit.py:313-326`; `agents/provisioning/deployer/card.py:20-30`; `agents/tests/unit/test_service_status_resolution.py` | S | 8 |
| 14 | **UI**: suggested prompt and status rendering for the new construct | `ui/src/App.tsx:93` and neighbours | S | 11 |
| 15 | **Tests and gate**: unit and envtest for 4-9; a live suite that submits the service and asserts verified state on sonic-vm via `node_exec.sh`; port `srv6_capture_counters.sh` and `srv6_failover_path_change.sh` off `docker exec`; make the two skipped gate checks report `skip`, not `pass` | `tests/integration/srv6_*.sh`; `tests/integration/evpn_srv6_suite.sh:217-229`; `scripts/lib/qualify.sh:79-87`; `agents/tests/e2e/` | M-L | 6, 10 |
| 16 | **Observability**: emit or scrape the metrics the dashboard and alert already query | `deploy/observability/dashboards/srv6-service-path.json:6-8`; `deploy/observability/rules/agentic-netops.rules.yaml:38-42`; `deploy/gnmi/gnmic.yaml` | M | 6 |
| 17 | **Docs**: fix the loop diagram, the demo tutorial SRv6 section and its verify command, known limitations, `specs/README.md` row | `TUTORIAL.md:33,228-263`; `docs/DEMO_TUTORIAL.md:117-165`; `agents/README.md`; `specs/README.md` | S | all |

Two items are worth doing regardless of the spec and are small enough for a direct change:
item 10's interim refusal (stop "SRv6 L3VPN" from silently becoming a VXLAN `ip-vrf`) and item
7 (profile-aware pins).

**Risks.**

- Item 1 may fail: SONiC 202505 with FRR may not signal or forward SRv6 VPN on a virtual
  platform. The whole feature rests on it, so it must run first and be allowed to end in "not
  achievable on this image".
- Item 2 changes the trust boundary (SSH credentials on the host executor) and touches the
  write path of all four existing constructs. Regression risk is highest here; the 299-test
  agents suite and `pkg/fabricplan/plan_test.go` do not cover the transport.
- The mapper is regex-ordered; adding a construct ahead of `l3vpn`/`evpn` can change how
  existing corpus phrasings map (`agents/tests/corpus/phrasings/l3vpn.yaml`).
- This repo's history includes approvals later contradicted by evidence
  (`specs/README.md:118-126`). Acceptance for this feature needs genuine live captures.

## Open questions for the owner

1. **Which service?** L3VPN over SRv6 (uDT46 per VRF, BGP IPv4/IPv6 VPN), EVPN over SRv6, or
   the 001 US5 shape (explicit primary/alternate SID path between two clients,
   `specs/001-agentic-netops-sonic-evpn-fabric/spec.md:169-200`)? The current CRD encodes the
   third; the gate's witnesses point at the first.
2. **Which profile is the acceptance target?** sonic-vm has no kernel seg6 and no proven SRv6
   forwarding; sonic-vs has kernel seg6 and a working executor path. Is control-plane-verified
   state on sonic-vm an acceptable definition of "provisioned", or is client-to-client traffic
   required (001 SC-013, `spec.md:395`)?
3. **Resource shape:** keep a separate `SRv6Service` CRD (001 FR-026, `spec.md:280`), or model
   SRv6 as an encapsulation option on the Kubenet `Network` the tier already submits? 003's
   out-of-scope list forbids changing the upstream Network field names
   (`specs/003-datacenter-service-constructs/spec.md:429-435`).
4. **Operator vocabulary:** a fifth construct, or an "over srv6" qualifier on `ip-vrf` /
   `mac-vrf`? The name must pass the vocabulary guard.
5. **Allocation:** per-node locators (static, bootstrap-owned) with per-service SIDs from KUID,
   or everything per service? The existing pools are "simplified"
   (`deploy/kubenet/srv6-pools.yaml:1`).
6. **Write path:** accept SSH-into-guest for the executor on sonic-vm, or invest in gNMI Set
   (blocked on the sonic-vs image, `docs/SRV6_GNMI_CAPABILITY_FINDINGS.md:24`; untested as true
   gNMI Set on sonic-vm)? This overlaps reconciliation candidate C1
   (`specs/001-agentic-netops-sonic-evpn-fabric/reconciliation-2026-09-19.md:258`).
7. **Fate of the placeholders:** delete `pkg/render` SRv6 renderers and their register entries,
   or rewrite them against `SRV6_MY_LOCATORS` / `SRV6_MY_SIDS`?
8. **Scope of path steering:** is the two-path lab policy from 001 (`spec.md:424-426`) in or
   out for this round? It conflicts with the mapper's `tePolicy` refusal.
9. **Profile handling:** confirm capability-based refusal (controller and tier) over making
   sonic-vm the default, and whether the tier may read the site capability ConfigMap.
10. **UI:** is chat plus an SRv6 suggested prompt sufficient, or is a structured SRv6 form
    wanted?
11. **Direct CR submission:** are hand-typed locator and prefixes acceptable on the CR path, or
    must the controller claim them from KUID even without the tier (001 FR-029,
    `spec.md:291`)?

## Specs history

- **001** made SRv6 a P1 story: US5 (`spec.md:169-200`), FR-026 to FR-030 (`spec.md:280-296`),
  SC-013 to SC-015 (`spec.md:395-403`), with `sonic-vm` named as the fallback profile
  (`spec.md:420`). Its tasks scaffold the controller and CRD and write tests, but contain no
  task implementing the SRv6 reconcile (`tasks.md:104-117,151-153,168-171`).
- **001 reconciliation (2026-09-19)** records rows 28-30, 51, 52, 80 as never held and proposes
  **candidate spec C2**: "Finish SRv6 conformance on a qualifying image, or formally de-scope it
  from 001", action "spawn spec" (`reconciliation-2026-09-19.md:180-181,259`). Candidate C1
  (declare the real southbound) is adjacent (`:258`). `specs/README.md:124` lists the disputed
  approvals.
- **002** adds no service type ("the supported set is inherited, not extended",
  `spec.md:469-470`) and only provisions RBAC for `srv6services`
  (`research.md:255-257`).
- **003** does not mention SRv6 at all (`grep -i srv6` over its `spec.md`, `plan.md`,
  `research.md` and reconciliation sheet returns nothing). It closed the vocabulary to four
  constructs (`spec.md:13-14`) and lists as out of scope "any service the fabric cannot already
  render" (`spec.md:429-433`), which is what excludes SRv6 in practice.

No existing spec covers SRv6 requests through the agent path.

## Recommendation: a new spec

A single prompt is not enough. The evidence:

- **Layers touched:** 10 (lab bootstrap, executor, API, plan/render, controller, compat,
  Go contract, four agents, UI, tests/docs), 17 items, three of them L.
- **Open decisions:** 11, of which Q1-Q3 change the shape of everything downstream.
- **Entry points:** three, with different acceptance (CR converges; chat request converges or
  refuses correctly; UI offers and reports it).
- **Acceptance needs a live lab**, including a spike whose outcome may be "not achievable".
- **Regression surface:** the executor transport and the mapper ordering both sit under the
  four constructs that work today.
- **Process fit:** the 001 reconciliation already assigned this to a spawned spec (C2), and a
  construct change crosses the 003 vocabulary contract.

Suggested split: do the two small fixes now by direct prompt (below), run item 1 as a
time-boxed spike, then specify.

### Prompt for the two immediate fixes

> In `/root/agentic-netops`, make two small, independent changes with tests. Do not touch the
> lab or cluster.
>
> 1. Mapper: a request that names SRv6 (`srv6`, `segment routing v6`, `segment-routing`) must
>    never be mapped to `ip-vrf` or `mac-vrf`. In
>    `agents/provisioning/mapper/agent.py`, detect it before `_detect_service_type` runs and
>    return a terminal interpretation with `unsupported_properties` naming SRv6 transport and
>    stating that the tier provisions VXLAN EVPN constructs only. Add the matching refusal text
>    and suggestion in `agents/supervisors/provisioning/graph/graph.py`. Add a corpus file under
>    `agents/tests/corpus/phrasings/unsupported/` with at least: "SRv6 L3VPN between ...", "EVPN
>    over SRv6 across ...", "ip-vrf over SRv6 ...", "SRv6 service between ...". Keep
>    `test_vocabulary_guard.py` green (mark legacy names with the `(migration alias)` trailer).
>    Run plain `pytest` in `agents/`; never run the e2e lifecycle marker.
> 2. Pins: in `scripts/provision.sh` (the `fabric-compat-pins` generator near lines 229-275)
>    select the `sonic-image` pin from `versions.lock.yaml` according to
>    `AGENTIC_NETOPS_PROFILE` instead of the hard-coded `sonic-vs-gnmi` regex, and make
>    `versions.lock.yaml` use one form for the sonic-vm image in `sonic_images.sonic_vm` and
>    `sonic_yang.compatibility`. Do not change `cap-sai-srv6` semantics. Run `make verify-pins`.
>
> Report the diff summary and test output. Do not commit.

### Spec seed for `/speckit-specify`

This seed reflects the owner decisions of 2026-10-11 (table at the end of this document).

**Title:** SRv6 service requests end to end (004)

**Problem statement.** An operator who asks for a service carried over SRv6 does not get one.
Through chat, two common phrasings are silently provisioned as VXLAN services and the rest are
refused. Below the tier, the `SRv6Service` resource is accepted by the cluster but its
controller never programs or verifies anything, the device recipe for an SRv6 VPN on the pinned
SONiC image has never been proven, the controllers' write path cannot reach the nodes of the
SONiC VM lab, and that lab boots every switch with the same identity and no underlay. Feature
001 required SRv6 services (US5, FR-026 to FR-030, SC-013 to SC-015); its 2026-09-19
reconciliation recorded them as never held and called for a dedicated specification (candidate
C2). The SONiC VM image now in the lab has an SRv6-capable kernel dataplane and accepts SRv6
locator and SID configuration, so the remaining gaps are in this repository.

**Users and value.** A network operator asks, in plain language, in the UI, or by applying a
resource, for a tenant service between attachment points carried over the SRv6 underlay, and
sees it reach Ready only when the devices' own state shows it and client traffic passes.
Withdrawing the service releases everything it claimed.

**In scope.**
- **Lab:** the SONiC VM image is the lab image for all four switches and the default profile.
  The fabric baseline gives each node a unique identity, IPv4 and IPv6 underlay reachability,
  and one SRv6 locator per node, owned by the lab bootstrap. The container image stays as a
  second selectable profile on which SRv6 is refused.
- **Service types:** L3VPN over SRv6 and EVPN over SRv6. EVPN covers routed (IP prefix) and
  bridged (MAC-VRF) services; the bridged one may be deferred to a follow-up if the prerequisite
  spike shows the image cannot carry it, in which case requests for it are refused by name.
- **Path steering:** a service may name a preferred path through one spine with the other as
  alternate; traffic follows the preferred path and moves to the alternate when it fails.
- **Three entry points:** plain-language request, the UI (SRv6 example prompts in chat and SRv6
  services in the status views; no structured form), and a directly applied `SRv6Service`
  resource, which stays a separate resource kind.
- Recognition of SRv6 requests by the tier, with clarification for missing fields and explicit
  refusal of unsupported variants; no SRv6 request is ever provisioned over a different
  transport.
- Identifier allocation by the controller from the cluster allocation authority on every entry
  point, including direct resources, released on decline, rollback and delete.
- A controller that applies, verifies, re-verifies and rolls back, with Ready derived only from
  device-observed state.
- A write and read path from the controllers to the SONiC VM nodes that also carries the four
  existing constructs.
- Update, idempotent re-apply, drift repair and delete, at the standard of the existing
  constructs.
- Capability gate checks that run on the SONiC VM profile instead of being skipped, and
  operator documentation.

**Out of scope.**
- Arbitrary operator-chosen SID lists beyond a preferred and an alternate spine, flex-algo,
  bandwidth or latency constraints.
- Multihoming, service chaining, multicast, QoS.
- Making gNMI Set work on images where it is blocked.
- Migrating existing VXLAN services to SRv6.
- Changing the upstream Kubenet `Network` field names.
- A structured SRv6 form in the UI.

**Acceptance criteria (draft).**
1. A default lab bring-up yields four SONiC VM switches with distinct loopbacks, ASNs and
   router-ids, established underlay sessions on all four fabric links, and each node's SRv6
   locator reachable from every other node.
2. The four existing constructs provision, verify, update and delete on that lab, and the
   existing suites pass on it.
3. For each supported service type, a plain-language request confirmed twice results in exactly
   one `SRv6Service` whose Ready becomes True, with the service's SID state readable from both
   leaves.
4. For each supported service type, traffic between `srv6-client01` and `srv6-client02` passes
   through the service, and a capture on a fabric link shows SRv6 encapsulation carrying the
   service SID. Ready is not True before this holds at first activation.
5. Ready is never True while a per-node check fails; breaking one check on one leaf turns Ready
   False with a reason naming the node within the re-verification interval.
6. A service with a preferred spine forwards through that spine; disabling the preferred path
   moves traffic to the alternate with the loss bound the spec sets, and restoring it moves
   traffic back.
7. The phrasings "SRv6 L3VPN between ...", "EVPN over SRv6 across ...", "ip-vrf over SRv6 ..."
   and "mac-vrf over SRv6 ..." each produce the SRv6 service or a refusal naming SRv6; none
   produces a VXLAN construct.
8. A resource applied directly, without the tier, meets criteria 3 to 6. It carries no
   hand-typed locator or SID; the controller allocates them.
9. Every identifier on a service traces to a claim carrying the request's correlation id. After
   delete, no such claim remains and no state owned by the service remains on any node, while
   other services are untouched.
10. Re-applying an unchanged request produces zero device writes; manually removing a service's
    SID state on one leaf is repaired without operator action.
11. The chat page offers at least one runnable SRv6 example per supported type, and the status
    views list SRv6 services with type and Ready state.
12. On the container profile, a direct resource is refused with a capability reason and a chat
    request is refused before any identifier is claimed, naming the profile limitation.
13. The capability gate runs the encapsulation and SID-list checks on the SONiC VM profile; a
    check that cannot run is reported as skipped, never as passed.
14. Every acceptance proof is a capture produced by a command recorded next to it, taken on the
    live lab.

**Prerequisite spike (before planning).** By hand, on the SONiC VM lab, between `leaf01` and
`leaf02`: bring up the underlay and locators, then configure in turn an L3VPN over SRv6, a
routed EVPN service over SRv6, a bridged EVPN service over SRv6, and a preferred-spine path.
For each, record the exact device state that makes it work, the read-back that proves it, and
a capture of client traffic. The outcome fixes which service types the spec commits to.

**Questions left for `/speckit-clarify`.**
- Operator vocabulary: working default is an "over srv6" qualifier on `ip-vrf` and `mac-vrf`
  rather than a fifth construct; it must pass the vocabulary guard.
- How a preferred path is expressed by the operator and on the resource, and the loss bound for
  criterion 6.
- Whether the tier may read the site capability ConfigMap for the early refusal in criterion 12.
- Confirmation of the three working technical defaults (allocation split, SSH write path,
  rewrite of the placeholder renderers).

**Dependencies and related records.** Reconciliation candidates C1 and C2
(`specs/001-agentic-netops-sonic-evpn-fabric/reconciliation-2026-09-19.md:258-259`); 003's
closed construct vocabulary; the vocabulary guard test.

## Not verified

- No agent, test or lab command was executed apart from read-only `docker ps`. Mapper behavior
  was established by reading the code and replaying its regexes.
- Whether the supervisor's LLM classifier refuses SRv6 requests before the mapper sees them.
- Whether the running controllers currently fail on the sonic-vm lab as inferred in row 19; I
  did not query the cluster or the executor.
- Whether true gNMI Set works on the sonic-vm image (the gate does not test it).
- Whether SONiC 202505 with its FRR build can signal and forward an SRv6 VPN on either virtual
  platform.
- Whether gNMIc is configured to export the SRv6 metrics the dashboard queries.
- The proof logs under `gates/proofs/` are appended across runs, so I relied on the final lines
  and the report JSON timestamp (2026-10-11 14:56) to attribute them to the sonic-vm run.

## Addendum 2026-10-11: owner decision and lab topology

**Owner decision.** sonic-vm becomes the lab image and SRv6 must work on it. Entry points in
scope: natural-language request, UI, and direct `SRv6Service` CR. This supersedes
recommendation 1 under "Lab profile selection" (keep sonic-vs as default).

**The sonic-vm guest kernel does support seg6 (verified on the running lab, leaf01).**

- `SONiC.202505.1238524-ff3c0c9f6`, platform `x86_64-kvm_x86_64-r0`, `ASIC: vs`, kernel
  `6.1.0-29-2-amd64`.
- `/boot/config-6.1.0-29-2-amd64` has `CONFIG_LWTUNNEL=y`, `CONFIG_IPV6_SEG6_LWTUNNEL=y`,
  `CONFIG_IPV6_SEG6_HMAC=y`, `CONFIG_IPV6_SEG6_BPF=y`, `CONFIG_NET_VRF=m`.
- The gate's probe (`tests/integration/evpn_srv6_suite.sh:218-219`) installs its test route on
  `dev lo`. On the guest that command returns 0 but the kernel drops the encap, so the probe
  reads "no seg6" and the H.Encaps.Red and SID-list witnesses are skipped. The same route on
  `dev Loopback0` installs as `encap seg6 mode encap segs 1 [ fc00::1 ]`. The probe route was
  removed afterwards.
- `net.ipv6.conf.all.seg6_enabled = 0` and `net.ipv6.conf.all.forwarding = 1` on the guest.
- FRR answers `show segment-routing srv6 locator` with an empty table: the daemon supports SRv6
  and nothing is configured.

Because the ASIC is `vs`, the Linux kernel is the forwarding plane, so kernel seg6 is the SRv6
dataplane on this image. The "may not be achievable on this image" risk in the recommendation
is lower than stated; the recipe spike is still needed, since no SRv6 VPN has been signalled or
forwarded yet.

**Recommended topology setup.**

1. **One image per fabric: all four switches on sonic-vm.** Do not mix sonic-vs and sonic-vm
   nodes in one fabric. The two need different write transports (`docker exec` vs SSH into the
   guest, `tests/integration/lib/node_exec.sh:4-9`), different bootstrap and different
   persistence, so a mixed fabric doubles every code path for no SRv6 benefit.
2. **Keep `lab/topology.clab.yml` (sonic-vs) as a second, fast profile** for unit-level and
   non-SRv6 work on hosts without KVM. "Both images" means two selectable topologies, not two
   images in one fabric. SRv6 requests are refused there through the `cap.sai.srv6` capability
   (recommendations 2 and 3 above still apply).
3. **Flip the default** in the three places it is set: `scripts/provision.sh:15`,
   `scripts/lib/containerlab.sh:14-15`, `Makefile:71`. Do this only after items 4 and 5, or
   the four working constructs break on a default bring-up.
4. **Give every node its own identity at boot.** Every guest comes up as `Loopback0
   10.1.0.1/32`, AS 65100, router-id 10.1.0.1. The fabric needs per-node IPv4 and IPv6
   loopbacks, the ASNs already in the topology labels (65000 spines, 65101/65102 leaves),
   IPv6 addressing or unnumbered peering on the four fabric links, and underlay BGP for IPv4
   and IPv6 unicast. Deliver it as a per-node `config_db.json` (containerlab `startup-config`
   for the sonic-vm kind if the pinned vrnetlab build honours it, **not verified**; otherwise
   extend `init-sonic-bootstrap.sh`).
5. **Executor transport into the guest** (work item 2): without it nothing can be provisioned
   on sonic-vm at all, SRv6 or not.
6. **SRv6 base per node, owned by bootstrap, not by a service.** One locator per node from a
   common block (for example `fcbb:bbbb:<node>::/48`, uSID, matching the `uN`/`uDT46` rows the
   gate already writes), advertised in the IPv6 underlay; FRR `segment-routing srv6` locator;
   `seg6_enabled=1` on fabric interfaces; `net.vrf.strict_mode=1` for `End.DT46` **(kernel
   requirement, stated from general knowledge, to confirm in the spike)**. Services then only
   allocate a VRF and a per-service SID.
7. **Keep the links, clients and MTU as they are.** Two spines give two equal paths, which is
   what `tests/integration/srv6_failover_path_change.sh` needs. `srv6-client01/02` on
   `leaf01:eth4` / `leaf02:eth4` are the right attachment for an L3VPN test; the service puts
   those ports in the customer VRF. 9216 MTU leaves ample room for the SRv6 header.
8. **Fix the gate probe** to use a real interface so H.Encaps.Red and SID-list run on sonic-vm
   instead of being recorded as pass while skipped, then correct
   `lab/profiles/sonic-vm/README.md:20-22` and `TUTORIAL.md:258-261`.
9. **Fix the image pin** so topology, `versions.lock.yaml:99-100,162` and the compat list name
   the same digest, and make the `sonic-image` pin follow the active profile
   (`scripts/provision.sh:240`).

**Host fit.** Four VMs at 2 vCPU / 4 GB each (`lab/topology.sonic-vm.clab.yml` header) is
8 vCPU / 16 GB. The lab host has 22 cores and 93 GB and is running this topology now.

**Effect on the open questions.** Question 2 (acceptance profile) is answered: sonic-vm.
Client-to-client traffic is a realistic acceptance bar there, since the kernel dataplane is
present. Question 9 keeps its capability-based refusal, now for the sonic-vs profile.

## Owner decisions (2026-10-11)

| Open question | Decision |
| --- | --- |
| 1. Which service | Both L3VPN over SRv6 and EVPN over SRv6 |
| 2. Acceptance profile and bar | sonic-vm; client-to-client traffic is required, control-plane state alone is not enough |
| 3. API shape | Keep the separate `SRv6Service` CRD |
| 1 (detail). EVPN scope | Routed (Type-5) and bridged (MAC-VRF); the bridged service may be deferred if the spike shows the image cannot carry it |
| 8. Path steering | In scope: preferred and alternate spine, with failover |
| 10. UI | Chat with SRv6 example prompts plus SRv6 in the status views; no structured form |
| 11. Direct CR | The controller allocates locators, SIDs and VRFs from KUID; no hand-typed values |
| Entry points | Natural-language request, UI, and direct `SRv6Service` CR |
| Lab | sonic-vm is the lab image; sonic-vs stays as a second selectable topology |

Working defaults taken for the technical questions, to be confirmed in the spec's clarify step:

- **5. Allocation:** per-node locators owned by the lab bootstrap; per-service SIDs and VRFs
  claimed from KUID.
- **6. Write path on sonic-vm:** SSH into the guest (the path the gate already uses). gNMI Set
  stays out of scope until it is proven on this image.
- **7. Placeholder renderers and register entries:** rewrite against the tables the gate
  writes (`SRV6_MY_LOCATORS`, `SRV6_MY_SIDS`); delete what has no SONiC schema behind it.
- **4. Operator vocabulary:** an "over srv6" qualifier on `ip-vrf` and `mac-vrf`, not a fifth
  construct.

Path steering being in scope means the mapper's `tePolicy` refusal is lifted for the
preferred/alternate-spine case only, and the work list grows by one item (steering policy
render, verify and failover test; roughly L).

**Risk raised by decision 1 (from general knowledge, not verified on this image).** FRR's SRv6
VPN support covers L3 services (`End.DT4` / `End.DT6` / `End.DT46`, which the gate's `uDT46`
rows match). Layer-2 EVPN over SRv6 (MAC-VRF, route types 2 and 3 with `End.DT2U` /
`End.DT2M`) may not be implemented in the FRR shipped with SONiC 202505. The recipe spike must
answer this first, per service type, before the rest of the EVPN work is planned.
