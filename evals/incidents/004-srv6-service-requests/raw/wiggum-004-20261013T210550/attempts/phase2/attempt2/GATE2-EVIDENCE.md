# GATE2-EVIDENCE — feature 004-srv6-service-requests, Phase 2 (Foundational, blocking prerequisites)

Date: 2026-10-11 · Workdir: repo root (`/root/agentic-netops`) · All paths workdir-relative.
Scope honored: ONLY this phase's paths were touched; pre-existing dirty files outside the
phase (`.gitignore`, `vendor/sonic-buildimage`, untracked `.mixture-of-loops/`, `tmp_research/`,
`versions.lock.yaml.bak`) were left exactly as found. `lab/profiles/sonic-vm/srv6-supported.yaml`
was deliberately NOT created: nothing proven yet, so the derived capability is honestly "false".

## 1. Gate commands — every one green

| # | Command (executed verbatim) | Result | Proof |
| - | --------------------------- | ------ | ----- |
| 1 | `go build ./...` | clean | `gates/proofs/p2-go-sweep.txt` |
| 2 | `go test ./...` | `ok tests/unit`, `ok tests/envtest` (all packages) | `gates/proofs/p2-go-sweep.txt` |
| 3 | `make test-envtest` | PASS (envtest cases SKIP without `KUBEBUILDER_ASSETS` — baseline behavior, recorded honestly) | `gates/proofs/p2-envtest.txt` |
| 4 | `make verify-pins` | "versions.lock.yaml pins and compatibility are consistent" | `gates/proofs/p2-t020-t021-pins.txt` |
| 5 | `bash scripts/proof.sh selftest -- true` | `proof recorded: selftest (exit 0)` | `gates/proofs/p2-proofsh-replay.txt` |
| 6 | `bash scripts/proof.sh replay selftest` | "1 proof(s) checked, no difference" | `gates/proofs/p2-proofsh-replay.txt` |
| 7 | `bash scripts/proofs/run-q10-baseline.sh` | green — runs "cd agents && pytest tests/unit/test_phrasings_baseline.py" (1 passed) | `gates/proofs/q10-baseline.cmd`, `gates/proofs/q10-baseline.out`, `gates/proofs/p2-restage-proofs.txt` |
| 8 | `bash scripts/proofs/run-q10-srv6.sh` | green — runs "cd agents && pytest tests/unit/test_phrasings_srv6.py" (1 passed; the 5 corpus cases run inside that test) | `gates/proofs/q10-srv6.cmd`, `gates/proofs/q10-srv6.out`, `gates/proofs/p2-restage-proofs.txt` |
| 9 | `bash scripts/proofs/run-q10-guard.sh` | green — runs "cd agents && pytest tests/unit/test_vocabulary_guard.py" (1 passed) | `gates/proofs/q10-guard.cmd`, `gates/proofs/q10-guard.out`, `gates/proofs/p2-restage-proofs.txt` |
| 10 | `bash scripts/proofs/run-p1-agents.sh` — runs "cd agents && pytest" (whole suite) | **304 passed, 4 skipped, 5 deselected** | `gates/proofs/p1-agents.cmd`, `gates/proofs/p1-agents.out`, `gates/proofs/p2-restage-proofs.txt` |

Replay determinism: `scripts/proof.sh replay q10` → "3 proof(s) checked, no difference";
`replay p1-agents` → no difference; `replay selftest` — the command the phase gate itself
executes — no difference (`gates/proofs/p2-restage-replay.txt`). Each proof now runs a script
under `scripts/proofs/` that sources `agents/.venv/bin/activate` itself, so record AND replay
use the same interpreter (the one carrying the `a2a` package). The scripts also export
`OBSERVE_TELEMETRY=false`: the tier's OTLP endpoint (`config/telemetry.py`) is a cluster DNS
name this host cannot resolve, and the exporter's shutdown traceback used to race into the
capture with nondeterministic length — that race made the old full-suite replay flaky, not
red. Test outcomes are unchanged: 304 passed, 4 skipped, 5 deselected.

