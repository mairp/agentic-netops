# Host runbook — running Phases 4-6 with wiggum on Opus 5

This is the operator's runbook for the live half of the SR Linux migration:
bringing the fabric up, driving the four constructs to `Ready=True`, and
recording the walkthrough. Phases 1-3 are offline and already in the tree;
this runbook starts from a clone of that tree on the lab host and ends with an
accepted `final.mp4` and an acceptance report.

Feature slug: `001-agentic-netops-srlinux-evpn-fabric`
Plan: [`specs/001-agentic-netops-srlinux-evpn-fabric/plan.md`](../specs/001-agentic-netops-srlinux-evpn-fabric/plan.md)
Tasks: [`specs/001-agentic-netops-srlinux-evpn-fabric/tasks.md`](../specs/001-agentic-netops-srlinux-evpn-fabric/tasks.md)

Everything below has been written from the tree, not from a completed run:
**no phase of this runbook has been executed yet.** Where a step says what an
output looks like, that is the contract the step must meet, not a transcript.

---

## 1. Prerequisites

### 1.1 Host tooling

A Linux host with, at minimum:

| Tool | Why | Check |
|---|---|---|
| `docker` | kind and containerlab | `docker info` |
| `kind` | the Kubernetes cluster | `kind version` |
| `kubectl` | everything | `kubectl version --client` |
| `containerlab` | the SR Linux fabric | `containerlab version` |
| `go` (1.22+) | vendored controller build | `go version` |
| `python3` 3.13 + `uv` | the agent tier and its tests | `uv --version` |
| `node` 20 + `npm` | the console build | `node -v` |
| `gnmic` | bootstrap, capability gate, suites | `gnmic version` |
| `jq`, `yq`, `curl` | lifecycle scripts | |
| `ffmpeg`, `Xvfb`, `xdotool`, `ttyd` | Phase 6 recording | |
| `claude` CLI | the wiggum proposer and critic | `claude --version` |

`./scripts/install-deps.sh` installs the pinned versions of the lab tooling.
`scripts/lib/preflight.sh` enforces the CPU/RAM/disk floor (4 vCPU, 8 GiB,
20 GiB free); the four SR Linux containers want ~1.5-2 GiB each, so 16 GiB is
the realistic figure with the intent tier running. There is **no** KVM
requirement on this target.

Resource and context traps are in [DEPENDENCIES.md](DEPENDENCIES.md) — read it
before the first provision. The two that cost the most time: `provision.sh`
dry-runs against your **current kubectl context**, and `kubectl top` returns
nothing without metrics-server, which kind does not install.

### 1.2 The model key and `.env`

The intent tier needs a model. Copy the example and fill in one provider block:

```bash
cp .env.example .env
$EDITOR .env
# LLM_MODEL is always the model variable; its prefix picks the LiteLLM provider.
# e.g. LLM_MODEL=openai/gpt-5   OPENAI_API_KEY=...   OPENAI_BASE_URL=https://api.openai.com/v1
```

`.env` is gitignored and becomes `Secret/llm-provider` at provision time. With
no model configured the tier deploys but cannot reason, and every prompt fails
at classification.

This key is for the **agents**. It is unrelated to the key the `claude` CLI
uses for wiggum's proposer and critic.

### 1.3 The wiggum orchestrator

```bash
git -C /root/wiggum rev-parse --short HEAD   # the clone must exist
test -x /root/wiggum/orchestrator.sh
```

`scripts/run-loop.sh` looks for `/root/wiggum/orchestrator.sh`; override with
`ORCH=/path/to/orchestrator.sh` if it lives elsewhere.

### 1.4 The claude CLI

The proposer and the critic both run through the `claude` CLI, so it must be
logged in on this host **before** the loop starts — an unauthenticated CLI
fails every proposal and the loop burns iterations on it.

```bash
claude --version
claude -p 'reply with the single word: ok'    # must print ok
```

---

## 2. Place the repository

Clone the SR Linux repository into its own directory (the tutorial and the
video docs assume this path):

```bash
git clone https://github.com/mairp/agentic-netops-srlinux.git /root/agentic-netops-srlinux
cd /root/agentic-netops-srlinux
git checkout 001-agentic-netops-srlinux-evpn-fabric   # or main, once merged
```

If the repository does not exist yet, create and push it from the authoring
clone with `./scripts/bootstrap-srlinux-repo.sh` (dry-run first:
`./scripts/bootstrap-srlinux-repo.sh --dry-run`). That script never touches the
`origin` remote; it adds `srlinux` and pushes the current branch to `main`
there.

Pull the fabric image before anything else — it is the largest single download
and everything downstream waits on it:

