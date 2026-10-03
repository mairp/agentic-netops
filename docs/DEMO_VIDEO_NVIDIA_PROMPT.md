# Prompt: retheme the operator console to the NVIDIA dark palette and re-record the walkthrough

Written 2026-10-03. Successor of `DEMO_VIDEO_PROMPT.md` (the first take) and
`DEMO_VIDEO_RETAKE.md` (the fixed driver). This job changes how the console and
the terminal LOOK and nothing else: the recording has the same workflow, the
same prompts, the same commands and the same acceptance as the 2026-09-07 take
that mairp.ai embeds, in the palette mairp.ai itself uses.

Everything between the `=== PROMPT ===` markers is the text to give the model.
The appendix after it is ground truth verified on 2026-10-03.

=== PROMPT ===

## Mission

1. Retheme the operator console (`ui/`) and the recording terminal to the
   NVIDIA dark palette of mairp.ai (token table below).
2. Re-record the walkthrough with the existing driver
   (`testautomation/video/record.py`), accept it with the existing acceptance
   (`testautomation/video/accept.py`), and produce the accelerated cut the site
   embeds.
3. Check the result against mairp.ai: frames of the new video, placed next to
   the page, must read as one design.

You are the test-automation engineer. Every claim of success is backed by
machine output (kubectl JSON, router output, ffprobe, sampled pixel values),
never by what a screenshot "looks like".

## Palette (source of truth: `:root, [data-theme="dark"]` in `index.html` of the mairp.ai site repository)

| role | mairp.ai token | value | console token (`ui/src/styles.css`) |
|---|---|---|---|
| ground | `--bg` | `#000000` | `--page` |
| surface | `--bg-2` | `#121212` | `--panel` |
| raised surface | `--panel` | `#1b1b1b` | `--panel-strong` |
| hover / nested | `--repo-hover` | `#242424` | `--panel-soft` |
| hairline | `--line` | `rgba(255,255,255,.13)` | `--border` |
| text | `--ink` | `#ffffff` | `--text` |
| secondary text | `--ink-dim` | `#8f8f8f` | `--muted` |
| tertiary text | `--ink-faint` | `#6a6a6a` | `--faint` |
| the single accent | `--signal` | `#76b900` | `--accent`, and `--teal` (ready/success) |
| accent, darker | `--signal-dim` | `#5f9400` | `--accent-dim` |
| label on green | `--on-signal` | `#000000` | `--on-accent` |
| status: attention | `--amber` | `#ffb01f` | `--amber` |
| status: failure | (kanban guide `--red`) | `#ff5c5c` | `--danger` |
| dot-grid ground | `--dot` | `rgba(255,255,255,.085)`, 22px | `--dot` |