## 2. Task evidence (tasks.md order)

### Python / agents (T004-T015, T597)
- **T004/T005 baseline phrasings** — `agents/tests/unit/test_phrasings_baseline.py`;
  snapshot `agents/tests/corpus/phrasings/baseline_snapshot.json` (67 cases). Proof: `gates/proofs/q10-baseline.out` (1 passed per case group; whole-suite sweep `gates/proofs/p2-agents-sweep.txt`).
- **T006 unsupported SRv6 corpus** — `agents/tests/corpus/phrasings/unsupported/srv6_transport.yaml` (5 cases, all `expect: refusal`); loader skips `srv6_*` files in `agents/tests/corpus/phrasings/runner.py` so baseline snapshots cannot absorb them.
- **T007 SRv6 phrasings tests** — `agents/tests/unit/test_phrasings_srv6.py` (5 cases, level-1 mapper + level-2 graph R1). Red first: `gates/proofs/p2-t007-prefix-fail.txt`. Green: `gates/proofs/q10-srv6.out`.
- **T008 deterministic mapper recognition** — `agents/provisioning/mapper/agent.py`: `SRV6_UNSUPPORTED_PROPERTY = "srv6Transport"` (exported single source), `_detect_srv6(text)` with case-insensitive `\bsrv6\b`, `\bsegment[- ]routing\s+over\s+ipv6\b`, `\bsegment[- ]routing\s+v6\b` (bare "segment routing" NOT SRv6), detection before service-type/alias/construct patterns; `_map_node` appends `srv6Transport` to `unsupported_properties` (terminal result, `missing_fields` auto-emptied) and coerces the placeholder service type. Vocabulary-guard clean.
- **T009 R1 at the supervisor** — `agents/supervisors/provisioning/graph/graph.py`: imports `SRV6_UNSUPPORTED_PROPERTY` from `provisioning.mapper.agent`; `SRV6_REFUSAL_REASON` ("SRv6 services are not available yet. This request names SRv6, so it is not provisioned as a VXLAN service" — no trailing period, template adds it) and `SRV6_REFUSAL_SUGGESTION` (nothing provisioned, nothing claimed; VXLAN only as an explicit separate request); `_mapper_node` refuses R1 when `srv6Transport ∈ unsupported_properties`, BEFORE the generic unsupported branch, with `stage="mapper"`.
- **T010 refusal-path tests** — `agents/tests/unit/test_refusal_paths.py::TestSRv6InterimRefusal`: R1 end-to-end (FAILED outcome, reason renders the R1 template, no "unsupported properties" leak, transport calls exactly `["mapper"]` — nothing beyond the failing stage — audited refuse, no `mapped_parameters`, no pending action), bare-SRv6 request not diverted to INFORMATIONAL, classifier-prompt rule pinned.
- **T011 classifier routing** — `agents/supervisors/provisioning/prompts/system.py` CLASSIFIER_PROMPT decision-order rule 2: a request naming SRv6 is PROVISIONABLE (so the official R1 refusal reaches the operator rather than a generic unsupported refusal).
- **T012-T015 proofs** — `gates/proofs/q10-baseline.*`, `q10-srv6.*`, `q10-guard.*`, `p1-agents.*` recorded via `bash scripts/proof.sh <name> -- scripts/proofs/run-<name>.sh`; one runner script per proof (`gates/proofs/p2-restage-scripts.txt`), each sourcing `agents/.venv` and exporting `OBSERVE_TELEMETRY=false`. The stored command is the script path, and the declared gate argv is exactly `bash scripts/proofs/run-<name>.sh`, so the gate re-runs the recorded command byte-for-byte (summary elapsed time normalized by `render_out` in `scripts/proof.sh`; replays green in `gates/proofs/p2-restage-replay.txt`).
- **T597 review record** — `docs/SRV6_ACCEPTANCE_004.md` "### R1 — interim SRv6 refusal and classifier routing (T597, phase 2, 2026-10-11)": before/after texts and the proofs; vocabulary guard green over the doc.

