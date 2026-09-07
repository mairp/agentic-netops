# Prompt: record the agentic-netops walkthrough video

Target model: GLM 3.5 flash (vision). Tools available to the model: Playwright
(Python, `/root/agentflow/.venv/bin/python`), a shell on this host (`kubectl`,
`docker`, `ffmpeg`, `Xvfb`, `xdotool`, `ttyd`), and screenshot reading.

Everything between the `=== PROMPT ===` markers is the text to give the model.
The appendix after it is site ground truth that was verified on 2026-09-06 and
is pasted into the prompt as-is.

=== PROMPT ===

## Mission

Produce ONE silent screen-recording, `final.mp4`, with no duration limit (the
video is as long as the work takes), that shows the agentic-netops intent
tier provisioning at least THREE services from plain-language prompts typed into the operator console at
http://127.0.0.1:30000/, and, after EACH service is reported deployed, the
operator switching to a terminal and proving it with `kubectl` (the kubenet
`Network` resource and its conditions) and with commands run inside the SONiC
leaf router. The video is a tool demonstration, not a tutorial: no captions,
no title cards, no voice, no text overlays, no subtitles. Only what is on the
screen: the console, the terminal, and the cursor. `final.mp4` is the ONLY
video file this job produces: rehearsals are not recorded, and a failed take
is deleted before it is re-recorded.

You are not the presenter. You are the test-automation engineer who makes the
recording deterministic. Every claim of success in your final report must be
backed by machine output you collected (kubectl JSON, redis/vtysh output,
ffprobe), never by what a screenshot "looks like".

## Hard rules

1. Never state that a service converged unless
   `kubectl -n agentic-netops-intent get networks.network.kubenet.dev <name> -o json`
   shows a condition `type=Ready` with `status="True"`. Screenshots are for
   framing checks only, never for pass/fail.
2. Never cut, speed up, or hide any part of the recording where the console
   shows a failure, a refusal, or a still-converging state. If a take contains
   one, the take is discarded and the whole take is re-recorded after fixing
   the cause.
3. Never type into the console anything that is not in the prompt list below.
   Do not improvise wording; three of the console's own suggestion cards are
   refused by the supervisor today (see ground truth), so the prompt list, not
   the cards, is the source of truth.
4. One request per thread. After each deployment click "Clear conversation"
   (aria-label `Clear conversation`) before typing the next prompt.
5. Do not modify anything under `/root/agentic-netops` except the output
   directory `/root/agentic-netops/testautomation/video/`. Do not edit
   supervisor, deployer or UI code. Do not delete cluster resources unless the
   plan below says so.
6. Read-only on the routers. Inside the SONiC containers you may run only
   `redis-cli -n 4 ...` (hgetall/keys), `vtysh -c 'show ...'`, `bridge vlan
   show`, `ip -br link`, `ip -br addr`, `show vlan brief`, `show vrf`. Never
   `config`, `redis-cli ... set/del`, `vtysh -c 'conf t'`.
7. If a step cannot be made to pass after two attempts, stop, and report
   exactly what failed with the collected output. Do not deliver a video that
   does not meet the success criteria and call it done.

## Success criteria (all mandatory)

- `final.mp4` exists, plays, resolution 1920x1080. There is no maximum
  duration; record the actual duration as measured by
  `ffprobe -v error -show_entries format=duration -of csv=p=0` in `evidence.json`.
- `final.mp4` is the only `.mp4` in the output directory when the job ends.
- At least 3 prompts from the list below were typed in the console during the
  final take and each ended with the console's outcome card (aria-label
  `deployment-outcome`) containing the word `Deployed`, and no element with
  aria-label `failure-reason` present.
- For each of those prompts, in the same take, the terminal tab shows the
  kubectl Network listing with READY `True` for the new Network, its
  `ApplySucceeded` event, and at least one router-side proof from leaf01
  (see per-construct checks).
- `evidence.json` records, per prompt: the prompt text, correlation id,
  Network name, the Ready condition JSON, the router command outputs, and the
  wall-clock seconds from Enter to `Deployed`.
- Gap between the end of one prompt's validation and the typing of the next
  prompt: 6 seconds of settled screen. Never shorten any wait, command list or
  hold to save time; there is no total-duration budget.

## Prompt list

Type them in this order. A and B are mandatory. C1 is the preferred third; if
C1 fails rehearsal use C2; if both fail, use D. Use one of C1/C2/D as the third
prompt. A fourth prompt from the remaining candidates is optional; include it
only if it passed rehearsal.