Form rules, from the site's flattening layer: square corners everywhere, no
soft drop shadows, no gradients on surfaces, label text on a green fill is
black and bold, never white. The green glow of live elements is allowed (the
site's ambient layer makes the same exception). The light theme maps to the
site's light tokens (`#5c9400` accent on white) so the toggle stays coherent;
the recording uses dark.

Terminal (ttyd theme in `record.py`): background `#000000`, foreground
`#ffffff`, cursor and ANSI green `#76b900`. The `PS1` string is unchanged.

## Hard rules

1. Colour and form only. Do not change any DOM structure, text, aria-label,
   element size, spacing, font family or font size in the console: the driver's
   framing assertions (`fit_canvas()`, `term_frame_check()`) and the viewer's
   comparison with the first take depend on identical geometry. No web fonts
   (the console must not gain a network dependency).
2. In `record.py` only the ttyd `theme=` argument changes. Prompts, selectors,
   waits, the command lists, `PS1`, `fontSize`, the ffmpeg line and `accept.py`
   are untouched. Do not edit the supervisor, the agents or the deployments.
3. The take types the same three prompts as the embedded video, in this order:
   - A3 `Provision a vlan 170 on leaf01 ethernet1 for tenant acme`
   - B3 `Deploy an ip-vrf between leaf01 wan1 and leaf02 wan1 for tenant initech with prefix 10.53.0.0/24`
   - C3 `Extend vlan152 as a mac-vrf across leaf01 ethernet1 and leaf02 ethernet1 for tenant blue`

   They are single-use on a lab that already holds them. If Vlan170, Vlan152 or
   10.53.0.0/24 is present on the lab, stop and report; do not pick other
   identifiers and do not delete resources to free them.
4. Never state that a service converged unless the Ready condition in
   `evidence.json` says so. Never cut or hide a failure; a failed take is
   deleted and reported, not delivered.
5. Read-only on the routers and the cluster, except rolling the `ui`
   Deployment onto the rebuilt image. Do not `kubectl apply` the files under
   `deploy/agents/` wholesale.
6. The lab is a precondition, not something this job creates. If the console
   at http://127.0.0.1:30000/ is not served by the SONiC lab of THIS repository
   (see pre-flight), finish phases 1 and 2, then stop and report. Do not create,
   delete or replace a kind cluster or a containerlab topology.
7. Nothing is pushed or published. The site repository
   the mairp.ai site repository is read-only for this job.

## Success criteria (all mandatory)

- Video integrity: `final.mp4` is 1920x1080, one continuous take, no cuts, no
  overlays, and the only `.mp4` in `testautomation/video/` besides the
  accelerated cut named below.
- Workflow: `record.py` ends with `DONE take=final prompts=3`; every
  `terminal_frames` and `canvas_frames` entry in `meta-final.json` has
  `"ok": true`; no command has `prompt_returned_on_screen` false.
- Commands: the command set typed in the terminal is the one `record.py`
  generated on 2026-09-07 for A3, B3, authority, C3 and closing, in the same
  order (compare `commands[*].cmd` of the new `evidence.json` with
  `docs/media/agentic-netops-intent-tier-demo-evidence.json`, with correlation
  ids, Network names and the derived VRF name normalised).
- Acceptance: `accept.py --take final` prints no `FAIL` line and writes
  `"accept_pass": true`.
- Palette: in a frame of the console, the canvas ground samples `#000000`, the
  top bar `#121212`, and the active SLIM rail label `#76b900` (tolerance 6 per
  channel for H.264). In a terminal frame the ground samples `#000000` and the
  prompt `operator@netops` samples `#76b900`. No pixel of the old accent
  `#3699ff` (blue) or old ground `#15181c` survives in the UI stylesheet.
- Harmony: a contact sheet of four frames of the new video next to a dark-theme
  screenshot of the "building now" card of `index.html` of the mairp.ai site repository
  is produced, and the sampled ground, surface and accent values on both sides
  are reported side by side.

## Phases

Phase 1, retheme (no cluster needed):
- Replace the token values in `.app-shell` and `.app-shell[data-theme='light']`
  per the table; add `--accent-dim`, `--on-accent`, `--dot`.
- Every `color: white` that sits on an accent fill becomes `var(--on-accent)`
  (brand mark, primary button, send button, active rail label, the icon-blink
  keyframe).
- Append a flattening layer: `border-radius: 0 !important` shell-wide, drop
  the black drop shadows on graph nodes and the composer, keep the green rings.
- Dot grid uses `--dot` at 22px like the site. `ui/index.html` theme-color
  becomes `#000000`.
- `record.py`: the ttyd `theme=` value only.

Phase 2, verify the look (no cluster needed):
- `npx tsc --noEmit` and `npx vite build` in `ui/` succeed.
- Serve the build and drive it with Playwright while fulfilling `/api/**` from
  the script (health ok, an NDJSON stream with mapper, confirmation, allocator,
  deployer COMPLETED, and an error). Screenshot idle, working, approval,
  deployed and failure, in dark and in light. Look at them: nothing clipped,
  no white label on green, no rounded corner, no blue.
- Assert geometry is unchanged: `.topology-flow` bounding box is 720 wide and
  at the same x,y as before the change at 1920x1080.

Phase 3, pre-flight on the lab (read-only):
- `curl -fsS http://127.0.0.1:30000/api/v1/health` reports `"status":"ok"`.
- `kubectl get crd networks.network.kubenet.dev` exists and
  `docker inspect -f '{{.Config.Image}} {{.State.Status}}' clab-agentic-netops-fabric-leaf01`
  shows a running SONiC image. Anything else is rule 6: stop.
- The remaining pre-flight items of `DEMO_VIDEO_RETAKE.md` step 1.

Phase 4, roll the console:
- Build `docker/Dockerfile.ui` from the repository root to the image reference
  the running `ui` Deployment uses, `kind load` it, `kubectl rollout restart
  deploy/ui`, wait for the rollout, and confirm the served CSS contains
  `#76b900` and not `#3699ff`.

Phase 5, record and accept: steps 2, 3 and 4 of `DEMO_VIDEO_RETAKE.md`,
unchanged.

Phase 6, the cut and the harmony check:
- `scripts/video-accelerate.sh final.mp4 agentic-netops-demo.mp4 <factor>`,
  the factor chosen so the cut lasts the 6½ min the site's caption states
  (duration of `final.mp4` / 390), and a 1280x720 poster frame
  `agentic-netops-demo-thumb.jpg` taken from a frame that shows the outcome
  card. Both stay in `testautomation/video/`.
- Sample the palette pixels and build the contact sheet described under
  success criteria.
- Refresh `docs/images/agent-ui.png` and `docs/images/agent-ui-outcome.png`
  from the take's own screenshots. Leave
  `docs/media/agentic-netops-intent-tier-demo-evidence.json` alone: it is the
  evidence of the video the README embeds, which this job cannot replace.

Phase 7, report. Exactly: files changed; the palette samples (expected vs
measured); the three prompts and their Enter-to-Deployed seconds; durations of
`final.mp4` and of the cut; the command-set comparison result; the frame-check
entries; anything that failed, verbatim; paths of every artefact. No adjectives
about quality.

=== END PROMPT ===

## Appendix: ground truth (verified 2026-10-03)

- mairp.ai is the mairp.ai site repository (single `index.html`); it embeds
  `assets/agentic-netops-demo.mp4` (1920x1080, 388 s, the 2026-09-07 take at
  6x) with poster `assets/agentic-netops-demo-thumb.jpg`, captioned "6½ min".
  The working tree there has uncommitted edits of its own.
- The console's colours all come from custom properties in
  `ui/src/styles.css`; no component carries an inline colour. Fonts are the
  system stack (`Inter`/`IBM Plex Mono` are named but never loaded).
- The 2026-09-07 take: `record.py --prompts A3,B3,C3 --take final`, 2328 s,
  Enter-to-Deployed 642.7 / 655.3 / 668.3 s, 22 terminal commands.
- Lab state today: the kind cluster named `agentic-netops` is the SR Linux
  variant's (`agentic-netops-srl`: CRD `networks.fabric.agentic-netops.io`,
  console on host port 13000, supervisor on 19090), and its four
  `clab-agentic-netops-fabric-*` routers are SR Linux containers that exited.
  Nothing listens on 30000, `networks.network.kubenet.dev` does not exist, and
  no SONiC image is loaded in Docker. The SONiC lab this driver records has to
  be provisioned (`scripts/provision.sh --with-intent-tier`) under the same
  cluster and topology names, which replaces the SR Linux lab: an operator
  decision, hence rule 6.