```bash
docker pull ghcr.io/nokia/srlinux:26.7.2
docker images --digests | grep srlinux
# the digest must equal versions.lock.yaml srlinux_images.srlinux.digest
```

---

## 3. Re-verify gates 1-3 offline, on this host

The loop starts from a proven tree, so run the offline checkpoints here before
phase 4. Nothing in this section touches Docker, kind or containerlab.

```bash
cd /root/agentic-netops-srlinux

# Gate 1 — foundation: pins, topology, lifecycle scripts
./scripts/lib/verify_pins.sh
python3 -c 'import yaml,sys; list(yaml.safe_load_all(open("lab/topology.clab.yml")))'
bash -n scripts/*.sh scripts/lib/*.sh scripts/ci/*.sh
bash scripts/ci/supply_chain.sh

# Gate 2 — southbound: renderer, executor, provider
go build -mod=vendor ./...
go build -mod=vendor -tags agentic_netops_k8s ./cmd/... ./controllers/...
go vet  -mod=vendor -tags agentic_netops_k8s ./cmd/fabric-executor ./controllers/...
go test -mod=vendor ./tests/unit ./pkg/...
make verify-register
grep -n "docker" cmd/fabric-executor/main.go        # must print nothing

# Gate 3 — platform surfaces: telemetry, manifests, agents, UI, docs, driver
make verify-pins
python3 -m json.tool deploy/observability/dashboards/*.json > /dev/null
python3 -c 'import yaml,sys; [list(yaml.safe_load_all(open(f))) for f in sys.argv[1:]]' deploy/**/*.yaml
python3 -m py_compile testautomation/video/*.py
( cd agents && uv sync --frozen && uv run ruff check . && uv run pytest -q )
( cd ui && npm ci && npm run typecheck && npm run build )
```

If any of these fails, fix it in the tree and re-run. Starting the loop on a
tree that does not pass its own offline gates wastes a live phase.

---

## 4. Start the loop

```bash
cd /root/agentic-netops-srlinux
WIGGUM_PROPOSER=claude ANTHROPIC_MODEL=claude-opus-5 ./scripts/run-loop.sh
```

`run-loop.sh` already exports both with those defaults, so a bare
`./scripts/run-loop.sh` does the same thing; passing them explicitly documents
the intent in the shell history and lets you override either one.

What the variables mean:

- `WIGGUM_PROPOSER=claude` selects the Claude backend for the proposer.
- `ANTHROPIC_MODEL=claude-opus-5` selects the model. wiggum passes **no**
  `--model` flag for the claude backend; Claude Code reads `ANTHROPIC_MODEL`
  from the environment, which is why it is exported rather than passed as an
  argument.
- The **critic** stays on wiggum's default claude backend. Do not change it to
  match the proposer: the point of the critic is that it is not the proposer.

Other environment the script honours:

| Variable | Default | Meaning |
|---|---|---|
| `FEATURE` | `001-agentic-netops-srlinux-evpn-fabric` | the feature slug under `specs/` and `.wiggum/features/` |
| `ORCH` | `/root/wiggum/orchestrator.sh` | the orchestrator entry point |
| `LOKI_URL` | `http://127.0.0.1:3100` | telemetry probe target |
| `OTEL_URL` | `http://127.0.0.1:4318` | telemetry probe target |
| `GRAFANA_URL` | `http://127.0.0.1:3000` | printed in the banner |

Flags:

```bash
./scripts/run-loop.sh          # live timeline + telemetry
./scripts/run-loop.sh --quiet  # no live view (use when running under nohup)
./scripts/run-loop.sh --stop   # set the stop flag; the loop halts cleanly
```

For a long unattended run:

```bash
setsid nohup ./scripts/run-loop.sh --quiet > .wiggum/run-loop.log 2>&1 &
```

---

## 5. What each live phase produces

Evidence lands under
`.wiggum/features/001-agentic-netops-srlinux-evpn-fabric/gates/proofs/`.
A phase gate approves only on evidence that is actually there; a missing proof
file is a failed gate, not a warning.

### Phase 4 — bring-up (T039-T044)

| Task | Produces |
|---|---|
| T039 | `srlinux-image.txt` — `docker images --digests \| grep srlinux` |
| T040 | `provision.log` — a clean `./scripts/provision.sh --profile srlinux --cluster-name agentic-netops` |
| T041 | `qualify.report.json` — every gNMI and EVPN test `pass`, SRv6 entries `not-applicable` with their reason; `make lab-qualify` prints `[qualify] OK` |
| T042 | `fabric-verify.log` — `./tests/integration/fabric_verify.sh run` exit 0, every assertion line passed |
| T043 | a second `fabric-verify` log after `docker restart clab-agentic-netops-fabric-leaf01` |
| T044 | `curl :9273/metrics` counts for four sources; refreshed `docs/images/grafana-fabric-telemetry.png` and `docs/images/grafana-physical-fabric.png` |

