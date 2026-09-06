# Every suggested prompt was unrunnable — postmortem

**Date:** 2026-09-06
**Trigger:** an operator clicked a prompt the chat surface itself offers and got

```
one construct per request; you named: mac-vrf, vlan.
Supported constructs: vlan, mac-vrf, ip-vrf, acl
Suggestion: provision it declaratively instead — e.g. 'extend vlan 100 as a mac-vrf
across <siteA> <portA> and <siteB> <portB> for tenant <tenant>' ...
```

The refusal's own suggested phrasing was the phrasing that had just been refused.

**Scope:** the full path from the served prompt to the proposal — the supervisor's
deterministic guards, the mapper's parse, the allocator's normalization — and the test
and CI machinery that was supposed to catch all of it.

**Resolution:** commit `12144252` (45 files). Verified live: all six served prompts map
and reach the first confirmation gate.

---

## TL;DR

| Layer | State before | State now |
|---|---|---|
| Supervisor guard (T072) | Refused 3 of 6 served prompts and its own worked examples | Counts service requests, not construct tokens |
| Mapper (`provisioning/mapper/agent.py`) | Feature-002 rules; 5 of 6 prompts unmappable | Construct semantics; all 6 map |
| Allocator (standalone acl) | Dropped `interpretation.acl` | Filter travels with every construct |
| `uv run pytest` (CI) | Aborted at collection — **zero** agent tests ran | 299 passed, 4 skipped, 5 deselected |
| `ruff check .` (same CI job) | 183 findings | clean |
| Adversarial corpus | Script-only, rotted to 22/33 unnoticed | 33/33, wired into pytest |
| Prompt coverage | Regex assertions only | Real supervisor graph + real mapper, per prompt |

---

## Root cause

Four independent defects sat on the same path. Each one alone would have produced a
bad-but-explainable answer; together they made the advertised surface unusable.

### 1. The guard counted construct *tokens*, not construct *requests*

`agents/supervisors/provisioning/graph/graph.py` — the T072 guard is the first thing a
message meets, before classification. It refused any message naming two construct words.
But `extend vlan 150 as a mac-vrf across …` names **one** service whose vlan is the
mac-vrf's tag, and that is the canonical phrasing everywhere in this repo: the served
suggestions, the US5 corpus, `DEFAULT_SUGGESTION`, `CLARIFICATION_HINT`, and the mapper
catalogue's own examples. Following the refusal's advice therefore earned the same
refusal — a closed loop with no exit.

The spec's intent (spec.md Edge Cases) is "an operator asks for two constructs" — two
*services*, e.g. "a mac-vrf and an ip-vrf". The implementation encoded "two words".

### 2. The mapper was never migrated to the construct vocabulary

`agents/provisioning/mapper/agent.py` is a deterministic regex mapper (no model call). It
still carried its feature-002 rules through the whole of feature 003:

- `_SERVICE_PATTERNS` matched `vlan` **first**, so every overlay phrasing mapped to a
  plain vlan and silently dropped the EVPN service that was asked for;
- endpoints were parsed from `between A and B` / `attach A and B` but **not**
  `across A and B` — the phrasing three of the six served prompts use;
- **two** endpoints were required for every construct, though research.md Decision 11
  sets `vlan` / `ip-vrf` / `acl` at one, so single-attachment prompts were unmappable;
- no `acl` block and no `anycast_gateway` were ever built, so an acl request failed
  `Interpretation` validation *inside* the mapper (`acl: required when service_type ==
  acl`) and the operator was told their **endpoints** were missing — the one part of the
  request that was complete.

### 3. The allocator dropped the filter

`agents/provisioning/allocator/agent.py` built the standalone-acl intent from
serviceId/type/tenant/endpoints only. A confirmed access list reached the deployer
carrying no rules — a service that forwards exactly what the operator asked to block.

### 4. Nothing that ran could see any of it

- `uv run pytest` **aborted at collection**: `tests/unit/test_phrasings_positive.py`
  imported `agents.tests.corpus.phrasings` while `agents/` is itself the import root. One
  bad import meant zero agent tests ran in CI, for as long as it had been there.
- Had it run, it would have shown 23 failures — 13 in `tests/e2e` (missing `thread_id`
  on `ainvoke`, repo-root-relative paths under a rootdir of `agents/`, a stub that never
  unfenced the tool request, `pending_action` names the graph has not used since feature
  002) and 10 more that failed *only in collection order*, because
  `test_restart_midrequest.py` assigned `graph_mod.CHECKPOINT_DB_PATH` directly instead
  of via monkeypatch and left every later graph in the process sharing one SQLite file.