### Go capability scoping (T016-T019)
- **T016 test-first** — red captured BEFORE the kind existed: `gates/proofs/p2-t016-red.txt` (`undefined: compat.KindNetwork`). Then `tests/unit/compat_fullvalidate_test.go`: existing FullValidate test updated to `compat.KindNetwork`; new `TestCompat_FullValidateSRv6CapabilityScoping` (Network validates with sai.srv6=false; SRv6Service fails with Reason CapabilityMissing; SRv6Service passes with true). Symbols cited: `TestCompat_FullValidateSRv6CapabilityScoping`.
- **T017** — `pkg/compat/compat.go`: `type ObjectKind string` with `KindNetwork` / `KindNetworkDevice` / `KindSRv6Service`; `Validate(set Set, kind ObjectKind, discovered map[string]bool)`; `requiresSRv6(kind ObjectKind) bool { return kind == KindSRv6Service }` — the SRv6 capability gate applies to SRv6Service only (FR-007). Line-numbered slice: `gates/proofs/p2-t017-t019-slices.txt`.
- **T018** — call sites pass the kind: `controllers/sonicprovider/network_controller.go:168` (`compat.KindNetwork`, with the FR-007 comment), `controllers/sonicprovider/controller.go:152` (`compat.KindNetworkDevice`).
- **T019** — `controllers/srv6service/controller.go:77` (`compat.KindSRv6Service`).

### Image pin + verify-pins (T020-T022)
- **T020** — `versions.lock.yaml` sonic_vm entry pins ONE line `image: local/sonic-vm@sha256:5f3b6c503d67d0b166beba1aedc9e2ccd46b5723f4f932b9a64d8accdb76edd2` (separate `digest:` key removed); the compatibility list carries the same string. Slice: `gates/proofs/p2-t020-t021-pins.txt`.
- **T021** — `scripts/lib/verify_pins.sh` validates sonic_vm against `^local/sonic-vm@sha256:[0-9a-f]{64}$` (lines ~137-141 in slice) and compares the compatibility entry; `make verify-pins` green.
- **T022 LIVE answer** — `gates/proofs/p1-image-by-digest.cmd` / `gates/proofs/p1-image-by-digest.out` (recorded `--destructive`, exit 1 = the honest result) + throwaway topology `gates/proofs/clab-digest-proof/clab.yml` (isolated mgmt subnets `192.168.241.0/24`, `3fff:192:168:241::/64`): containerlab 0.79 normalizes `local/sonic-vm@sha256:<digest>` to a registry reference (`docker.io/local/...`) and PULLS ("pull access denied"); plain docker fails the same ref locally ("No such image") because a `docker import` image carries no repository digest. Decision: the sonic-vm topology names the image by TAG, and bring-up asserts tag↔digest.

### Bring-up + ConfigMap + pins loader (T023-T026, T598, T599)
- **T023 + T598** — `scripts/provision.sh` (before the containerlab deploy, sonic-vm profile only): parses the `sonic_vm` lock entry, requires the one-form digest, requires `docker image inspect local/sonic-vm:202505` to exist, requires image ID == pinned digest (bring-up fails otherwise), prints the pin-verified line and the known-exception WARN. Lines 89-111 in `gates/proofs/p2-provision-t023-t035.txt`.
- **T599** — `lab/profiles/sonic-vm/README.md` "Known exceptions": what (tag instead of digest), why (containerlab cannot resolve a local image by digest — proof `p1-image-by-digest`), guard (provision-time assertion + WARN), remediation (serve from a local registry, then remove the exception).
- **T024** — `scripts/provision.sh` ConfigMap generation: `sonic-image` comes from the ACTIVE profile's lock entry (comment-tolerant entry slicer `image_of()`; sonic-vs-only regex removed). Slice line 276ff in `gates/proofs/p2-provision-t023-t035.txt`.
- **T025** — same heredoc: `cap-sai-srv6` generated as the honest default `"false"` (capability is derived, never guessed) + informational `lab-profile` key. Verified live: both profiles extract correctly (`vm: local/sonic-vm@sha256:...`, `vs: localhost:5000/sonic-vs-gnmi@sha256:...`).
- **T026** — `pkg/compat/pins.go`: `"srv6-supported": "agentic-netops.dev/cap.srv6.supported"` (rides the `agentic-netops.dev/cap.*` label routing in `ResolveSitePins`) and `"lab-profile": "agentic-netops.dev/lab-profile"`. Tests: `tests/unit/compat_pins_test.go` (`TestCompat_AnnotationForDerivedCapabilityKeys`, `TestCompat_ResolveSitePinsRoutesDerivedKeys`). Slice: `gates/proofs/p2-t026-slices.txt`; green in `gates/proofs/p2-go-sweep.txt`.

