# Feature Specification: agentic-netops on a Nokia SR Linux EVPN/VXLAN fabric

**Feature Branch**: `001-agentic-netops-srlinux-evpn-fabric`
**Created**: 2026-09-13
**Status**: Ready for implementation
**Input**: "Make the Nokia SR Linux version of agentic-netops instead of SONiC.
Only the NOS changes; everything else stays the same. Success criteria: a
recorded walkthrough like the one in the original repository, produced on the
operator's host through the wiggum orchestrator."

## Context

`mairp/agentic-netops` is an autonomous intent-to-fabric system: an operator
types plain language into a console, an AGNTCY multi-agent tier (supervisor,
mapper, allocator, deployer over A2A/SLIM) decomposes it, allocates identifiers
through kuid and submits a kubenet `Network`; a Kubernetes controller renders
the `Network` onto a live EVPN/VXLAN fabric through a fabric-executor and keeps
it converged. The original fabric is SONiC (sonic-vs) and its southbound is
`docker exec` + CONFIG_DB + FRR because gNMI Set was broken on that image.

This feature re-targets the fabric to **Nokia SR Linux** (`ghcr.io/nokia/srlinux`,
containerlab `nokia_srlinux`), where gNMI Set/Get/Subscribe are native and
first-class. The architecture, the intent tier, the CRDs, the operator console
and the observability stack are unchanged. SRv6 is out of scope on this target
(the SR Linux container has no SRv6 data plane) and is declared as such.

## User Scenarios & Testing *(mandatory)*

### User Story 1 - Bring up the SR Linux lab and qualify it (Priority: P1)

An operator runs `./scripts/provision.sh --profile srlinux --cluster-name agentic-netops`
on a Linux host with Docker, kind and containerlab. The script deploys two
spines, two leaves (SR Linux) and four Linux clients, boots the underlay
(dual-stack eBGP) and overlay (EVPN/VXLAN over iBGP with spine route
reflectors) from startup configuration, installs the Kubernetes control plane
and controllers, and runs the capability gate over gNMI.

**Why this priority**: nothing else can be demonstrated without a converged fabric.

**Independent Test**: `make lab-qualify` passes; `./tests/integration/fabric_verify.sh`
prints Established sessions on all four nodes, EVPN Type-2/3/5 routes on both
leaves, at least one remote VTEP on the bootstrap L2VNI, client01↔client02
reachability across the overlay, and no tenant state on spines.

**Acceptance Scenarios**:

1. **Given** a clean host, **When** provision runs, **Then** every SR Linux node
   answers gNMI Capabilities on 172.31.0.x:57400 with TLS and the generated credentials.
2. **Given** the lab is up, **When** `fabric_verify.sh run` executes, **Then** it
   exits 0 with every assertion line printed as passed.
3. **Given** the lab is up, **When** a node container is restarted, **Then** its
   configuration persists and the fabric re-converges without operator action.

---

### User Story 2 - Provision the four constructs from plain language (Priority: P1)