| id | construct | prompt text (type exactly) |
|---|---|---|
| A | vlan | `Provision a vlan 130 on leaf01 ethernet1 for tenant acme` |
| B | ip-vrf | `Deploy an ip-vrf between leaf01 wan1 and leaf02 wan1 for tenant initech with prefix 10.50.0.0/24` |
| C1 | mac-vrf | `Extend vlan150 as a mac-vrf across leaf01 ethernet1 and leaf02 ethernet1 for tenant blue` |
| C2 | mac-vrf | `Create a mac-vrf across leaf01 ethernet1 and leaf02 ethernet1 for tenant blue using vlan150` |
| D | acl | `Apply an acl on leaf01 wan1 for tenant acme: allow ingress tcp port 443 from 10.0.0.0/24, deny everything else` |

Why `vlan150` with no space: the supervisor refuses any request that names two
constructs, and it detects the word `vlan` with a word-boundary regex. `vlan150`
is a single token, so only `mac-vrf` is detected, while the mapper LLM still
reads the VLAN id. This is a workaround for a supervisor bug, not a style.

Rehearsal prompts (same shapes, different identifiers, so the final take never
collides with rehearsal leftovers and nothing has to be deleted):

| id | rehearsal text |
|---|---|
| A' | `Provision a vlan 131 on leaf01 ethernet1 for tenant acme` |
| B' | `Deploy an ip-vrf between leaf01 wan1 and leaf02 wan1 for tenant initech with prefix 10.51.0.0/24` |
| C1' | `Extend vlan151 as a mac-vrf across leaf01 ethernet1 and leaf02 ethernet1 for tenant blue` |
| C2' | `Create a mac-vrf across leaf01 ethernet1 and leaf02 ethernet1 for tenant blue using vlan151` |
| D' | `Apply an acl on leaf02 wan1 for tenant acme: allow ingress tcp port 443 from 10.0.0.0/24, deny everything else` |

## Console interaction contract (Playwright)

- Composer: `page.get_by_label("Service request")`. Type with
  `type(text, delay=45)` so keystrokes are visible, then `keyboard.press("Enter")`.
- The supervisor asks for two confirmations. Wait for and click, in order:
  `page.get_by_label("confirm-mapper")` then `page.get_by_label("confirm-allocator")`.
  Wait up to 120 s for each to appear. Before clicking, pause 1.5 s so the
  viewer can read the interpretation and the allocation.
- Outcome: wait up to 240 s for `page.get_by_label("deployment-outcome")` to
  contain text `Deployed`. If instead it contains `still converging` or
  `Deployment failed`, or `failure-reason` appears, the take has failed.
- The thread id and correlation id are shown as chips in the conversation;
  also read the correlation id from the NDJSON the page receives, or from the
  supervisor log line `audit ... correlation=<id>`. Use it to find the Network:
  `kubectl -n agentic-netops-intent get networks.network.kubenet.dev -l agentic-netops.io/correlation-id=<id> -o json`.
  If the label lookup returns nothing, take the newest Network by
  `creationTimestamp` created after the Enter timestamp.
- Zoom and framing controls that exist in the UI: buttons with aria-labels
  `Zoom in canvas`, `Zoom out canvas`, `Reset canvas view`; Ctrl+wheel over the
  canvas zooms; drag on the canvas background pans; the divider with aria-label
  `Resize conversation panel` accepts arrow keys, Home/End, and double-click
  toggles maximised conversation. The conversation and sidebar have their own
  zoom controls in the same component family.

## Recording architecture

Use a virtual display so the take is deterministic and not affected by the
host desktop:

1. `Xvfb :99 -screen 0 1920x1080x24 &` and `export DISPLAY=:99`.
2. Start a web terminal for the operator's shell:
   `ttyd -p 7681 -W -t fontSize=20 -t 'theme={"background":"#0d1117"}' bash &`.
   Give that bash a clean prompt (`PS1='\[\e[32m\]operator@netops\[\e[0m\]:\w$ '`)
   and pre-export `KUBECONFIG` so `kubectl` works without `--context`.
3. Launch Chromium headed through Playwright (`headless=False`,
   `args=["--window-size=1920,1080","--window-position=0,0","--kiosk"]`),
   one browser context, two pages: page U = http://127.0.0.1:30000/ and
   page T = http://127.0.0.1:7681/. Switch with `page.bring_to_front()`.