- Tools: Playwright Python (the venv `DEMO_VIDEO_PROMPT.md` names), `ffmpeg`, `Xvfb`,
  `ttyd`, `kind`, `docker`.

## Outcome of the 2026-10-03 run

- The operator authorised shutting the SR Linux lab down and moving an unrelated Docker
  network, auto-assigned to 172.31.0.0/16, off the lab's management subnet, which lifts rule 6 for that run. The SONiC lab was
  provisioned from scratch with `scripts/provision.sh --with-intent-tier`.
- Three things the from-scratch provision did not do, fixed by hand before the
  take: `deploy/rbac/controller-rbac.yaml` is applied by no script (the
  provider never won its lease); the `fabric-compat-pins` generator in
  `provision.sh` had a stray `}` (fixed in the script); ClickHouse never gets
  the `agent_analytics` database (`CLICKHOUSE_DB` sits on the collector
  container in `deploy/agents/telemetry.yaml`, not on ClickHouse).
- On a lab with no backlog of Networks the three services deployed in 63.8,
  39.6 and 72.0 s, so `final.mp4` is 655 s instead of 2328 s and the cut uses
  factor 1.68 (390 s). The closing listing filters `migr-*` and is therefore
  empty on a fresh lab.
- `accept.py`: PASS. Command set: 22 of 22 identical to the 2026-09-07 take.
