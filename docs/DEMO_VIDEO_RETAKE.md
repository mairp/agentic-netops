# Task: re-record the agentic-netops walkthrough with the fixed driver

Handed to `dsh --profile headless` on 2026-09-07 after the first accepted take
was reviewed. Three defects were found in that take and fixed in the driver
(`testautomation/video/record.py`), so this job does not write a driver: it
runs the existing one, accepts the result, and reports.

Defects fixed, so you know what to look for if something fails:

1. At 11:47 of the first take the on-screen `redis-cli hgetall 'VLAN|Vlan130'`
   printed nothing. The driver now scans CONFIG_DB keys case-insensitively
   (`vlan_lookup()`), and waits for the shell prompt to return before it
   screenshots or types the next command (`term_wait_prompt()`).
2. The agent canvas was zoomed in and the topology was cut. The driver now
   zooms OUT until the whole topology fits the canvas viewport and asserts it
   before every prompt and at the mapper stage (`fit_canvas()`).
3. The terminal was CSS-zoomed after xterm had sized itself, clipping both
   edges. The page is no longer zoomed; ttyd runs at fontSize 24 (135x39) and
   `term_frame_check()` fails the take if the xterm screen is clipped.

## Mission

Produce ONE silent 1920x1080 screen recording,
`/root/agentic-netops/testautomation/video/final.mp4`, of the intent tier
provisioning three services from the operator console, each proven in the
terminal, exactly as the driver does it. No captions, no overlays, no cuts.

## Steps, in order

1. Pre-flight (read-only):
   - `curl -fsS http://127.0.0.1:30000/api/v1/health` reports `"status":"ok"`.
   - `kubectl -n agentic-netops-agents get deploy deployer supervisor -o json`
     shows `DEPLOYER_CONVERGENCE_TIMEOUT_SECONDS=1200`,
     `DEPLOYER_CALL_TIMEOUT_SECONDS=1500`, `SUPERVISOR_REQUEST_DEADLINE_SECONDS=2700`.
     If any is missing, stop and report; do not change the deployments.
   - `ls /root/agentic-netops/testautomation/video/*.mp4` lists nothing.
   - `docker exec clab-agentic-netops-fabric-leaf01 redis-cli -n 4 keys 'VLAN|*'`
     contains neither `Vlan170` nor `Vlan152`, and
     `kubectl -n agentic-netops-intent get networks.network.kubenet.dev -o json | grep -c 10.53.0.0`
     prints 0. If any identifier is taken, stop and report.
2. Smoke the framing (about a minute, no video):
   `cd /root/agentic-netops/testautomation/video && /root/agentflow/.venv/bin/python record.py --smoke --take smoke`
   must exit 0 and its last line must say `commands without a returned prompt: none`.
3. Record the take (about 35 to 40 minutes; do not interrupt it). Start it
   detached so no tool call has to stay open that long, then poll the log:
   ```
   cd /root/agentic-netops/testautomation/video
   setsid nohup /root/agentflow/.venv/bin/python record.py --prompts A3,B3,C3 --take final > record-final.log 2>&1 &
   ```
   Poll with `tail -3 /root/agentic-netops/testautomation/video/record-final.log`
   about once a minute (sleep 60 between polls) until the log contains a line
   starting `DONE take=final` or `TAKE FAILED`, or 70 minutes have passed
   (then report a timeout with the last 20 lines of the log; do not kill the
   run). The prompts it types are, in this order:
   - A3 `Provision a vlan 170 on leaf01 ethernet1 for tenant acme`
   - B3 `Deploy an ip-vrf between leaf01 wan1 and leaf02 wan1 for tenant initech with prefix 10.53.0.0/24`
   - C3 `Extend vlan152 as a mac-vrf across leaf01 ethernet1 and leaf02 ethernet1 for tenant blue`
   It must end with a line starting `DONE take=final prompts=3`. If it prints
   `TAKE FAILED`, read the reason in `meta-final.json` (`failed`,
   `framing_problems`) and the log, delete `final.mp4`, and stop: report the
   failure verbatim. Do not retry with different wording and do not edit the
   driver. The identifiers 170, 152 and 10.53.0.0/24 are single-use; a second
   take needs new ones and a human decision.
4. Accept:
   `cd /root/agentic-netops/testautomation/video && /root/agentflow/.venv/bin/python accept.py --take final`
   must print no `FAIL` lines and write `evidence.json` with `"accept_pass": true`.
5. Report, exactly these sections and nothing else: the three prompts and
   their Enter-to-Deployed seconds (from `meta-final.json`); the final
   duration from `ffprobe -v error -show_entries format=duration -of csv=p=0 final.mp4`;
   for each prompt the router proof lines from `evidence.json` (trimmed to the
   matching lines); the `terminal_frames` and `canvas_frames` entries of
   `meta-final.json` (every one must have `"ok": true`); every command whose
   `prompt_returned_on_screen` is false (must be none); the paths of
   `final.mp4`, `evidence.json`, `meta-final.json`, `record-final.log`.

## Hard rules

- Do not modify anything under `/root/agentic-netops` except the output
  directory `/root/agentic-netops/testautomation/video/`. Do not edit
  `record.py`, `accept.py`, the UI, the agents or the deployments.
- Read-only on the routers and the cluster. The driver only runs `redis-cli`
  reads, `vtysh -c 'show ...'`, `bridge vlan show` and `kubectl get`.
- Never state that a service converged unless the Ready condition in
  `evidence.json` says so. Screenshots are for framing, never for pass/fail.
- If a step fails, stop and report with the collected output. Do not deliver a
  video that did not pass `accept.py`.
