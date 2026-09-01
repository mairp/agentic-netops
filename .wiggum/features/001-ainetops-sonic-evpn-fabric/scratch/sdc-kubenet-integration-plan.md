# Integration Plan (post-cycle-run): real SDC + KUID + NetworkDevice derivation + SRv6 application

Status: DESIGN (written during attempt-1, pass N, 2026-09-01 ~02:10 local, while the long
cycles job is still running — NO repo files changed this pass).
Execute ONLY after the long job finishes (it re-applies deploy/** and rebuilds Go source
mid-run). Then: implement workstreams A–F, re-verify gates, CYCLES_FORCE_RERUN=1, live
window, evidence.

## 0. Why (evidence from the in-flight run, gates/proofs/cycles/, started 2026-08-31T20:13:12Z)

- provision-{1,2,3,idem-1,idem-2}.log: `[qualify] OK`, provision exit=0 → capability gate
  PASSES for real on localhost:5000/sonic-vs-gnmi:202605 (re-pinned gNMI-enabled image).
- test-fabric-{1,2,3}.log: exit=1 in ALL cycles. Two distinct failure classes:
  1. cycle 1 (old fabric_verify.sh): OC path NotFound (openconfig-network-instance unmapped
     on this build — expected, documented in findings 4.2).
  2. cycles 2/3 (new fabric_verify.sh):
     a. `sonic-db query for BGP_NEIGHBOR did not answer` on ALL 4 nodes → gNMI get
        `--target CONFIG_DB --path /BGP_NEIGHBOR` returns a non-NotFound rpc error
        (QUERY_FAILED in sdb_body). Need the actual gNMI error text (live capture).
     b. `bgpd is not running` (pgrep -x bgpd) on spine01/spine02 ONLY; leaves PASS
        (session Established + L2VPN EVPN AF negotiated).
     BUT provision-3.log line 450 says `[fabric-bgp] underlay converged (all nodes
     Established)` — so either spine bgpd died between convergence and test (crash;
     check /var/log/frr + supervisor log live), or the convergence grep passed on a
     partial state. FIRST live debug task.
- Mid-run contamination: lab/profiles/sonic-vs/bootstrap/configure-fabric-bgp.sh was
  created/edited at Sep 1 00:58 (mtime) by the previous pass WHILE this run was in
  flight. Cycle-1/2 bootstrap never executed it (file absent/not -x at the time —
  provision-1.log has no `[clab] bootstrap: configuring underlay` line at all);
  cycle-3 + idempotence did. ⇒ the whole set must come from ONE consistent script
  version: CYCLES_FORCE_RERUN=1 after fixes.
- test-parity / test-observability / runtime-scan / off / off-noop: all exit=0 in every
  section so far (this run + prior verified runs).
- Root cause chain (pass-8 analysis, verified): upstream chain is dead.
  * deploy/kubenet/controllers.yaml: kubenet-controller@sha256:1111… (NO such upstream
    image exists — kubenet repo is pure YAML, 0 Go files on all branches).
  * deploy/kubenet/controllers.yaml: kuid-controller@sha256:2222… (fabricated; real image
    is ghcr.io/kuidio/kuid-server:v0.0.13, present locally).
  * deploy/sdc/components.yaml: sdc-schema/sdc-config/sdc-data/sdc-cache @aaaa…/bbbb…
    (fabricated; real SDC v0.0.58 topology is api-server + controller +
    data-server-controller StatefulSet, images present locally).
  * deploy/sdc/crds + seed/* use fabricated group sdc.sdcio.dev; real API is
    inv.sdcio.dev (native CRDs) + config.sdcio.dev (aggregated apiserver, Badger).
  * Provider (controllers/sonicprovider/controller.go:172-174) renders a 1-line
    placeholder spec (`/interfaces/interface` = Ethernet1), not the pkg/render pipeline.
  * pkg/sdc GroupVersion is sdc.sdcio.dev (fabricated).
  * controllers/srv6service/controller.go is status-only (100 lines, no SDC Config write).
  * Nobody derives NetworkDevice from Network ⇒ provider starves ⇒ no device config.

## 1. Workstream A — real SDC deployment (deploy/sdc/)

Source of truth: upstream/sdc/docs/installation.yaml (2842 lines, canonical docs.sdcio.dev
install) + upstream/config-server/artifacts/* + example/* (all fetched, in this feature dir).

A1. Rewrite deploy/sdc/crds/sdc-crds.yaml: extract the 8 inv.sdcio.dev CRDs verbatim from
    installation.yaml (lines: workspaces ~4, discoveryvendorprofiles ~189, subscriptions
    ~292, rollouts ~555, targetconnectionprofiles ~795, schemas ~960, targetsyncprofiles
    ~1230, discoveryrules ~1379). NO config.sdcio.dev CRDs (that group is aggregated).
A2. deploy/sdc/components.yaml → canonical 3-workload topology:
    * Deployment api-server (ghcr.io/sdcio/config-server-api-server:v0.0.58, port 6443,
      args --tls-cert-file=/apiserver.local.config/certificates/tls.crt
      --tls-private-key-file=…/tls.key --audit-log-path=- --secure-port=6443;
      volumes: api-server-certs (Secret api-server-cert, kubernetes.io/tls) +
      config-store (PVC pvc-config-store → /config); SA api-server; strategy Recreate).
    * Deployment controller (ghcr.io/sdcio/config-server-controller:v0.0.58; env
      POD_IP/POD_NAMESPACE/NODE_NAME/NODE_IP fieldRef; ENABLE_DISCOVERYRULE/
      ENABLE_CONFIGSET/ENABLE_WORKSPACE/ENABLE_ROLLOUT; SA controller; PVC workspace-store).
    * StatefulSet data-server-controller, 2 containers:
      controller (config-server-controller:v0.0.58, LOCAL_DATASERVER, REVERTIVE) +
      data-server (ghcr.io/sdcio/data-server:v0.0.72, config file from ConfigMap
      data-server: grpc-server{schema-server{enabled, schemas-directory: ./schemas},
      data-server{max-candidates:16}, max-recv-msg-size 24MB}, schema-store persistent
      /schemadb, cache local badgerdb /cached/caches, prometheus :56090); PVCs
      pvc-schema-db, pvc-schema-store, pvc-cache (sizes per installation.yaml).
    * APIService v1alpha1.config.sdcio.dev (groupPriorityMinimum 1000, versionPriority
      15, service api-server:6443, caBundle=<generated CA>, insecureSkipTLSVerify false).
    * Services per installation.yaml (api-server, sdc-controller metrics 8443/9443,
      data-server 56000 …).
    * RBAC: ClusterRoles/Bindings (api-server, controller, data-server-controller) +
      namespaced Roles/Bindings + ServiceAccounts, from installation.yaml ~2591-2842.
    * Secrets: api-server-cert (kubernetes.io/tls) GENERATED at provision time (new
      scripts/lib/sdc_api_certs.sh: openssl CA + serving cert for
      api-server.sdc-system.svc[.cluster.local], deterministic, lab-only, no static
      certs in git — matches FR-015 posture); sdc-controller-token (SA token, K8s ≥1.24
      bound SA token or legacy token per cluster).
A3. Rewrite deploy/sdc/seed/* to real API shapes:
    * Schema inv.sdcio.dev/v1alpha1 (provider sonic.sdcio.dev, version <image tag>,
      repositories[] — see Workstream F).
    * TargetConnectionProfile inv.sdcio.dev: {port: 8080, protocol: gnmi,
      encoding: JSON_IETF, skipVerify: false, insecure: false} (v0.0.58 has NO CA
      field on the profile; per-target TLS comes from Target.spec.tlsSecret — see A4).
    * TargetSyncProfile inv.sdcio.dev: {buffer: 0, workers: 10, validate: true,
      sync: [{name: config, protocol: gnmi, paths: ["/"], mode: get, encoding:
      JSON_IETF, interval: 30s}]} (keep T063 decision: SDC does NOT subscribe for
      metrics; gNMIc is the sole metric collector — interval get for drift is fine).
    * DiscoveryRule inv.sdcio.dev: addresses 172.31.0.{11,12,21,22} hostName
      spine01/spine02/leaf01/leaf02, discoveryProfile.connectionProfiles [gnmi-sonic],
      targetConnectionProfiles [{connectionProfile: gnmi-sonic, syncProfile:
      sync-sonic, credentials: <profile name>}], targetTemplate labels.
      NOTE: the "credentials" field references a DiscoveryVendorProfile name — decide:
      create a minimal DiscoveryVendorProfile for sonic (gnmi discovery response
      parsing: organization sonic, modelMatch sonic-*, paths for DEVICE_METADATA/
      LOOPBACK_INTERFACE) or omit credentials if optional in v0.0.58 (check CRD
      required list before coding).
    * DELETE the fabricated Config-as-connection-profile entries (sonic-conn-profile /
      sonic-sync-profile as config.sdcio.dev Config kind with type: ConnectionProfile —
      wrong shape).
A4. Targets are created by SDC's discovery (Target kind in config.sdcio.dev, fields
    provider/address/credentials/tlsSecret/connectionProfile/syncProfile). Provision must
    wait for 4 Targets to appear + become Ready; Target.spec.tlsSecret = K8s Secret with
    the lab CA (so SDC validates the device self-signed cert — real TLS validation,
    FR-015). If discovery proves flaky, fallback: create Targets directly via the
    aggregated API (same kind) with deterministic names — provision stays idempotent.
A5. versions.lock.yaml: sdc block → real pins by digest (verified locally, pass-8 J):
    config-server-api-server:v0.0.58 @ sha256:bd5d312512ad…4041f9e;
    config-server-controller:v0.0.58 @ 01c69c589137…1ffea13;
    data-server:v0.0.72 @ f294c2b3810d…bd95dca0.
    Decide fate of schema-server:v0.0.34 / cache:v0.0.38 pins (canonical install does NOT
    deploy them standalone — they are embedded in data-server). Keep in lock as
    "provenance/standalone-fallback" with a comment, or drop + update
    scripts/lib/verify_pins.sh in the same commit (it reads those blocks).
A6. provision.sh SDC section: apply crds → components (with cert gen) → wait pods Ready →
    seed. Replace deploy/sdc/install.sh contents accordingly (it is invoked by
    provision.sh:86-87).

## 2. Workstream B — real KUID deployment

B1. deploy/kubenet/controllers.yaml: DELETE fabricated kubenet-controller Deployment
    (no upstream exists — document in deploy/kubenet/README.md that the AINETOPS provider
    owns Network→NetworkDevice derivation because pinned Kubenet v0.0.1 is pure intent
    YAML). Replace kuid-controller with real ghcr.io/kuidio/kuid-server:v0.0.13
    Deployment (pinned digest d6fdae78cc5b…0800608; entrypoint /app/kuid-server —
    verify args with `docker run --rm … --help` during implementation; KUID reconcilers
    are asclaim/asindex/genidclaim/genidindex/ipclaim/ipindex/extcomm — it does NOT
    derive NetworkDevice).
B2. Keep deploy/kubenet/crds/kubenet-crds.yaml (our stable, versioned Network/
    NetworkConfig/Topology/NetworkDevice CRDs — group network.kubenet.dev/v1alpha1;
    api_shape pinned in versions.lock.yaml) and deploy/kuid/crds (id.kuid.dev).
B3. Keep deploy/kubenet/{claims,srv6-pools,topology,topology-and-indices,networks/*}.yaml
    (already applied fine per provision logs: "unchanged" everywhere).
B4. provision.sh: wait for kuid-server Ready; assert claim/index resources exist
    (they already do per provision-*.log).

## 3. Workstream C — provider: NetworkDevice derivation + full render + real SDC API

C1. NEW derivation (controllers/sonicprovider/derive.go or new reconciler):
    watch network.kubenet.dev/v1alpha1 Network + Topology; for each network, compute
    per-device spec for every node in the topology (spine01/spine02/leaf01/leaf02):
    loopbacks (from underlay.loopbacks pools + KUID claims), /31 link addresses
    (underlay.linkAddresses pools + claims), BGP global/neighbors (asnPool), EVPN AF,
    VTEP (attachments vtep: true → leaves), tenant network instances (bridges/VRFs/L2VNI/
    L3VNI/RD/RT from the 4 tenant Network manifests), SRv6 locators/MySIDs (srv6-pools
    claims). Emit NetworkDevice objects: name <network>-<node>, ns kubenet-system (or
    network's ns), label network.kubenet.dev/derived=true (existing watch predicate in
    controller.go:258-270), annotations = compatibility set (copyCompatAnnotations keys,
    controller.go:273-287), deterministic ordering/hashing (Rule 2). Idempotent: no spec
    write when canonical hash unchanged.
    NOTE: derive must consume the SAME pools/claims the tenants use so that
    fabric_verify.sh expectations (VRF vrf-a, L2VNI 100, etc.) match. Map each tenant
    manifest field to device paths explicitly; reject unknown fields (T057 already
    implements translation validation — reuse pkg/migration where shapes match).
C2. FULL render in Reconcile: replace controller.go:172-174 placeholder with the real
    pipeline: NetworkDevice.spec → pkg/model structs → pkg/render.{RenderInterfaces,
    RenderBGP, RenderNetworkInstances, RenderL3VNI, RenderEVPNType5, RenderIRB,
    RenderSRv6Behaviors, RenderSIDList, RenderSRPolicy} → compose ordered tree →
    render.CanonicalHash → sdc.Config. Keep T036 offline validation + register guard
    (sdc.OfflineValidate/ValidateSpecAgainstRegister) on the composed tree.
C3. pkg/sdc conformance (types.go, offline.go, validate.go):
    * GroupVersion → config.sdcio.dev/v1alpha1.
    * Config.Spec → {priority int, revertive bool, config []{path string, value any}}
      (real shape per upstream example/config/config.yaml: single entry path "/" with
      JSON_IETF tree, or per-path entries — pick per-path entries for scoped ownership
      (contract Rule 4) and verify SDC accepts; example uses "/").
    * Config labels config.sdcio.dev/targetName + config.sdcio.dev/targetNamespace
      (ownedConfigName → per device, e.g. nd-leaf01 → targetName leaf01, ns default or
      sdc-system — match where Targets live).
    * Status: real Config status fields — CHECK config-server.md §303+ for condition
      names (Ready/conditions, per-path status, deviations) before coding; update
      controller.go:123-170,218-235 status reads to the real fields (keep T038
      Degraded propagation semantics).
    * Keep Target stub only if needed (Target now lives in config.sdcio.dev too).
C4. Tests: update unit/golden/envtest to the new shapes (go test ./... RC=0 is a gate);
    keep envtest (assets at /root/.local/share/kubebuilder-envtest/1.29.4-linux-amd64)
    covering SRv6Service CRD + finalization with the new SDC types.
C5. deploy/ainetops provider manifests: RBAC for the provider SA must gain:
    network.kubenet.dev (get/list/watch/create/update/patch on networks, networkdevices,
    topologies), id.kuid.dev (get/list/watch on indices/claims), config.sdcio.dev
    (get/list/watch/create/update/patch/delete on configs, targets), inv.sdcio.dev
    (get/list/watch on targetschemas/profiles) + events. (T073: keep verbs minimal,
    no cluster-admin.)

## 4. Workstream D — underlay bootstrap fixes (configure-fabric-bgp.sh + fabric_verify)

D1. LIVE DEBUG (first task, in a fresh single provision, lab left up):
    * On spine01: `supervisorctl tail -f bgpd` / `/var/log/frr/bgpd.log` or syslog to
      capture WHY bgpd is gone at test time (crash after convergence vs never started).
    * Capture the real gNMI error for `gnmic --target CONFIG_DB get --path /BGP_NEIGHBOR`
      (sdb_body returns QUERY_FAILED, not ABSENT): full rpc error text → decide fix:
      - if the telemetry build's CONFIG_DB origin maps only a subset of tables: adjust
        fabric_verify to read BGP_NEIGHBOR via `docker exec redis-cli -n 4 keys`
        (still a real device-state check; document the gNMI-origin limitation as a
        finding — do NOT weaken to "no check").
      - if the path syntax is wrong for this build: fix the query (test the exact
        working path against the device, e.g. /CONFIG_DB/BGP_NEIGHBOR vs /BGP_NEIGHBOR
        with --target CONFIG_DB).
    * Verify leaves keep passing; confirm EVPN AF + RIB assertions (Type-2/3/5) with the
      fixed checks.
D2. Make configure-fabric-bgp.sh robust: surface `supervisorctl start bgpd` failures
    (currently `|| true` hides them), add a bgpd-alive assertion at the END of main()
    (pgrep per node) so provision fails loudly instead of converging-on-paper, and keep
    the script idempotent for the idempotence cycles (it already is: guarded adds).
D3. Keep the two-layer design (FRR runtime + CONFIG_DB intent) — it is correct for this
    image (no bgpcfgd); document in lab/profiles/sonic-vs/bootstrap/README.md.

## 5. Workstream E — SRv6Service application (controllers/srv6service/)

E1. Extend the SRv6 reconciler beyond status: on Ready dependencies (topology + KUID
    locator/SID claims + targets + schema compat), render the SRv6 device intent per
    headend/transit/endpoint from SRv6Service spec + claims:
    * leaf01 (headend): VRF vrf-a, SRV6 SID_LIST, SR Policy / SID steering,
      H.Encaps.Red for the /128 endpoint prefix (paths per tests/integration/
      srv6_capture_counters.sh expectations: SID_LIST, SRV6_COUNTERS, VRF vrf-a on
      leaf01/leaf02).
    * leaf02 (endpoint): End.DT46 MySID + VRF binding.
    * spines: transit End (if the service marks them transit) — match the test's
      expected node roles.
E2. Apply via the SAME real SDC Config mechanism as C3 (scoped sonic-srv6 paths,
    deterministic, hash-annotated, finalizer-ordered deletion T040).
E3. Status: Ready only when SDC reports applied (per-device operations confirmed —
    Rule 5); Degraded on partial; never claim Ready on status-only (the current
    10s requeue loop must end in either an apply attempt or an explicit
    DependenciesNotReady with a concrete missing dependency).
E4. Update tests/unit + envtest for the new behavior; golden output for the rendered
    SRv6 tree (deterministic, Rule 2).

## 6. Workstream F — SDC schema (SONiC YANG) for real validation

F1. Options, in preference order:
    a. Schema CR repositories[] → github.com/sdcio/sonic-schema branch/tag matching the
       pinned image era (20220111 community base). Validate: diff the repo's
       sonic-srv6.yang/sonic-bgp-*.yang against the image's /usr/local/yang-models
       (extract via docker create+cp from the pinned image — read-only check) for the
       paths the provider renders. Cluster nodes need outbound HTTPS to github
       (host has network; kind NATs through host — verify with a curl probe from a pod).
    b. If the repo drifts from the image: build a git bundle of the IMAGE'S OWN
       /usr/local/yang-models (extract once, `git init`, commit, serve via file:// is
       NOT possible cross-container → host the bundle in the local registry as a
       config tarball OR kubectl cp the models into the shared schema PVC at
       <schemaBasePath>/sonic.sdcio.dev/<version>/ after the data-server-controller
       pod starts, then create the Schema CR with repositories[] empty if v0.0.58
       allows an already-loaded dir (check schema reconciler: it skips Load when the
       dir exists — "calls schemaLoader.GetRef() to check whether the YANG directory
       already exists on the shared PVC. If it does not… Load")). Option b keeps the
       schema EXACTLY equal to the pinned image (stronger claim for SC-013).
F2. Record the chosen source + digest in versions.lock.yaml (sonic_yang block) and in
    the compatibility set annotations (T029 five-part set).

## 7. Execution order + gates (each step verified before the next)

1. (job done) Snapshot the final consistent cycle set; grep exit codes; keep as
   "run N-1" reference (do not cite — contaminated by mid-run edits; used only for
   regression comparison).
2. D1 live debug in a throwaway provision (single, then off.sh). Capture: bgpd death
   cause, BGP_NEIGHBOR gNMI error, working CONFIG_DB read path.
3. A (SDC manifests + certs + pins) → make verify-pins green → kubectl server-side
   dry-run all new manifests (validate_crds.sh) → single live provision → SDC pods
   3/3-2/2 Running + 4 Targets discovered + Schema loaded (data-server logs).
4. C (Go: derivation + render wiring + pkg/sdc conformance) → go build + go test ./...
   RC=0 (unit/golden/envtest/sdc-validation selectors) → live provision → provider
   derives NetworkDevices → renders → SDC Configs appear (config.sdcio.dev) → devices
   receive underlay/tenant config via SDC (verify with fabric_verify-style probes).
   NOTE: if SDC end-to-end apply works, underlay may then flow through the control
   plane; keep configure-fabric-bgp.sh as bootstrap safety net ONLY if still needed
   (spec: bootstrap limited to management/TLS per T010 — decide then: if SDC delivers
   the underlay, trim D-script to TLS-only + daemons; document the change).
5. B (KUID real deployment) — can run in parallel with 3/4 (independent ns).
6. E (SRv6 application) → srv6_capture_counters.sh + srv6_failover_path_change.sh
   green in the live window.
7. F as needed by 3/4 (schema must load BEFORE SDC validates Configs).
8. Full re-verify: ./scripts/ci/run_suites.sh (strict; all suites real),
   scripts/lib/assert_crds.sh standalone, make verify-pins, make acceptance
   (denylist+supply-chain+security-audit — security-audit.sh must be extended for the
   new SDC manifests: RBAC verbs, cert generation, tlsSecret usage, no static certs).
9. CYCLES_FORCE_RERUN=1 ./tests/integration/cycles_runner.sh (background; ~90-150 min)
   — expect provision exit=0 AND test-fabric exit=0 all cycles, off sections exit=0,
   conformance section: sonic-vm image still absent → document designed fail-closed
   outcome (honest; SC-013 conformance is met via the gNMI-enabled sonic-vs-gnmi
   profile per spec Assumptions "sonic-vm or another pinned SONiC profile that passes
   the unchanged gate" — the re-pinned profile IS the conformance target; state this
   explicitly in evidence).
10. LIVE WINDOW after final cycles (lab up): run_suites.sh, assert_crds.sh,
    denylist_runtime_scan.sh, off.sh + no-op.
11. Stage line-numbered proof slices for every cited file/symbol; write
    gates/GATE8-EVIDENCE.md atomically (.tmp + mv): per-task T073–T080, per-SC
    SC-001..SC-016, final checkpoint statement matching cited logs EXACTLY.

## 8. Risks / fallbacks (honest, no faking)

- Aggregated APIService + Badger in Kind: if the api-server pod fails (certs,
  WatchListClient feature gate), fallback = pin a slightly different sdcio release
  whose install is simpler; last resort = document exact blocker with pod logs and
  keep the fail-closed evidence for SC-001/008 (critic requires real conformance for
  SC-002/003/013 — those flow through gNMI+device state, which the D/E workstreams
  deliver even if SDC stays partial; but the spec's control path requires SDC, so
  exhaust the SDC path first).
- KUID v0.0.13 arg surface: verify --help in a throwaway run; if it refuses our
  claims/indices shapes, pin the exact resources it manages (its reconciler list is
  known: asclaim/asindex/genidclaim/genidindex/ipclaim/ipindex/extcomm).
- SDC Schema load from github needs cluster egress; if blocked, option F1.b (image's
  own models via PVC seed).
- Mid-run edits are FORBIDDEN while any cycles run is in flight (this pass's
  constraint that caused the contaminated set).
- Do NOT mock gNMI or fabricate readiness (spec checklist: release acceptance cannot
  mock/substitute).

## 9. Verified-facts ledger for this pass (read-only, no repo changes)

- provider controller.go:172-174 placeholder render; :258-270 derived-label predicate;
  :273-287 compat annotation keys; :303 ownedConfigName "nd-<owner>".
- pkg/sdc/types.go:13 GroupVersion sdc.sdcio.dev (fabricated); Config.Spec map+
  $policy (BuildPolicy:53-60).
- pkg/kubenet/types.go:15 network.kubenet.dev/v1alpha1, NetworkDevice loose type.
- deploy/sdc/components.yaml: 4 fabricated Deployments @aaaa/…/dddd digests.
- deploy/kubenet/controllers.yaml:28,73 fabricated 1111/2222 digests.
- deploy/sdc/seed/{sonic-schema,discovery-rule}.yaml: fabricated sdc.sdcio.dev shapes
  (Schema with image:, Config-as-ConnectionProfile with port 9339 — real gNMI port is
  8080).
- bootstrap: init-sonic-bootstrap.sh (TLS+creds+sshd+telemetry, 88 lines, solid);
  configure-fabric-bgp.sh (209 lines: daemons, interfaces, FRR vtysh BGP/EVPN,
  VXLAN_TUNNEL_MAP on leaves, CONFIG_DB intent via GCU, convergence loop; created
  Sep 1 00:58 mid-run).
- upstream SDC facts (installation.yaml + config-server.md + data-server.md):
  topology, CRD groups, Config{priority,config[]{path,value}}, Target{tlsSecret,
  connectionProfile,syncProfile}, TargetConnectionProfile fields (port/protocol/
  encoding/skipVerify/insecure — NO CA field), Schema{provider,version,
  repositories[]}, schema reconciler skips Load when PVC dir exists, data-server
  embeds schema-server+cache, APIService caBundle required, api-server-cert Secret
  empty in docs (user-generated), upstream apiservice.yaml carries a sample caBundle.
- Local image digests (pass-8 J, re-verify with `docker images --digests` before pin):
  config-server-api-server:v0.0.58, config-server-controller:v0.0.58,
  data-server:v0.0.72, kuid-server:v0.0.13, schema-server:v0.0.34, cache:v0.0.38.