### Gate reports + capability derivation (T027-T035, T600)
- **T027 TEST-first** — `tests/integration/evpn_srv6_suite.sh` gained `--run seg6-probe-selftest` (installs the suite's own probe route, asserts the encap is VISIBLE). Red with the probe on `dev lo`: `gates/proofs/p2-t027-red.txt` — "the probe's route is not visible with its encap on lo (probe output: `2001:db8:7fff:ffff::/64 dev lo metric 1024 pref medium`)" — the installs-but-drops failure, exit 1.
- **T028** — probe AND witness installs moved to `Loopback0` (fallback `lo` only for nodes without Loopback0; overridable `SEG6_PROBE_DEV`). LIVE on sonic-vm: selftest green — "route installed on Loopback0 and visible with encap (`... encap seg6 mode encap segs 1 [ fc00::1 ] dev Loopback0 ...`)", and `H.Encaps.Red` + `SID-list` witnesses now EXECUTE and assert on both leaves. `gates/proofs/p2-t027-t029-seg6probe.txt`, slices in `gates/proofs/p2-t027-t029-slices.txt`.
- **T029** — a kernel witness whose probe cannot run exits 77 (never `continue` with status 0). Forced-skip proof: `SEG6_PROBE_DEV=lo tests/integration/evpn_srv6_suite.sh --run H.Encaps.Red` → exit 77 with the explicit note (`gates/proofs/p2-t027-t029-seg6probe.txt`).
- **T030** — `scripts/lib/qualify.sh`: exit 77 recorded as `skip` (skip is not pass, not fail, does not gate); report gains `"totals":{"passed":N,"failed":N,"skipped":N}`; `result` is pass iff failed==0. Slices: `gates/proofs/p2-t030-t600-slices.txt`; live shape in `gates/proofs/q14-report-vm.out`.
- **T600** — `scripts/lib/qualify.sh --print-report-path` prints the report path and exits 0; `scripts/lib/capability.sh` takes the path from it (never a literal) — the only occurrence of the path literal is inside qualify.sh itself.
- **T031 TEST-first** — fixtures `tests/fixtures/qualify/{all-pass,one-skip,one-fail,no-verdict}/qualify.report.json` + `tests/unit/capability_derive_test.sh` (derives `true` ONLY for all-pass). Red: `gates/proofs/p2-t031-red.txt` (no `scripts/lib/capability.sh`).
- **T032** — `scripts/lib/capability.sh`: `cap-sai-srv6` = "true" iff report result pass (path via `capability::default_report_path` → `qualify.sh --print-report-path`) AND `SRv6-Underlay`, `End`, `End.DT46`, `H.Encaps.Red`, `SID-list`, `Decapsulation` all `pass` (none `skip`) AND `lab/profiles/<profile>/srv6-supported.yaml` lists ≥1 `proven` variant; otherwise both keys derive "false". Profile name read from `AGENTIC_NETOPS_PROFILE` (default sonic-vs) — NOT an input. Green: `gates/proofs/p2-t032-capability.txt` (6/6 ok).
- **T033** — `scripts/provision.sh` post-gate derivation patches `cap-sai-srv6` + `srv6-supported` into `fabric-compat-pins` (`capability::derive`, lines ~404-417 in `gates/proofs/p2-provision-t023-t035.txt`); a failed gate exits BEFORE the patch, leaving "false". Patch path exercised live against the cluster (honest false/false — no srv6-supported.yaml exists this phase).
- **T034** — sample `SRv6Service` apply + `kubectl wait ... || true` removed from `scripts/provision.sh`; no readiness wait in the file ends in `|| true` (grep proof in `gates/proofs/p2-provision-t023-t035.txt`).
- **T035** — stale gate message corrected to match versions.lock.yaml: sonic_vs runs the core gNMI capability gate; full EVPN/SRv6 conformance runs on sonic_vm (line 393 in `gates/proofs/p2-provision-t023-t035.txt`).

### Live checks (T036-T039)
- **T036 `q14-gate-vm`** — full `scripts/lib/qualify.sh` on the LIVE sonic-vm lab, recorded via `scripts/proof.sh --destructive` (`gates/proofs/q14-gate-vm.cmd` / `q14-gate-vm`** — full `scripts/lib/qualify.sh` on the LIVE sonic-vm lab, recorded via `scripts/proof.sh --destructive` (`gates/proofs/q14-gate-vm.out`, exit 0): `[qualify] OK`, and for the first time `H.Encaps.Red` and `SID-list` EXECUTE ("seg6 encap.red programmed and read back" / "seg6 encap programmed and read back" on BOTH leaves) instead of auto-skipping.
- **T037 `q14-report-vm`** — `cat "$(scripts/lib/qualify.sh --print-report-path)"` (`gates/proofs/q14-report-vm.out`): 17 tests, `totals {"passed":17,"failed":0,"skipped":0}`, `result "pass"` — totals.passed equals the checks that ran and passed; skipped is separate (zero here because nothing was skipped on this kernel).
- **T038 `q14-probe`** — `tests/integration/evpn_srv6_suite.sh --run seg6-probe-selftest` passes (`gates/proofs/q14-probe.out`).
- **T039 `p1-network-unaffected`** — `gates/proofs/p1-network-unaffected.cmd` / `p1-network-unaffected`** — `gates/proofs/p1-network-unaffected.out`: the provider was REDEPLOYED from this tree (CGO_ENABLED=0 linux build → `docker import` USER 65532:65532 → `kind load docker-image` → rollout restart — the running pod predated T017/T018). With `cap-sai-srv6` **false** in `fabric-compat-pins`, all 7 `Network` objects in `agentic-netops-intent` reconcile PAST the compatibility gate into the apply stage (`Ready=False/ApplyFailed` at 19:07:37-39Z — the sonic-vm guest lacks `redis-cli` for the feature-003 `migr-*` executor ops; an apply-stage condition is only reachable AFTER `compat.FullValidate(..., compat.KindNetwork, ...)` passed). No `CapabilityMissing`, no `SchemaMismatch` anywhere. Cross-check in unit terms: `TestCompat_FullValidateSRv6CapabilityScoping` subtest `network_validates_with_cap-sai-srv6_false` (`gates/proofs/p2-go-sweep.txt`).

## 3. Honest states and deliberate non-actions
- `lab/profiles/sonic-vm/srv6-supported.yaml` NOT created — nothing proven yet; the derived `cap-sai-srv6` / `srv6-supported` in the live ConfigMap are "false" / "false" and the derivation only flips them on a proven gate.
- envtest SKIPs are the documented baseline on this host (no `KUBEBUILDER_ASSETS`); `make test-envtest` is green with them.
- The sonic-vm image is named by TAG in `lab/topology.sonic-vm.clab.yml` — a recorded known exception (T599) with a bring-up digest assertion (T023) and a WARN at every sonic-vm bring-up (T598), because containerlab cannot resolve a local image by digest (T022 live proof).
- `scripts/proof.sh` `render_out` normalizes only the volatile summary elapsed time; no stored command changed meaning.

## 4. Vocabulary guard
`cd agents && pytest tests/unit/test_vocabulary_guard.py` green (retired words absent from
README/TUTORIAL/docs/supervisors/mapper/ui except migration-alias-marked or historically-marked
lines) — `gates/proofs/q10-guard.out`, `gates/proofs/p2-agents-sweep.txt`.