Anything the live image rejects — startup-config syntax, a gNMI path, the save
command — is fixed **in the Phase 1/2 tree files and re-applied**, never as a
manual change on a node. A node carrying configuration that is not in the tree
invalidates every later proof.

### Phase 5 — intent tier convergence (T045-T052)

| Task | Produces |
|---|---|
| T045 | all six tier deployments Ready; UI on `:30000` healthy |
| T046 | `construct-vlan/` — `kubectl get network -o json` plus `sr_cli "show network-instance vlan-<id> interfaces"` |
| T047 | `construct-ip-vrf/` — NI summary, route table, and the EVPN Type-5 **on the peer leaf** |
| T048 | `construct-mac-vrf/` — both leaves' NI summary and the `multicast-destinations` list (the remote VTEP) |
| T049 | `construct-acl/` — `show acl acl-filter …` and the subinterface binding |
| T050 | drift repair: delete the vlan network-instance on leaf01 with `sr_cli` (the only sanctioned write outside the executor, for this test), wait one resync (≤ 5 min), `Ready` returns True with an `ApplySucceeded` event |
| T051 | the refusal path: a prompt naming `ethernet9` refused by the translator, naming the site's real ports; supervisor audit line saved |
| T052 | `README.md` "What works" paragraph and `docs/INTENT_TIER_SERVICE_TYPES.md` updated with the dates and the measured Enter-to-Deployed seconds |

### Phase 6 — walkthrough recording (T053-T058)

| Task | Produces |
|---|---|
| T053 | refreshed site ground truth in `docs/DEMO_VIDEO_PROMPT.md`, and the single-use identifiers chosen |
| T054 | `record.py --smoke --take smoke` exit 0 with `commands without a returned prompt: none` |
| T055 | a rehearsal (no video) with the primed identifiers and per-prompt Enter-to-Deployed seconds |
| T056 | `final.mp4`, the only `.mp4`, ending `DONE take=final prompts=3` |
| T057 | `evidence.json` with `accept_pass: true`, copied to `docs/media/agentic-netops-srlinux-intent-tier-demo-evidence.json` |
| T058 | `final.mp4` uploaded as a repository asset and the README Demo section pointing at it |

The full Phase 6 procedure is in [DEMO_VIDEO_RETAKE.md](DEMO_VIDEO_RETAKE.md);
the prompt list, the proof commands and the ground-truth template are in
[DEMO_VIDEO_PROMPT.md](DEMO_VIDEO_PROMPT.md).

---

## 6. Watching a run

```bash
wiggum watch                    # the live timeline
tail -f .wiggum/features/001-agentic-netops-srlinux-evpn-fabric/runs/<run_id>/run.log
cat  .wiggum/features/001-agentic-netops-srlinux-evpn-fabric/PROGRESS.md
ls   .wiggum/features/001-agentic-netops-srlinux-evpn-fabric/gates/
ls   .wiggum/features/001-agentic-netops-srlinux-evpn-fabric/debug/invocations/   # with --debug
```

`run-loop.sh` prints a banner with the Loki queries for this run; `$TASK` is
the working directory's basename (`agentic-netops-srlinux` if you cloned to the
path in section 2). In Grafana → Explore → Loki:

```
{job="ralph", task="agentic-netops-srlinux"}                                   # everything
{job="ralph", task="agentic-netops-srlinux", event="reject"}                    # critic rejections
{job="ralph", task="agentic-netops-srlinux", event=~"phase_start|phase_done"}   # phase boundaries
{job="ralph", task="agentic-netops-srlinux", event="gate_oscillation"}          # stuck: the same gate flipping
```

The banner also probes Loki, OTLP and Grafana and prints `✓`/`✗` for each. A
`✗` is not fatal: events still land in `run.log`, you just lose the live view.

If `gate_oscillation` appears, the loop is proposing and rejecting the same
change repeatedly. Stop it, read the last rejection in `run.log`, and fix the
underlying disagreement (usually a gate whose evidence cannot exist as written)
rather than re-running.

---

## 7. Stopping and resuming

```bash
./scripts/run-loop.sh --stop    # sets .wiggum/stop.flag
```

The loop halts at its next checkpoint and exits **6**, which is a clean stop,
not a failure. To resume, simply start it again:

```bash
./scripts/run-loop.sh
```

The script removes a leftover stop flag on start — a stale flag would
otherwise make the next run exit 6 immediately. State lives in
`.wiggum/features/<slug>/`, so a resumed run picks up at the first unapproved
task rather than redoing approved ones.

