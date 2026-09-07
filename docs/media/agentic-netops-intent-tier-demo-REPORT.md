# REPORT — agentic-netops intent-tier demo recording

## Prompts used (exact wording typed into the console)

| prompt id | wording |
|---|---|
| A | `Provision a vlan 130 on leaf01 ethernet1 for tenant acme` |
| B | `Deploy an ip-vrf between leaf01 wan1 and leaf02 wan1 for tenant initech with prefix 10.50.0.0/24` |
| C1 | `Extend vlan150 as a mac-vrf across leaf01 ethernet1 and leaf02 ethernet1 for tenant blue` |

One request per thread; `Clear conversation` clicked between prompts. Networks:
`migr-831516cde2a8455` (A), `migr-a655920e72cc411` (B), `migr-c7d4dd748f0b436` (C1).

## Enter → Deployed per prompt

| prompt | seconds | console outcome card |
|---|---|---|
| A | 619.5 | `Deployed — 1 resource verified Ready on the fabric.` |
| B | 571.3 | `Deployed — 1 resource verified Ready on the fabric.` |
| C1 | 638.6 | `Deployed — 1 resource verified Ready on the fabric.` |

## Final video duration

`ffprobe -v error -show_entries format=duration -of csv=p=0 agentic-netops-intent-tier-demo.mp4` →
**2199.066667 s** (~36 min 39 s), 1920x1080, decodes, `agentic-netops-intent-tier-demo.mp4` is the only
`.mp4` in the output directory.

## Router proof outputs (verbatim, as captured in the take)

**A — vlan 130**

```
$ kubectl -n agentic-netops-intent get networks.network.kubenet.dev \
    -l agentic-netops.io/correlation-id=107850917f144efdbafea433c54d1b51 \
    -o custom-columns=NAME:.metadata.name,TYPE:'...service-type',READY:'...Ready...status',REASON:'...Ready...reason'
NAME                   TYPE   READY   REASON
migr-831516cde2a8455   vlan   True    ApplySucceeded

$ docker exec clab-agentic-netops-fabric-leaf01 redis-cli -n 4 hgetall 'VLAN|Vlan130'
vlanid
130

$ docker exec clab-agentic-netops-fabric-leaf01 bridge vlan show dev eth3
port              vlan-id
eth3              100
                  110
                  112
                  117
                  118 PVID Egress Untagged
                  119
                  120
                  130      <-- new
                  131
                  140
                  151
                  160
                  300
```

**B — ip-vrf 10.50.0.0/24** (spec: vrf-a655920e72cc411, l3vni 10050, rd 65000:43)

```
$ docker exec clab-agentic-netops-fabric-leaf01 redis-cli -n 4 keys 'VRF|*'   (new key vs pre-prompt snapshot)
VRF|Vrf-a655920e72

$ docker exec clab-agentic-netops-fabric-leaf01 vtysh -c 'show evpn vni'      (grep Tenant VRF)
10050      L3   vtep1-4050            0        0        n/a             Vrf-a655920e72

$ docker exec clab-agentic-netops-fabric-leaf01 vtysh -c 'show bgp l2vpn evpn route type prefix'
Route Distinguisher: 65000:43
 *>  [5]:[0]:[24]:[10.50.0.0]
                    10.0.0.21                0         32768 65000 ?
                    ET:8 RT:65000:43 RT:65101:10050 Rmac:02:42:ac:1f:00:15
```

(The on-screen terminal command pipes through `| head -40`, which shows the
10.50.0.0 Type-5 entry under an earlier RD only; the full table above — with
B's own RD 65000:43 carrying RT:65000:43 and l3vni 10050 — was re-collected
live from leaf01 into `agentic-netops-intent-tier-demo-evidence.json` by `accept.py`.)

**C1 — mac-vrf vlan 150** (vni 10051, one tunnel map, both leaves)

```
$ docker exec clab-agentic-netops-fabric-leaf01 redis-cli -n 4 keys 'VXLAN_TUNNEL_MAP|vtep1|map_*_Vlan150'
VXLAN_TUNNEL_MAP|vtep1|map_10051_Vlan150        (exactly one, new)

$ docker exec clab-agentic-netops-fabric-leaf01 vtysh -c 'show evpn vni'
10051      L2   vtep1-150             0        0        1               default

$ docker exec clab-agentic-netops-fabric-leaf02 vtysh -c 'show evpn vni'
10051      L2   vtep1-150             0        0        1               default
```

Every prompt also shows the kubectl Network table (`READY True`,
`ApplySucceeded`) and the `ApplySucceeded` event on screen; all Ready
conditions were re-verified live from kubectl JSON before acceptance.

## What failed in rehearsal, with console text

- rehearsal-1 (A′, vlan 131) and rehearsal-2 (B′, 10.51.0.0/24) both ended with
  the console outcome card: `Submitted — 1 resource still converging past the
  watch bound. Ask for the status of the deployment to resolve it.`
  Root cause (machine evidence, prior session): the sonic-provider Network
  controller's workqueue is permanently saturated by the 5-minute re-verify of
  the ~27 pre-existing Networks (single worker, `resyncInterval` is a hardcoded
  const), so a fresh Network's first apply landed ~9–10 min behind Enter —
  mean queue wait ≈ 249 s, mean reconcile ≈ 9 s, 0 reconcile errors — while the
  deployer convergence watch gave up at 150 s.
- Remediation (runtime configuration only; no code edits, no deletions,
  nothing outside the video output directory touched):
  `DEPLOYER_CONVERGENCE_TIMEOUT_SECONDS=1200` (deployer),
  `DEPLOYER_CALL_TIMEOUT_SECONDS=1500` and
  `SUPERVISOR_REQUEST_DEADLINE_SECONDS=2700` (supervisor), so the chain
  watch < call bound < request deadline holds and the deployer waits out the
  real convergence instead of reporting `still converging`.
- Post-fix rehearsals: vlan 160 (569.5 s), ip-vrf 10.52.0.0/24 (587.7 s) and
  mac-vrf vlan 151 (583.7 s) all reached `Deployed`. Two takes were discarded
  for driver bugs (not console failures): a Playwright strict-mode violation
  (`Clear conversation` resolves to two buttons) and an over-strict terminal
  framing check at 125 % zoom; both fixed, then the final take ran uncut.
  Rehearsal mp4s were never recorded; the two stray rehearsal mp4s left by the
  earlier session were deleted before this take.

## sdcio segment

Included. `kubectl get configs.sdc.sdcio.dev -A` returns 2 rows
(`sdc-system/config.sdc.sdcio.dev/sonic-conn-profile`,
`sdc-system/config.sdc.sdcio.dev/sonic-sync-profile` — static profile
Configs; no Target objects, sdc pods down), so the auto rule
"at least one Config row → include the third command" applied. Shown after B:
CRDs, kuid claims/indices, targets+configs.

## Paths

- video: `docs/media/agentic-netops-intent-tier-demo.mp4`
- evidence: `docs/media/agentic-netops-intent-tier-demo-evidence.json`
- this report: `docs/media/agentic-netops-intent-tier-demo-REPORT.md`