4. Record the display with
   `ffmpeg -y -f x11grab -video_size 1920x1080 -framerate 30 -i :99 -c:v libx264 -preset veryfast -crf 20 -pix_fmt yuv420p final.mp4`
   started immediately before the first action and stopped (SIGINT) after the
   last. Only the final take is recorded, and ffmpeg writes it directly to
   `final.mp4` (no `take-N.mp4`, no `rehearsal-N.mp4`); rehearsal runs skip
   ffmpeg entirely. Start it after both pages are loaded and the console
   reports the supervisor healthy, so the recording never contains a loading
   spinner.
5. Terminal typing: on page T use `page.keyboard.type(cmd, delay=35)` then
   `press("Enter")`, then wait a fixed 2.5 s (or until the prompt string
   reappears in a screenshot) before the next command. The truth for the
   evidence file comes from running the SAME command with `subprocess.run` on
   the host, not from reading the terminal pixels.
6. Take screenshots of page U at: after typing, at each confirmation, at the
   outcome card; and of page T after each command. Save them next to the take
   as `shots/<take>-<prompt>-<step>.png`. Look at them with your vision input
   to check framing only (nothing cut off, zoom legible, no dialog covering
   the content).

## Shot plan for the final take

There is no time budget. Use the waits as written and let each deployment take
as long as convergence takes; the shot lengths below are pacing, not limits.

Opening (about 15 s): Console overview. Page U at 100 %. Slowly `Zoom in canvas` twice
over the agent topology (supervisor, mapper, allocator, deployer, SLIM rail),
pan once left-right, `Reset canvas view`. Move the divider so the
conversation gets about 60 % of the height.

Per prompt (3 prompts, each as long as its convergence takes):
- Type the prompt, Enter. While the mapper interprets, the canvas animates the
  SLIM traffic; keep the canvas visible.
- When `confirm-mapper` appears: zoom the conversation one step in so the
  interpretation card is readable, pause 1.5 s, click Confirm.
- When `confirm-allocator` appears: pause 1.5 s on the allocation (RD/RT, VNI,
  vlan), click Confirm.
- Wait for `Deployed`. Hold the outcome card for 2 s.
- Switch to page T. Run the validation commands for that construct (below),
  one after another, 2.5 s each. Zoom the terminal to 125 % via
  `document.body.style.zoom` when the output is dense (the Network table and
  the vtysh table); reset to 100 % afterwards.
- Switch back to page U, click `Clear conversation`, settle 6 s.

Closing: page T, run the summary listing (see "closing" below), hold 5 s,
stop recording.

## Validation commands

Run every command on page T (typed, visible) and on the host (subprocess,
recorded). `$NET` is the Network name, `$CID` the correlation id.

Common, for every prompt:

```bash
kubectl -n agentic-netops-intent get networks.network.kubenet.dev -l agentic-netops.io/correlation-id=$CID \
  -o custom-columns=NAME:.metadata.name,TYPE:'.metadata.annotations.agentic-netops\.io/service-type',READY:'.status.conditions[?(@.type=="Ready")].status',REASON:'.status.conditions[?(@.type=="Ready")].reason'
kubectl -n agentic-netops-intent get events --field-selector involvedObject.name=$NET
kubectl -n agentic-netops-intent get networks.network.kubenet.dev $NET -o jsonpath='{.spec}' | python3 -m json.tool | head -40
```

Construct A (vlan 130 on leaf01):

```bash
docker exec clab-agentic-netops-fabric-leaf01 redis-cli -n 4 hgetall 'VLAN|Vlan130'
docker exec clab-agentic-netops-fabric-leaf01 bridge vlan show dev eth3
```
Pass: the hgetall returns a non-empty hash with `vlanid 130`; `bridge vlan
show dev eth3` lists `130`.

Construct B (ip-vrf on wan1, 10.50.0.0/24):

```bash
docker exec clab-agentic-netops-fabric-leaf01 redis-cli -n 4 keys 'VRF|*'
docker exec clab-agentic-netops-fabric-leaf01 vtysh -c 'show vrf'
docker exec clab-agentic-netops-fabric-leaf01 vtysh -c 'show evpn vni'
docker exec clab-agentic-netops-fabric-leaf01 vtysh -c 'show bgp l2vpn evpn route type prefix' | head -40
```
Pass: a new `VRF|Vrf-<10 hex of the correlation id>` key appears that was not
present before the prompt; `show evpn vni` shows an `L3` row whose Tenant VRF
is that VRF; the Type-5 listing contains `10.50.0.0/24`. Snapshot the VRF key
list BEFORE typing the prompt so "new" is a diff, not a guess.

Construct C (mac-vrf vlan 150 across both leaves):