The operator types "Provision a vlan 130 on leaf01 ethernet1 for tenant acme",
confirms the mapper's interpretation and the allocator's identifiers, and the
deployer reports `Deployed`. The same for an ip-vrf ("Deploy an ip-vrf between
leaf01 wan1 and leaf02 wan1 for tenant initech with prefix 10.50.0.0/24"), a
mac-vrf ("Extend vlan150 as a mac-vrf across leaf01 ethernet1 and leaf02
ethernet1 for tenant blue") and an acl.

**Why this priority**: this is the product; the walkthrough video records exactly this.

**Independent Test**: for each construct the kubenet `Network` reaches
`Ready=True` with reason `ApplySucceeded`, and `sr_cli` on leaf01 shows the
network-instance / subinterface / vxlan-interface / EVPN state the construct
declares.

**Acceptance Scenarios**:

1. **Given** the intent tier is installed, **When** the vlan prompt is confirmed
   twice, **Then** `Network` `Ready=True` and `show network-instance vlan-130`
   lists `ethernet-1/3.130` up on leaf01.
2. **Given** the same, **When** the ip-vrf prompt is confirmed, **Then** an ip-vrf
   network-instance exists on both leaves with an L3 VXLAN interface, and a
   Type-5 route for 10.50.0.0/24 is originated (visible in the EVPN RIB).
3. **Given** the same, **When** the mac-vrf prompt is confirmed, **Then** the
   mac-vrf exists on both leaves with `vxlan1.<l2vni>`, and each leaf lists the
   other as a multicast destination (remote VTEP) for that VNI.
4. **Given** the same, **When** the acl prompt is confirmed, **Then** an
   `acl-filter` with the declared entries is bound on the attachment subinterface.
5. **Given** a converged service, **When** its network-instance is deleted by
   hand on the node, **Then** within one resync (5 min) the controller re-applies
   it and `Ready` reflects the repair.
6. **Given** a prompt naming a port the site does not have, **When** submitted,
   **Then** the translator refuses it before anything is submitted, listing the
   site's real ports.

---

### User Story 3 - Observe the fabric (Priority: P2)

Grafana shows live interface counters, oper-state and BGP session state for
the four SR Linux nodes, collected by gnmic subscriptions and scraped by Prometheus.

**Independent Test**: `curl gnmic:9273/metrics` inside the cluster returns
SR Linux interface and BGP series for all four targets; the "Fabric telemetry"
dashboard renders non-empty panels.

---

### User Story 4 - Record the walkthrough (Priority: P2)

The recording driver (`testautomation/video/record.py`) drives the console and
a web terminal on a virtual display, provisions at least three constructs from
the sanctioned prompt list, proves each with `kubectl` and `sr_cli` on leaf01,
and `accept.py` validates `final.mp4` (1920x1080) and writes `evidence.json`.

**Independent Test**: `accept.py --take final` prints no `FAIL` line and
`evidence.json` has `"accept_pass": true`.

---

### Edge Cases

- A `Network` whose l3vni is outside the kuid band derives no subinterface tag → rendering refuses with a named error (same as today).
- Two services on the same attachment port: each gets its own single-tagged subinterface; no "PVID stealing" class of defect exists on SR Linux.
- An RT without the `target:` prefix (allocator emits `65000:N`) is normalised by the renderer; an RD without prefix stays `ASN:N`.
- The SR Linux gNMI server rejects a Set → the executor returns the node's error text verbatim in `Ready=False/ApplyFailed`.
- A node reboot loses unsaved config → the executor saves after every successful apply, and the 5-minute resync repairs residual drift.
- SRv6Service objects exist in the API but the site capability is `false` → they report `Ready=False` with `CapabilityMissing`, never a fake success.

## Requirements *(mandatory)*

### Functional Requirements

- **FR-001**: The lab MUST run on `ghcr.io/nokia/srlinux` pinned by immutable digest in `versions.lock.yaml` and `lab/topology.clab.yml` (kind `nokia_srlinux`, type `ixrd2l`).
- **FR-002**: The topology MUST keep two spines, two leaves, four Linux clients, the management subnet 172.31.0.0/16 with the same per-node management IPs, and jumbo MTU 9216 on fabric links.
- **FR-003**: Underlay MUST be dual-stack eBGP (spines AS 65000, leaf01 AS 65101, leaf02 AS 65102) over /31 + /127 point-to-point links with the original addressing; overlay MUST be EVPN over iBGP (AS 65535) between system0 loopbacks with spines as route reflectors; leaves MUST carry a bootstrap mac-vrf (L2VNI 100, clients untagged on ethernet-1/3) and a bootstrap ip-vrf (VrfBlue, L3VNI 2000) that originates Type-5 routes, delivered as containerlab startup configuration.
- **FR-004**: `scripts/provision.sh` MUST keep its phase order and flags; profile name becomes `srlinux`; the bootstrap step creates the generated gNMI user on every node and publishes the containerlab CA into the `gnmi-lab-tls` Secret.
- **FR-005**: `scripts/lib/qualify.sh` MUST gate on gNMI Capabilities/Get/Set/Subscribe with content assertions, persistence across a container restart, and EVPN Type-2/3/5; SRv6 entries MUST be reported `not-applicable` with the documented reason, never `pass`.
- **FR-006**: `pkg/fabricplan` MUST render every construct (vlan, mac-vrf, ip-vrf, symmetric IRB, acl) into gNMI Set ops (JSON-IETF updates/deletes against SR Linux native paths), per-node verification checks (gNMI Get assertions) and rollback ops, deterministically and idempotently.
- **FR-007**: `cmd/fabric-executor` MUST keep its HTTP API (`/v1/nodes`, `/v1/node/apply`, `/v1/node/verify`) and node-map contract, and execute ops as gNMI Set and checks as gNMI Get over TLS with the lab credentials; it MUST NOT use the docker socket. After a successful apply sequence it MUST persist the configuration.
- **FR-008**: The provider controller MUST keep its reconcile contract (finalizer, apply → verify → `Ready`, 5-minute resync, best-effort rollback on delete); package and binary names change from `sonicprovider`/`sonic-provider` to `srlprovider`/`srlinux-provider`.
- **FR-009**: The site compatibility pins MUST carry the SR Linux image, its YANG model version and `cap-sai-srv6=false`; `Network` reconciliation MUST NOT require SRv6 capability.
- **FR-010**: gnmic MUST subscribe to SR Linux state paths (interface statistics and oper-state, BGP neighbor session state, platform CPU/memory) and expose them to Prometheus; the Grafana dashboards MUST query the resulting series.
- **FR-011**: `tests/integration/fabric_verify.sh` and the gNMI suites MUST read state over gNMI (and `sr_cli` where a show command is the honest source), with content assertions.
- **FR-012**: The intent tier MUST keep the construct vocabulary, the kuid pools (L3VNI 10000–14094 retained: the ip-vrf attachment subinterface tag is derived from the L3VNI), the two-confirmation flow and the deployer transaction; operator-facing text MUST say "SR Linux fabric".
- **FR-013**: The supply-chain policy MUST invert: SONiC artifacts are forbidden in runtime manifests and the dependency graph.
- **FR-014**: `testautomation/video/record.py` and `accept.py` MUST prove constructs with `sr_cli` show commands (read-only) instead of redis/vtysh and keep the 1920x1080 silent-recording contract.
- **FR-015**: README, TUTORIAL and docs MUST describe the SR Linux lab; SONiC-specific findings documents are kept under `docs/legacy/` for provenance.
- **FR-016**: No credential literal in manifests; the SR Linux default password is only used once, to create the generated user, and never stored.

### Key Entities

- **Network** (kubenet `network.kubenet.dev/v1alpha1`): unchanged intent schema (routers, bridgeDomains, vlans, attachments, accessLists).
- **Plan / NodePlan / Op / Check** (`pkg/fabricplan`): device work order; `Op` becomes a gNMI Set (updates + deletes), `Check` a gNMI Get assertion.
- **Site port map**: logical attachment → SR Linux interface (`ethernet1..3` → `ethernet-1/3`, `wan1` → `ethernet-1/4`).
- **Site pins ConfigMap** (`fabric-compat-pins`): image, yang, capability flags.

## Success Criteria *(mandatory)*

- **SC-001**: `make verify-compat`, `go test ./tests/unit ./pkg/...`, `uv run pytest` (agents), `npm run build` (ui) and `scripts/ci/supply_chain.sh` pass in CI.
- **SC-002**: `provision.sh --profile srlinux --with-intent-tier` completes on the host with `[qualify] OK` and `fabric_verify.sh` exit 0.
- **SC-003**: Each of vlan, mac-vrf, ip-vrf and acl reaches `Ready=True` from a console prompt, with per-node gNMI verification recorded in the controller events.
- **SC-004**: A recorded `final.mp4` (1920x1080, silent, no cuts) shows at least three constructs deployed and proven, and `accept.py` writes `evidence.json` with `accept_pass: true`.
- **SC-005**: The intent tier still has no network route to the devices (only the executor in the system tier does).

## Out of scope

- SRv6 services on SR Linux (the `SRv6Service` CRD and controller remain in the tree and report `CapabilityMissing`).
- Multi-vendor fabrics, hardware platforms, licensing of non-public images.