A hard kill (`Ctrl-C`, SIGKILL) leaves the current task unapproved; that is
safe — the next run re-attempts it. What is *not* safe is a hard kill in the
middle of `provision.sh` or a recording: clean those up before resuming
(`./scripts/off.sh --delete-kind true`, or delete the partial `.mp4`).

---

## 8. Site ground truth to refresh before the video take

Do this immediately before Phase 6 (task T053) and paste the answers into the
appendix of [DEMO_VIDEO_PROMPT.md](DEMO_VIDEO_PROMPT.md) with the date. Every
item is read-only.

- [ ] **Free VLAN ids.** `sr_cli "show network-instance summary"` on both
      leaves. The bootstrap mac-vrf `vlan100` and ip-vrf `VrfBlue` are always
      present; any `vlan-<id>` from an earlier construct is consumed. Pick
      three ids that appear nowhere, and use each exactly once.
- [ ] **Free VNIs.** `sr_cli "show tunnel-interface vxlan1 vxlan-interface brief"`.
      L2VNI 100 and L3VNI 2000 are the bootstrap's.
- [ ] **Free prefixes.** Grep every `Network` spec in `agentic-netops-intent`
      for the candidate prefix; it must return zero.
- [ ] **Existing Networks and what they hold.** `kubectl -n agentic-netops-intent
      get networks.network.kubenet.dev -o wide` plus each one's `attachments`.
      A `Network` that is not Ready and binds an ACL on an interface will make
      any new ACL prompt on that interface fail the deployer pre-flight — that
      is why the ACL prompt names `wan1`.
- [ ] **Subinterfaces already on the attachment interfaces.**
      `sr_cli "show interface ethernet-1/3 detail"` and `ethernet-1/4`.
- [ ] **`sr_cli` show syntax verified on the image.** Run
      `cd testautomation/video && python record.py --smoke --take smoke`. It
      must end with `commands without a returned prompt: none`. A command the
      image rejects is corrected in `record.py`, `accept.py` and
      `docs/DEMO_VIDEO_PROMPT.md` **together**, before the take.
- [ ] **Suggestion cards vs the one-construct rule.**
      `curl -s http://127.0.0.1:30000/api/suggested-prompts` and check each
      card against the supervisor's `\b(vlan|mac[- ]?vrf|ip[- ]?vrf|acl)\b`
      refusal. Record which cards trip it; the take types the sanctioned prompt
      list, not the cards.
- [ ] **Deployer convergence bound in force.**
      `kubectl -n agentic-netops-agents get deploy deployer -o json` →
      `DEPLOYER_CONVERGENCE_TIMEOUT_SECONDS`. The driver's own wait must cover
      it with margin.
- [ ] **No leftover `.mp4`.** `ls testautomation/video/*.mp4` must list nothing.

---

## 9. Acceptance report format

The report at the end of Phase 6 mirrors step 5 of
[DEMO_VIDEO_RETAKE.md](DEMO_VIDEO_RETAKE.md). Output exactly these sections and
nothing else — no adjectives about quality, no summary of how it went:

1. **Prompts used and their Enter-to-Deployed seconds** — the three prompts
   verbatim as typed, with the seconds from `meta-final.json`.
2. **Final duration** —
   `ffprobe -v error -show_entries format=duration -of csv=p=0 final.mp4`.
3. **Device proofs, verbatim** — for each prompt, the proof lines from
   `evidence.json`, trimmed to the matching lines (the `vlan-<id>` interfaces
   row, the peer leaf's Type-5 for the prefix, the `multicast-destinations`
   entry carrying the peer's system IP, the acl-filter entries and binding).
4. **Framing results** — the `terminal_frames` and `canvas_frames` entries of
   `meta-final.json`; every one must have `"ok": true`.
5. **Commands whose prompt did not return** — every entry whose
   `prompt_returned_on_screen` is false. Must be none.
6. **Paths** — `final.mp4`, `evidence.json`, `meta-final.json`,
   `record-final.log`.

Additionally, for the migration's own gate:

7. **Where the evidence lives** — the files under
   `.wiggum/features/001-agentic-netops-srlinux-evpn-fabric/gates/proofs/` that
   back phases 4, 5 and 6, and the `GATE4-EVIDENCE.md` / `GATE5-EVIDENCE.md` /
   `GATE6-EVIDENCE.md` notes that cite them.
8. **Corrections made to the tree during the live phases** — every startup-config,
   gNMI path or show-command fix, with the task it belonged to. A live phase
   that needed no correction says so explicitly; a phase that needed one and
   does not name it is not accepted.

If any criterion fails, report the failure with the collected output and stop.
Do not deliver a video that did not pass `accept.py`, and do not describe a
service as converged unless its `Ready` condition in `evidence.json` says so.
