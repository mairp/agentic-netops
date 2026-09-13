# Prompt: record the agentic-netops walkthrough video (Nokia SR Linux fabric)

Target model: a vision-capable model with tool use. Tools available to the
model: Playwright (Python), a shell on the lab host (`kubectl`, `docker`,
`ffmpeg`, `Xvfb`, `xdotool`, `ttyd`), and screenshot reading.

Everything between the `=== PROMPT ===` markers is the text to give the model.
The appendix after it is site ground truth. **It must be re-verified against
the running SR Linux lab and pasted into the prompt before every take** — see
"Appendix: site ground truth" for what to check and how. The values currently
in the appendix are a template carried over from the previous (SONiC) site and
have NOT been read off an SR Linux fabric.

=== PROMPT ===

## Mission

Produce ONE silent screen-recording, `final.mp4`, with no duration limit (the
video is as long as the work takes), that shows the agentic-netops intent
tier provisioning at least THREE services from plain-language prompts typed into the operator console at
http://127.0.0.1:30000/, and, after EACH service is reported deployed, the
operator switching to a terminal and proving it with `kubectl` (the kubenet
`Network` resource and its conditions) and with read-only `sr_cli` show
commands run inside the Nokia SR Linux leaf. The video is a tool
demonstration, not a tutorial: no captions, no title cards, no voice, no text
overlays, no subtitles. Only what is on the screen: the console, the terminal,
and the cursor. `final.mp4` is the ONLY video file this job produces:
rehearsals are not recorded, and a failed take is deleted before it is
re-recorded.