```bash
docker exec clab-agentic-netops-fabric-leaf01 redis-cli -n 4 hgetall 'VLAN|Vlan150'
docker exec clab-agentic-netops-fabric-leaf01 redis-cli -n 4 keys 'VXLAN_TUNNEL_MAP|vtep1|map_*_Vlan150'
docker exec clab-agentic-netops-fabric-leaf01 vtysh -c 'show evpn vni'
docker exec clab-agentic-netops-fabric-leaf02 vtysh -c 'show evpn vni'
```
Pass: the VLAN row exists; exactly one tunnel-map key for Vlan150; both leaves
show an `L2` row with `VxLAN IF vtep1-150` and `# Remote VTEPs` = 1.

Construct D (acl on leaf01 wan1):

```bash
docker exec clab-agentic-netops-fabric-leaf01 redis-cli -n 4 keys 'ACL_TABLE|*'
docker exec clab-agentic-netops-fabric-leaf01 redis-cli -n 4 keys 'ACL_RULE|*'
docker exec clab-agentic-netops-fabric-leaf01 redis-cli -n 4 hgetall "$(docker exec clab-agentic-netops-fabric-leaf01 redis-cli -n 4 keys 'ACL_TABLE|*' | tail -1)"
```
Pass: a new `ACL_TABLE|<name>` key bound to `eth4` with `stage ingress`, and
two `ACL_RULE|` keys for it, both new relative to the pre-prompt snapshot.

Allocation authority (show once, after prompt B or C, it is the same view):

```bash
kubectl get crd | grep -E 'kubenet|kuid|sdcio'
kubectl -n kuid-system get claims.id.kuid.dev,vniindices.id.kuid.dev
```

sdcio: only if `kubectl get configs.sdc.sdcio.dev -A` returns at least one
row, add `kubectl get targets.sdc.sdcio.dev,configs.sdc.sdcio.dev -A` to the
allocation-authority segment. If it returns `No resources found`, do not show
sdcio at all (the intent path on this site renders through the kubenet
Network controller and the host fabric-executor, not through sdcio, and the
sdc-system pods are currently not running). Record which case applied in the
report.

Closing listing:

```bash
kubectl -n agentic-netops-intent get networks.network.kubenet.dev \
  -o custom-columns=NAME:.metadata.name,TYPE:'.metadata.annotations.agentic-netops\.io/service-type',READY:'.status.conditions[?(@.type=="Ready")].status' | grep -v '^migr-'
```

## Procedure

Phase 0, preflight (no recording):
- `curl -s http://127.0.0.1:30000/` returns 200; `kubectl -n agentic-netops-agents get pods` shows supervisor, mapper, allocator, deployer, slim, ui all Running.
- Confirm VLANs 130, 131, 150, 151 are absent from `redis-cli -n 4 keys 'VLAN|*'` on leaf01 and absent from every Network spec in `agentic-netops-intent`. If any is present, stop and report; do not pick another number.
- Snapshot on leaf01: `VLAN|*`, `VRF|*`, `ACL_TABLE|*`, `VXLAN_TUNNEL_MAP|*` key lists to `snap/pre.json`.

Phase 1, rehearsal (NOT recorded: ffmpeg is not started, framing is judged from the screenshots only):
- Write ONE Python Playwright script, `record.py`, parameterised by the prompt list and a `--record` flag (off for rehearsal, on for the final take). It drives everything; you never drive the browser by hand for a take.
- Run it with A', B', then C1' (fallback C2', then D'). Record per prompt the seconds from Enter to `Deployed`. A rehearsal prompt that ends in refusal, `Deployment failed`, or `still converging` is a failed candidate: capture the console text and the supervisor log (`kubectl -n agentic-netops-agents logs deploy/supervisor --since=10m | grep audit`) into the report, and move to the next candidate. Do not retry the same wording more than once.
- The inter-prompt gap is fixed at 6 s. Do not drop commands, shorten waits or trim the overview to reduce the total duration; the measured per-prompt seconds go into the report only.
- Look at the rehearsal screenshots: confirm nothing is clipped at any zoom level, the terminal font is legible at 1080p, and the outcome card is fully visible when held.

Phase 2, final take:
- Run `record.py --record` with A, B, and the chosen C (plus the optional fourth). Everything is scripted; the only variability is convergence time. This is the only run that records video, and it writes `final.mp4` directly.
- Immediately after the take, run the acceptance checks in Phase 3. If any fails, delete `final.mp4`; fix the script and re-run Phase 2 with fresh identifiers only if the failed prompt actually consumed its identifier (check the Network list). Otherwise re-run with the same identifiers.

