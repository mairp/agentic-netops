# Task: record the agentic-netops walkthrough on the SR Linux fabric

This job does not write a driver: it runs the existing one
(`testautomation/video/record.py`), accepts the result
(`testautomation/video/accept.py`), and reports. It is Phase 6 of
`specs/001-agentic-netops-srlinux-evpn-fabric/plan.md` (tasks T053-T058).

The driver already carries the framing fixes found on the previous fabric, so
you know what to look for if something fails:

1. Device lookups must actually print something. The driver scans
   `sr_cli "show network-instance summary"` for the object and then reads the
   object itself, and waits for the shell prompt to return before it
   screenshots or types the next command (`term_wait_prompt()`).
2. The agent canvas must not be cut. The driver zooms OUT until the whole
   topology fits the canvas viewport and asserts it before every prompt and at
   the mapper stage (`fit_canvas()`).
3. The terminal must not be clipped. The page is never CSS-zoomed; ttyd runs
   at fontSize 24 (135x39) and `term_frame_check()` fails the take if the xterm
   screen box is clipped.

**New on this target:** the `sr_cli` show syntax has not been executed against
the pinned `ghcr.io/nokia/srlinux:26.7.2` image from this tree. Step 2's smoke
run is the gate that catches a syntax change; treat a command that returns no
prompt as a blocker, not as noise.

## Mission

Produce ONE silent 1920x1080 screen recording,
`<repo>/testautomation/video/final.mp4`, of the intent tier provisioning three
services from the operator console, each proven in the terminal, exactly as the
driver does it. No captions, no overlays, no cuts.

## Steps, in order

1. Pre-flight (read-only):
   - `curl -fsS http://127.0.0.1:30000/api/v1/health` reports `"status":"ok"`.
   - `kubectl -n agentic-netops-agents get deploy deployer supervisor -o json`
     shows `DEPLOYER_CONVERGENCE_TIMEOUT_SECONDS`,
     `DEPLOYER_CALL_TIMEOUT_SECONDS` and `SUPERVISOR_REQUEST_DEADLINE_SECONDS`
     set. Record the values. If any is missing, stop and report; do not change
     the deployments.
   - `ls <repo>/testautomation/video/*.mp4` lists nothing.
   - The identifiers chosen in `docs/DEMO_VIDEO_PROMPT.md` (refreshed ground
     truth, task T053) are free:
     ```bash
     docker exec clab-agentic-netops-fabric-leaf01 sr_cli "show network-instance summary"
     docker exec clab-agentic-netops-fabric-leaf02 sr_cli "show network-instance summary"
     kubectl -n agentic-netops-intent get networks.network.kubenet.dev -o json | grep -c '<prefix>'
     ```
     No network-instance may already carry the chosen vlan ids, and the prefix
     grep must print 0. If any identifier is taken, stop and report.
2. Smoke the framing and the show syntax (about a minute, no video):
   `cd <repo>/testautomation/video && python record.py --smoke --take smoke`
   must exit 0 and its last line must say
   `commands without a returned prompt: none`.
3. Record the take (expect tens of minutes; do not interrupt it). Start it
   detached so no tool call has to stay open that long, then poll the log:
   ```
   cd <repo>/testautomation/video
   setsid nohup python record.py --prompts A3,B3,C3 --take final > record-final.log 2>&1 &
   ```
   Poll with `tail -3 <repo>/testautomation/video/record-final.log`
   about once a minute (sleep 60 between polls) until the log contains a line
   starting `DONE take=final` or `TAKE FAILED`, or 70 minutes have passed
   (then report a timeout with the last 20 lines of the log; do not kill the
   run). The prompts it types are the three the refreshed ground truth
   sanctioned, in order — for the default `A3,B3,C3`:
   - A3 `Provision a vlan <id> on leaf01 ethernet1 for tenant acme`
   - B3 `Deploy an ip-vrf between leaf01 wan1 and leaf02 wan1 for tenant initech with prefix <prefix>`
   - C3 `Extend vlan<id> as a mac-vrf across leaf01 ethernet1 and leaf02 ethernet1 for tenant blue`
   It must end with a line starting `DONE take=final prompts=3`. If it prints
   `TAKE FAILED`, read the reason in `meta-final.json` (`failed`,
   `framing_problems`) and the log, delete `final.mp4`, and stop: report the
   failure verbatim. Do not retry with different wording and do not edit the
   driver. The identifiers are single-use; a second take needs new ones and a
   human decision.
4. Accept:
   `cd <repo>/testautomation/video && python accept.py --take final`
   must print no `FAIL` lines and write `evidence.json` with `"accept_pass": true`.
5. Report, exactly these sections and nothing else: the three prompts and
   their Enter-to-Deployed seconds (from `meta-final.json`); the final
   duration from `ffprobe -v error -show_entries format=duration -of csv=p=0 final.mp4`;
   for each prompt the device proof lines from `evidence.json` (trimmed to the
   matching lines); the `terminal_frames` and `canvas_frames` entries of
   `meta-final.json` (every one must have `"ok": true`); every command whose
   `prompt_returned_on_screen` is false (must be none); the paths of
   `final.mp4`, `evidence.json`, `meta-final.json`, `record-final.log`.

## Hard rules

- Do not modify anything in the repository except the output directory
  `testautomation/video/`. Do not edit `record.py`, `accept.py`, the UI, the
  agents or the deployments. If the image rejects a show command, that is a
  tree fix made and re-verified BEFORE a take, not a live edit during one.
- Read-only on the routers and the cluster. The driver only runs
  `sr_cli "show ..."` and `kubectl get`. Never `sr_cli "enter candidate"`,
  `"commit"`, `"set"`, `"delete"` or `"tools"`.
- Never state that a service converged unless the Ready condition in
  `evidence.json` says so. Screenshots are for framing, never for pass/fail.
- If a step fails, stop and report with the collected output. Do not deliver a
  video that did not pass `accept.py`.