- The one test that did cover suggested prompts asserted **regexes**, not behaviour: it
  checked that each prompt matched the fallback classifier's two patterns. Both matched
  perfectly while the request was refused one layer earlier.
- The graph tests that do run prompts end to end use the corpus runner's **stub mapper**,
  which — because it was written later, against the construct spec — was *more correct
  than production*: it already ordered `vlan` last and knew what "across" meant. The stub
  passing is what made the suite look healthy.

### Why the four lined up

The same parsing knowledge is implemented three times — the supervisor's fallback
classifier, the real mapper, and the corpus stub — with no shared source of truth. When
feature 003 changed the vocabulary, two of the three were updated and the third (the one
in the request path) was not. The test suite compared the two updated copies to each
other.

---

## How it was resolved

| Defect | Fix |
|---|---|
| Guard counts tokens | `_find_constructs` now drops a `vlan` used as an overlay's tag (no determiner) and an `acl` introduced by an attachment preposition; "a mac-vrf and an ip-vrf" is still two |
| vlan matched first | `_SERVICE_PATTERNS` matches VLAN **last**, as the corpus runner already did |
| "across" unknown | `_ENDPOINT_BETWEEN` accepts `between|across` |
| Two endpoints required | Per-construct minimum: `mac-vrf` 2, everything else 1 (Decision 11) |
| No acl / gateway | `_parse_acl` and `_parse_anycast_gateway`; a filter clause attaches to **any** construct; a stage is never guessed |
| Prefixes scooped from any CIDR | Only an `ip-vrf` carries address families; a gateway or ACL prefix is not one |
| Allocator dropped the acl | `_normalized_acl` translates `default_action` → `defaultAction` and every branch carries it |
| Prompt 6 unmappable | The served text names its stage (`ingress`), in the JSON **and** the ConfigMap |
| CI never ran | Import fixed; 13 e2e tests repaired; checkpoint-path leak monkeypatched; 183 lint findings cleared |
| `make` from another cwd | `$(PWD)` → `$(CURDIR)` (this is why the lifecycle-idempotence job died with 127) |

New guards, all in `agents/tests/unit/`:

- `test_suggested_prompts_runnable.py` — every served prompt **and every worked example
  the tier quotes in its own refusal and clarification text** through the real supervisor
  graph: past every deterministic guard, to `confirm_1`, with the construct it named.
- `test_suggested_prompts_map.py` — every served prompt through the **real mapper**:
  complete interpretation, right construct, the endpoints the prompt spells out, and the
  filter it asks for.
- `test_adversarial_corpus.py` — runs the adversarial corpus in pytest so it cannot rot
  silently again.

---

## Preventing a recurrence

Ranked by how much of this class they remove.

1. **Test the artifact you ship, through the components that serve it.** The regex test
   was true and useless. The two new modules read `suggested_prompts.json` itself, so a
   prompt added later is covered without anyone remembering to cover it. *(Done.)*
2. **Assert on the operator's exit, not just the happy path.** The refusal and
   clarification text quote worked phrasings; those are now extracted from the constants
   and executed. A refusal whose advice is refused is a dead end, and no unit assertion
   short of running it will see it. *(Done.)*
3. **A collection error must be as loud as a failure.** `uv run pytest` returning
   non-zero was correct, but nothing acted on it. Consider a floor in CI — assert the
   collected test count is at or above a known number — so "zero tests ran" cannot look
   like a passing lane. *(Not done; proposed.)*
4. **Collapse the three parsers into one.** The supervisor's fallback classifier, the
   mapper and the corpus stub each re-implement "what does this sentence ask for". Until
   the stub *is* the mapper (or defers to it), a corpus run can keep passing while the
   request path is broken. *(Not done; the largest remaining structural risk.)*
5. **Close the acl clarification gap in the contract.** `Interpretation` requires the
   `acl` block whenever `service_type == acl`, so a stage-less acl request has no
   schema-valid way to *ask* for the stage — it can only fail validation. Either relax the
   requirement when `missing_fields` is non-empty (a clarification is not an
   interpretation) or state in the contract that acl clarifications ride on the top-level
   fields. *(Not done; documented here and in the corpus.)*
6. **Keep the duplicated prompt copies pinned.** `suggested_prompts.json`, the
   `supervisor-prompts` ConfigMap and the UI's offline fallback are three copies of one
   list; the existing tests pin them together. Any fourth copy must be pinned on arrival.
   *(Already in place — and it is what caught the ConfigMap drift a day earlier.)*

---

## Mitigation — when a prompt misbehaves again

Work **downwards**; the failure is usually below the layer the message names.