Phase 3, acceptance (machine-checked, in `accept.py`):
- ffprobe width 1920, height 1080; duration is recorded, not bounded.
- For each prompt in the take: Network found by correlation id; Ready=True; event `ApplySucceeded`; router pass condition true; all captured with timestamps.
- Console: for each prompt a screenshot of the outcome card exists and, from the page DOM at that time, `deployment-outcome` contained `Deployed` and no `failure-reason` existed. Record the DOM text, not a description of the screenshot.
- Write `evidence.json`. `final.mp4` is already in place; confirm it is the only `.mp4` in the output directory.

Phase 4, report. Output exactly these sections, nothing else: which prompts were used and their wording; per-prompt Enter-to-Deployed seconds; the final duration; the three router proofs quoted verbatim (trimmed to the matching lines); what failed in rehearsal, if anything, with the console text; whether the sdcio segment was included and why; the paths of `final.mp4`, `evidence.json`, `record.py`, `accept.py`. No adjectives about quality.

=== END PROMPT ===

## Appendix: site ground truth (verified 2026-09-06, paste into the prompt)

- Console: http://127.0.0.1:30000/ (NodePort of `ui` in `agentic-netops-agents`). It calls the supervisor at `/api` through the same origin; `GET /api/suggested-prompts` is the served card list, `POST /api/agent/prompt/stream` is NDJSON.
- kubectl context: `kind-agentic-netops`. Namespaces: agents `agentic-netops-agents`, submitted intent `agentic-netops-intent`, kubenet `kubenet-system`, allocation `kuid-system`, sdc `sdc-system` (pods in ImagePullBackOff, zero `Config`/`Target` objects).
- Routers: `clab-agentic-netops-fabric-leaf01`, `...-leaf02`, `...-spine01`, `...-spine02`. CONFIG_DB is redis db 4; ASIC_DB is db 1.
- Port map at this site: `ethernet1`, `ethernet2`, `ethernet3` all resolve to `eth3` (the single client-facing port on each leaf); `wan1` resolves to `eth4`. Site aliases `site-a`=leaf01, `site-b`=leaf02.
- VLANs already on leaf01 eth3: 100, 110, 112, 117, 118, 119, 120, 140, 300; on eth4: 4007, 4008 (derived L3VLANs). Free for the demo: 130, 131, 150, 151, 160, 170. VLAN ids above the derived-L3VLAN base are refused.
- Existing Networks that are NOT Ready and hold ports: `phase8-4e-acl` and `phase8-4e-aclonly` bind an ingress ACL on `ethernet1` (eth3) on both leaves. Any prompt that attaches an ACL on ethernet1/2/3 at ingress is refused by the deployer pre-flight (FR-018). That is why the ACL candidate uses `wan1`.
- Supervisor bounds: MAX_ITERATIONS=3, two explicit confirmations required, deployer convergence watch `DEPLOYER_CONVERGENCE_TIMEOUT_SECONDS`=150. A converged service is re-verified every 5 minutes; an `ApplySucceeded` event may therefore repeat.
- Supervisor rule T072: a request naming two constructs (regex `\b(vlan|mac[- ]?vrf|ip[- ]?vrf|acl)\b`) is refused with "one construct per request". Served cards 2, 4 and 6 ("Extend vlan 150 as a mac-vrf ...", "Create a mac-vrf on vlan 160 ...", "Extend vlan 170 as a mac-vrf ... permitting only tcp 443") trip it on the running supervisor (refusal observed in the log at 15:59 on 2026-09-06).
- UI aria-labels: `Service request` (composer), `Send intent`, `confirm-mapper`, `decline-mapper`, `confirm-allocator`, `decline-allocator`, `deployment-outcome`, `convergence-outcomes`, `failure-reason`, `failure-suggestion`, `Clear conversation`, `Zoom in canvas`, `Zoom out canvas`, `Reset canvas view`, `Resize conversation panel`, `Agent topology`, `Agent conversation`.
- Outcome text on success: `Deployed — N resource verified Ready`; `convergence-outcomes` contains `applied and verified on all nodes`. Ready condition reason on success: `ApplySucceeded`.
- Status question phrasing the supervisor understands on the same thread, if ever needed: `what is the status of the deployment`.
- Tools on the host: Playwright Python in `/root/agentflow/.venv` (browsers in `/root/.cache/ms-playwright`), `chromium` at `/usr/bin/chromium`, `ffmpeg`, `Xvfb`, `xvfb-run`, `xdotool`, `ttyd 1.7.7`.
- Output directory: `/root/agentic-netops/testautomation/video/` (create it).