You are not the presenter. You are the test-automation engineer who makes the
recording deterministic. Every claim of success in your final report must be
backed by machine output you collected (kubectl JSON, `sr_cli` output,
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
   Do not improvise wording.
4. One request per thread. After each deployment click "Clear conversation"
   (aria-label `Clear conversation`) before typing the next prompt.
5. Do not modify anything under the repository except the output directory
   `testautomation/video/`. Do not edit supervisor, deployer or UI code. Do not
   delete cluster resources unless the plan below says so.
6. **Read-only on the routers.** Inside the SR Linux containers you may run
   only `sr_cli "show ..."` and `sr_cli "info from state ..."`. Never
   `sr_cli "enter candidate"`, `"commit ..."`, `"tools ..."`, `"delete ..."`
   or `"set ..."`; never `bash` inside the node. The only sanctioned write to a
   node in the whole project is the drift-repair test (T050), which is not part
   of the recording.
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
  `ApplySucceeded` event, and at least one device-side proof from leaf01
  (see per-construct checks).
- `evidence.json` records, per prompt: the prompt text, correlation id,
  Network name, the Ready condition JSON, the device command outputs, and the
  wall-clock seconds from Enter to `Deployed`.
- Gap between the end of one prompt's validation and the typing of the next
  prompt: 6 seconds of settled screen. Never shorten any wait, command list or
  hold to save time; there is no total-duration budget.

## Prompt list

Type them in this order. A and B are mandatory. C1 is the preferred third; if
C1 fails rehearsal use C2; if both fail, use D. Use one of C1/C2/D as the third
prompt. A fourth prompt from the remaining candidates is optional; include it
only if it passed rehearsal.

The identifiers below are placeholders: **replace them with identifiers the
refreshed ground truth says are free on this fabric**, and use each one once.

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
- Outcome: wait for `page.get_by_label("deployment-outcome")` to contain text
  `Deployed`. If instead it contains `still converging` or
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
  toggles maximised conversation.

## Recording architecture

Use a virtual display so the take is deterministic and not affected by the
host desktop:

1. `Xvfb :99 -screen 0 1920x1080x24 &` and `export DISPLAY=:99`.
2. Start a web terminal for the operator's shell:
   `ttyd -p 7681 -W -t fontSize=24 -t 'theme={"background":"#0d1117"}' bash &`.
   Give that bash a clean prompt (`PS1='\[\e[32m\]operator@netops\[\e[0m\]:\w$ '`)
   and pre-export `KUBECONFIG` so `kubectl` works without `--context`.
3. Launch Chromium headed through Playwright (`headless=False`,
   `args=["--window-size=1920,1080","--window-position=0,0","--kiosk"]`),
   one browser context, two pages: page U = http://127.0.0.1:30000/ and
   page T = http://127.0.0.1:7681/. Switch with `page.bring_to_front()`.
4. Record the display with
   `ffmpeg -y -f x11grab -video_size 1920x1080 -framerate 30 -i :99 -c:v libx264 -preset veryfast -crf 20 -pix_fmt yuv420p final.mp4`
   started immediately before the first action and stopped (SIGINT) after the
   last. Only the final take is recorded; rehearsal runs skip ffmpeg entirely.
   Start it after both pages are loaded and the console reports the supervisor
   healthy, so the recording never contains a loading spinner.
5. Terminal typing: on page T use `page.keyboard.type(cmd, delay=35)` then
   `press("Enter")`, then wait until the shell prompt reappears in xterm's
   buffer before the next command. The truth for the evidence file comes from
   running the SAME command with `subprocess.run` on the host, not from
   reading the terminal pixels.
6. Take screenshots of page U at: after typing, at each confirmation, at the
   outcome card; and of page T after each command. Save them next to the take
   as `shots/<take>-<prompt>-<step>.png`. Check framing only (nothing cut off,
   zoom legible, no dialog covering the content).

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
  one after another, waiting for the prompt each time.
- Switch back to page U, click `Clear conversation`, settle 6 s.

Closing: page T, run the summary listing (see "closing" below), hold 5 s,
stop recording.

## Validation commands

Run every command on page T (typed, visible) and on the host (subprocess,
recorded). `$NET` is the Network name, `$CID` the correlation id, `$LEAF1` and
`$LEAF2` the containers `clab-agentic-netops-fabric-leaf01` / `-leaf02`.

> **VERIFY LIVE before the take.** Every `sr_cli` line below is the syntax
> recorded in `specs/001-agentic-netops-srlinux-evpn-fabric/research.md` (D10).
> None of it has been executed against the pinned 26.7.2 image from this tree.
> `python record.py --smoke --take smoke` types a short command set and asserts
> that every command returns a shell prompt — run it first, and correct any
> command whose syntax the image rejects, here and in `record.py` together.

Common, for every prompt:

```bash
kubectl -n agentic-netops-intent get networks.network.kubenet.dev -l agentic-netops.io/correlation-id=$CID \
  -o custom-columns=NAME:.metadata.name,TYPE:'.metadata.annotations.agentic-netops\.io/service-type',READY:'.status.conditions[?(@.type=="Ready")].status',REASON:'.status.conditions[?(@.type=="Ready")].reason'
kubectl -n agentic-netops-intent get events --field-selector involvedObject.name=$NET
kubectl -n agentic-netops-intent get networks.network.kubenet.dev $NET -o jsonpath='{.spec}' | python3 -m json.tool | head -40
```

Construct A (vlan 130 on leaf01):

```bash
docker exec $LEAF1 sr_cli "show network-instance summary" | grep -iE 'Name|Type|vlan-130'
docker exec $LEAF1 sr_cli "show network-instance vlan-130 interfaces"
```
Pass: the summary lists a `mac-vrf` network-instance `vlan-130` that was NOT in
the pre-prompt snapshot, and its interfaces list contains `ethernet-1/3.130`.

Construct B (ip-vrf on wan1, 10.50.0.0/24):

```bash
docker exec $LEAF1 sr_cli "show network-instance summary" | grep -iE 'Name|ip-vrf'
docker exec $LEAF1 sr_cli "show network-instance <VRF> summary"
docker exec $LEAF1 sr_cli "show network-instance <VRF> route-table ipv4-unicast summary"
docker exec $LEAF2 sr_cli "show network-instance default protocols bgp routes evpn route-type 5 summary" | grep -F '10.50.0.0'
```
`<VRF>` is the on-device name derived from the Network's router
(`Vrf-` + the first 10 usable characters); `record.py` derives it from the
Network spec. Pass: the ip-vrf network-instance is new relative to the
pre-prompt snapshot, its route table carries the prefix, and **leaf02** — the
peer — shows the Type-5 for `10.50.0.0/24`. The peer's view is the honest
proof: origination on leaf01 cannot put a route in leaf02's EVPN RIB.

Construct C (mac-vrf vlan 150 across both leaves):

```bash
docker exec $LEAF1 sr_cli "show network-instance <NI> summary"
docker exec $LEAF2 sr_cli "show network-instance <NI> summary"
docker exec $LEAF1 sr_cli "show tunnel-interface vxlan1 vxlan-interface <L2VNI> bridge-table multicast-destinations"
docker exec $LEAF2 sr_cli "show tunnel-interface vxlan1 vxlan-interface <L2VNI> bridge-table multicast-destinations"
```
`<NI>` is the bridge domain's device name, `<L2VNI>` the allocated L2VNI; both
come from the Network spec. Pass: the network-instance exists on BOTH leaves,
and each leaf's multicast-destinations list contains the OTHER leaf's system IP
(`10.0.0.21` on leaf02, `10.0.0.22` on leaf01). A remote VTEP appears only once
the peer's IMET route arrived — self-origination cannot fake it.

Construct D (acl on leaf01 wan1):

```bash
docker exec $LEAF1 sr_cli "show acl summary"
docker exec $LEAF1 sr_cli "show acl acl-filter <FILTER> type ipv4"
```
`<FILTER>` is `acl-<network name>-<stage>` sanitised. Pass: exactly one new
acl-filter relative to the pre-prompt snapshot; the filter lists the declared
entries (tcp 443 from 10.0.0.0/24 accept, default drop) and is bound on an
`ethernet-1/4` subinterface.

Allocation authority (show once, after prompt B or C, it is the same view):

```bash
kubectl get crd | grep -E 'kubenet|kuid|sdcio'
kubectl -n kuid-system get claims.id.kuid.dev,vniindices.id.kuid.dev
```

sdcio: only if `kubectl get configs.sdc.sdcio.dev -A` returns at least one
row, add `kubectl get targets.sdc.sdcio.dev,configs.sdc.sdcio.dev -A` to the
allocation-authority segment. If it returns `No resources found`, do not show
sdcio at all (the intent path on this site renders through the kubenet
Network controller and the host fabric-executor speaking gNMI, not through
sdcio). Record which case applied in the report.

Closing listing:

```bash
kubectl -n agentic-netops-intent get networks.network.kubenet.dev \
  -o custom-columns=NAME:.metadata.name,TYPE:'.metadata.annotations.agentic-netops\.io/service-type',READY:'.status.conditions[?(@.type=="Ready")].status' | grep -v '^migr-'
```

## Procedure

Phase 0, preflight (no recording):
- `curl -s http://127.0.0.1:30000/` returns 200; `kubectl -n agentic-netops-agents get pods` shows supervisor, mapper, allocator, deployer, slim, ui all Running.
- Refresh the site ground truth (appendix) against the running lab and paste it into this prompt.
- Confirm the chosen VLAN ids and prefixes are absent from `sr_cli "show network-instance summary"` on both leaves and absent from every Network spec in `agentic-netops-intent`. If any is present, stop and report; do not silently pick another number — record the substitution in the ground truth first.
- Snapshot on both leaves: `show network-instance summary`, `show acl summary`, and `show tunnel-interface vxlan1 vxlan-interface brief` into `snap/pre.json`.

Phase 1, rehearsal (NOT recorded: ffmpeg is not started, framing is judged from the screenshots only):
- `python record.py --smoke --take smoke` first: it proves the layout, the framing and that every terminal command returns a prompt. It must print `commands without a returned prompt: none`.
- Run `record.py` with A', B', then C1' (fallback C2', then D'). Record per prompt the seconds from Enter to `Deployed`. A rehearsal prompt that ends in refusal, `Deployment failed`, or `still converging` is a failed candidate: capture the console text and the supervisor log (`kubectl -n agentic-netops-agents logs deploy/supervisor --since=10m | grep audit`) into the report, and move to the next candidate. Do not retry the same wording more than once, and never fix a refusal by rewording outside the sanctioned list — fix it in the tree.
- The inter-prompt gap is fixed at 6 s. Do not drop commands, shorten waits or trim the overview to reduce the total duration.
- Look at the rehearsal screenshots: confirm nothing is clipped at any zoom level, the terminal font is legible at 1080p, and the outcome card is fully visible when held.

Phase 2, final take:
- Run `record.py --prompts A,B,C1 --take final` with fresh identifiers. Everything is scripted; the only variability is convergence time. This is the only run that records video, and it writes `final.mp4` directly.
- Immediately after the take, run the acceptance checks in Phase 3. If any fails, delete `final.mp4`; fix the script and re-run Phase 2 with fresh identifiers only if the failed prompt actually consumed its identifier (check the Network list). Otherwise re-run with the same identifiers.

Phase 3, acceptance (machine-checked, in `accept.py`):
- ffprobe width 1920, height 1080; duration is recorded, not bounded.
- For each prompt in the take: Network found by correlation id; Ready=True; event `ApplySucceeded`; device pass condition true; all captured with timestamps.
- Console: for each prompt a screenshot of the outcome card exists and, from the page DOM at that time, `deployment-outcome` contained `Deployed` and no `failure-reason` existed. Record the DOM text, not a description of the screenshot.
- Write `evidence.json`. `final.mp4` is already in place; confirm it is the only `.mp4` in the output directory.

Phase 4, report. Output exactly these sections, nothing else: which prompts were used and their wording; per-prompt Enter-to-Deployed seconds; the final duration; the three device proofs quoted verbatim (trimmed to the matching lines); what failed in rehearsal, if anything, with the console text; whether the sdcio segment was included and why; the paths of `final.mp4`, `evidence.json`, `record.py`, `accept.py`. No adjectives about quality.

=== END PROMPT ===

## Appendix: site ground truth

> **Status: NOT VERIFIED on the SR Linux lab.** The SR Linux fabric has not
> been brought up from this tree, so nothing in this appendix has been read off
> it. Every line below is either a fact fixed by the tree (ports, namespaces,
> aria-labels) or a placeholder carried over from the previous site (free VLAN
> ids, existing Networks). **Refresh it, with the commands given, immediately
> before the take (task T053) and record the date you did.**

Last refreshed: _(never — fill in with the date of the run)_

### Fixed by the tree (re-read only if the tree changed)

- Console: http://127.0.0.1:30000/ (NodePort of `ui` in `agentic-netops-agents`). It calls the supervisor at `/api` through the same origin; `GET /api/suggested-prompts` is the served card list, `POST /api/agent/prompt/stream` is NDJSON.
- kubectl context: `kind-agentic-netops`. Namespaces: agents `agentic-netops-agents`, submitted intent `agentic-netops-intent`, kubenet `kubenet-system`, allocation `kuid-system`, sdc `sdc-system`.
- Fabric nodes: `clab-agentic-netops-fabric-leaf01`, `...-leaf02`, `...-spine01`, `...-spine02`, all Nokia SR Linux (`ghcr.io/nokia/srlinux:26.7.2`, containerlab kind `nokia_srlinux`, type `ixrd2l`). Management addresses `172.31.0.21/.22/.11/.12`, gNMI on `:57400` over TLS.
- Port map at this site: `ethernet1`, `ethernet2`, `ethernet3` all resolve to `ethernet-1/3` (the single client-facing interface on each leaf); `wan1` resolves to `ethernet-1/4`. Site aliases `site-a`=leaf01, `site-b`=leaf02. Each service lands on its own single-tagged subinterface of that interface.
- system0 loopbacks (the VTEP source addresses): leaf01 `10.0.0.21`, leaf02 `10.0.0.22`, spine01 `10.0.0.11`, spine02 `10.0.0.12`.
- Bootstrap tenant state present on both leaves from startup configuration: mac-vrf `vlan100` (L2VNI 100, clients untagged on `ethernet-1/3.0`) and ip-vrf `VrfBlue` (L3VNI 2000). Do not reuse vlan 100 or VNIs 100/2000.
- UI aria-labels: `Service request` (composer), `Send intent`, `confirm-mapper`, `decline-mapper`, `confirm-allocator`, `decline-allocator`, `deployment-outcome`, `convergence-outcomes`, `failure-reason`, `failure-suggestion`, `Clear conversation`, `Zoom in canvas`, `Zoom out canvas`, `Reset canvas view`, `Resize conversation panel`, `Agent topology`, `Agent conversation`.
- Outcome text on success: `Deployed — N resource verified Ready`; `convergence-outcomes` contains `applied and verified on all nodes`. Ready condition reason on success: `ApplySucceeded`.
- Supervisor rule T072: a request naming two constructs (regex `\b(vlan|mac[- ]?vrf|ip[- ]?vrf|acl)\b`) is refused with "one construct per request". Check the served suggestion cards against this rule before the take and record which ones trip it.
- Status question phrasing the supervisor understands on the same thread: `what is the status of the deployment`.
- SRv6 is not applicable on this fabric; no SRv6 prompt exists and none may be improvised.

### To refresh before every take

Run these and paste the answers here:

```bash
# 1. Which network-instances already exist (free VLAN ids and VRF names)
docker exec clab-agentic-netops-fabric-leaf01 sr_cli "show network-instance summary"
docker exec clab-agentic-netops-fabric-leaf02 sr_cli "show network-instance summary"

# 2. Which VNIs are already bound
docker exec clab-agentic-netops-fabric-leaf01 sr_cli "show tunnel-interface vxlan1 vxlan-interface brief"

# 3. Which subinterfaces the client and wan interfaces already carry
docker exec clab-agentic-netops-fabric-leaf01 sr_cli "show interface ethernet-1/3 detail"
docker exec clab-agentic-netops-fabric-leaf01 sr_cli "show interface ethernet-1/4 detail"

# 4. Which acl-filters are bound
docker exec clab-agentic-netops-fabric-leaf01 sr_cli "show acl summary"

# 5. Existing Networks, which are Ready, and which hold ports
kubectl -n agentic-netops-intent get networks.network.kubenet.dev -o wide
kubectl -n agentic-netops-intent get networks.network.kubenet.dev -o json \
  | python3 -c 'import json,sys; [print(n["metadata"]["name"], json.dumps(n["spec"].get("attachments"))) for n in json.load(sys.stdin)["items"]]'

# 6. The supervisor's own suggestion cards, and whether any trips the
#    one-construct rule
curl -s http://127.0.0.1:30000/api/suggested-prompts

# 7. The deployer's convergence bound in force on this deployment
kubectl -n agentic-netops-agents get deploy deployer -o jsonpath='{.spec.template.spec.containers[0].env}' \
  | python3 -m json.tool | grep -A1 CONVERGENCE
```

Fill in, from those outputs:

- Free VLAN ids for the take (three, single-use): _(fill in)_
- Free prefixes for the ip-vrf prompts: _(fill in)_
- Existing Networks that are NOT Ready and hold ports (these constrain which
  attachment an ACL prompt may name): _(fill in)_
- Deployer convergence watch seconds: _(fill in)_
- Suggestion cards that the one-construct rule refuses: _(fill in)_
- `sr_cli` show syntax confirmed on the image (`record.py --smoke` output): _(fill in)_

### Host tooling

- Playwright Python with Chromium, `ffmpeg`, `Xvfb`, `xvfb-run`, `xdotool`, `ttyd`.
- Output directory: `testautomation/video/` in the repository clone.