```bash
cd agents

# 1. Does the deterministic layer refuse it, before any classification?
.venv/bin/python -c "
import sys; sys.path.insert(0,'.')
from supervisors.provisioning.graph.graph import (
    _find_constructs, detect_direct_device, detect_unsupported_feature, fallback_classification)
t = 'extend vlan 150 as a mac-vrf across leaf01 ethernet1 and leaf02 ethernet1 for tenant blue'
print(_find_constructs(t), detect_direct_device(t), detect_unsupported_feature(t), fallback_classification(t))"

# 2. Does the REAL mapper read it? (deterministic — no model, no cluster)
.venv/bin/python -c "
import sys, asyncio; sys.path.insert(0,'.')
from provisioning.mapper.agent import MappingAgent
async def m():
    _msg, i = await MappingAgent().ainvoke('<the prompt>')
    print(i.model_dump(exclude_none=True))
asyncio.run(m())"

# 3. Do the guards still hold and does the whole set still map?
.venv/bin/python -m pytest tests/unit/test_suggested_prompts_map.py \
                           tests/unit/test_suggested_prompts_runnable.py -q

# 4. What is actually SERVED (the ConfigMap is mounted over the file):
kubectl -n agentic-netops-agents port-forward svc/supervisor 19090:9090 &
curl -s localhost:19090/suggested-prompts

# 5. End to end against the running tier:
curl -s -X POST localhost:19090/agent/prompt/stream -H 'content-type: application/json' \
  -d '{"prompt":"<the prompt>","thread_id":"triage-1"}'
```

Reading the NDJSON: `type: stage` carries the mapped interpretation, `confirmation_request`
means it reached the gate, `clarification_request` names the fields the mapper could not
read, and `refusal_reason` (if present) names the guard that stopped it.

After changing agent source, the running tier keeps the old behaviour until the image is
rebuilt and reloaded:

```bash
docker build -f docker/Dockerfile.mapper -t agentic-netops/intent-mapper:latest .
kind load docker-image agentic-netops/intent-mapper:latest --name agentic-netops
kubectl -n agentic-netops-agents rollout restart deploy/mapper
# and, when the served prompt list changed:
kubectl apply -f deploy/agents/supervisor.yaml   # the ConfigMap is what is served
kubectl -n agentic-netops-agents rollout restart deploy/supervisor
```

---

## Two operational incidents during the fix

### The e2e marker purged the live lab

Reproducing the CI job with `pytest -m e2e -k lifecycle_idempotence` executed
`scripts/off.sh --purge-intent-tier`, which tore down the intent tier **and** the
containerlab fabric on the running lab. `provision.sh --with-intent-tier` restored both;
the `llm-provider` Secret could not be restored, because only the operator holds the
gateway model and key:

```bash
export AGENTIC_NETOPS_LLM_MODEL=openai/gpt-5
export AGENTIC_NETOPS_LLM_API_KEY=<key>
export AGENTIC_NETOPS_LLM_BASE_URL=https://api.core42.ai/v1
./scripts/provision.sh --profile sonic-vs --cluster-name agentic-netops --with-intent-tier
```

**Root cause:** the `e2e` marker means two different things — read-only cluster tests, and
tests that provision and purge for real — and nothing distinguished them.

**Fix applied:** the destructive pair is now opt-in behind
`AGENTIC_NETOPS_ALLOW_DESTRUCTIVE_E2E=1`, which CI's ephemeral runner sets and a lab host
does not. `pytest -m e2e` on a live host now skips them with the reason printed.

### The Docker daemon wedged at its fd ceiling

Repeated `kind load` calls surfaced (not caused) a long-running leak: `dockerd` held
**524,287 of 524,288** file descriptors, ~523,700 of them unix sockets on
`/var/run/docker.sock` with no client attached. `docker ps` hangs; kubectl and already
running containers are unaffected, since they are held by containerd.

**Mitigation:** only a daemon restart clears them, and without `live-restore` that bounces
every container on the host — the kind cluster, the containerlab fabric and the fleet
services. Schedule it. Setting `{"live-restore": true}` in `/etc/docker/daemon.json`
first would make future daemon restarts non-disruptive.

**Diagnosis command:**

```bash
pid=$(pgrep -o dockerd); ls /proc/$pid/fd | wc -l; grep -i "open files" /proc/$pid/limits
```

### Also worth fixing: `.gocache/` is in the history

`feat(migration): keep brownfield annotations on converged services` and two later commits
committed `.gocache/` — 5,633 files, 240 MB on disk — despite `.gitignore` listing it. The
pack for the unpushed commits was **117 MB**, which is why the first two `git push`
attempts died with `HTTP 408` and `curl 56 Recv failure`; the third succeeded with
`http.postBuffer` raised. Every fresh clone now pays that cost. Removing the blobs
requires rewriting those commits (they are pushed now, so it needs a force-push and a
heads-up to anyone who has cloned).
