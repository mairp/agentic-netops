# Issue: the operator never receives a final deployment status

**State:** fixed — documented 2026-09-04 after live reproduction, closed the
same day.
**Reproduction:** thread `goal-l3vpn-*` in the console, correlation `837509b6`,
`Network/migr-11db8434354f4ae`

## Symptom

The operator provisions an L3VPN through the console (two confirms). The last
message in the conversation is the deployer stage card:

> **deployer · PROVISIONING** — Deployment in progress…
> Submission report received: Network/migr-11db8434354f4ae.

The Network then *does* converge — `Ready=True "applied and verified on all
nodes"` at 07:48:18Z, fabric state verified on both leaves — but **nothing
ever tells the operator that**. The conversation ends at "in progress". The
final outcome (deployed / failed) is only discoverable out of band: inspecting
the cluster, or asking an external agent.

## Root cause — three layers, independently real

1. **The supervisor ends the graph at submission, not at outcome.**
   `agents/supervisors/provisioning/graph/graph.py` (~line 1616): on the
   deployer's `{"submitted": [...]}` report the node returns
   `next_node: END` with `workflow_status: PROVISIONING`. No node reopens the
   thread when the referenced Network's Ready condition later flips.

2. **PROVISIONING is transaction-terminal, not an outcome.**
   `agents/common/provisioning_states.py` maps the deployer stage to
   `PROVISIONING` ("dry-run passed, bundle applying") and the enum has no
   observer that transitions it to a final `DEPLOYED`/`FAILED` grounded in the
   Network's Ready condition.

3. **The convergence signal has no path back to the conversation.**
   `controllers/sonicprovider/network_controller.go` owns the Ready condition
   and emits Kubernetes events (`ApplySucceeded` / `ApplyFailed` with real op
   output), but nothing watches those conditions to notify the UI thread.

4. *(aggravating)* **Asking afterwards doesn't work either.** A follow-up
   like *"What is the status of the deployment?"* on the same thread falls
   into the general-response node (`graph.py` ~1640), which answers with the
   fixed capability blurb plus the thread's current status — observed
   `RECEIVED_REQUEST` on a thread whose transaction had already completed,
   because the new request starts a fresh graph run instead of resolving the
   completed transaction's Network.

5. *(presentation)* **The UI hard-codes the indeterminate wording.**
   `ui/src/components/Chat/Chat.tsx:39` renders `"Deployment in progress…"`
   for any `deployer`-stage event, even though by that point the report is
   final for the transaction.

## Impact

- The operator cannot learn the outcome in-band; the "UI shows deployed"
  expectation is unmet by construction.
- Failures are even worse: a Network that ends `Ready=False/ApplyFailed`
  looks identical in the conversation to one that converged — no answer either
  way.
- The tier's own honesty contract (truthful reports everywhere else) is
  undercut by a silent last mile.

## What was actually wrong

The convergence watch was never missing. `provisioning/deployer/submit.py`
step 7 already polled every submitted object to a terminal observation and
returned `{"submitted": [...], "convergence": [...]}`. **The supervisor read
`submitted` and dropped `convergence` on the floor** — it had the outcome in
hand and reported "in progress" anyway. Everything below follows from that,
plus six smaller defects found while closing it — two of which only
the live run could surface.

## The fix

**A — the supervisor reports the outcome, not the submission.**
`graph.py::_deployer_node` now consumes the convergence report and ends the
transaction on what it says:

| convergence report        | workflow_status | what the operator is told                              |
|---------------------------|-----------------|--------------------------------------------------------|
| every resource `ready`    | `COMPLETED`     | "Deployed. N resource(s) reached Ready…" + the condition |
| any resource `failed`     | `FAILED`        | the controller's own `ApplyFailed` message, and that the objects were *not* rolled back (the apply succeeded) |
| any `timeout`, none failed| `PROVISIONING`  | "still converging" — and how to resolve it              |
| no convergence entry      | `PROVISIONING`  | "the outcome is not yet known"                          |

A convergence failure emits **no** extra audit event: the `submit` event is
true (the objects *were* applied), and a `refuse` after it would claim nothing
was applied and break the SC-006 reconciliation.

`watch.py::_observe` now also carries the condition message for `Ready=True`,
so a success can quote *why* it succeeded, not only that it did.

**B — a status question resolves the transaction.**
`detect_deployment_status_query` recognises "what is the status of the
deployment?", "is it deployed?", "did it converge" and friends. On a thread
that has submitted something, the supervisor routes to the deployer tools path
with the thread's correlation id instead of the capability blurb.
`deployer.get_service_status` is no longer a stub returning `phase: Unknown`:
it selects the submitted objects by their correlation-id label
(`list_by_correlation`) and reports each object's `Ready` condition verbatim,
reducing to `Deployed` / `Failed` / `Converging` / `NotFound`. An unreadable
cluster is `Unknown` **with the error named** — never a success. The resolved
phase then sets the thread's status, so a converged transaction stops
reporting `PROVISIONING`.

**C — honest UI copy.** The deployer card renders the outcome it was actually
given ("Deployed — 1 resource verified Ready", "Deployment failed — …", or
"Submitted — still converging…") and lists each resource's convergence verdict
with the controller's message. It no longer claims a watch that is not
running.

**Four defects found on the way:**

- The tools path never unwrapped the supervisor's nonce fence, so a canonical
  `{"action": "status"}` command failed its JSON parse and silently degraded
  into "unknown tool action" — the status/remove routes could not have worked
  end to end. `_parse_action` now unwraps the fence, as
  `parse_deployment_envelope` always did.
- `main.py` imported `watch_ready`, which does not exist in `watch.py`. The
  whole T273 progress block was dead code inside a bare `except`. It is
  replaced by real convergence stage/progress chunks.
- `_general_response_node` relabelled *any* thread `COMPLETED` after an
  informational answer — including one with a submission still in flight. It
  now preserves an in-flight transaction's status.
- The deployer's A2A call shared the 60 s `WORKER_CALL_TIMEOUT_SECONDS` with
  the mapper and allocator, while its own convergence watch was 45 s: a slow
  fabric would have been cut off and reported as an unreachable worker. The
  watch bound is now 150 s (`DEPLOYER_CONVERGENCE_TIMEOUT_SECONDS`) and the
  deployer alone gets `DEPLOYER_CALL_TIMEOUT_SECONDS` (210 s); both are set
  explicitly in `deploy/agents/{deployer,supervisor}.yaml` so the coupling is
  visible. The mapper and allocator keep the tighter 60 s — neither waits on
  the fabric.

## Files changed

- `agents/supervisors/provisioning/graph/graph.py` — convergence → outcome,
  status-question routing, status-phase → workflow-status mapping,
  informational answers stop relabelling threads
- `agents/supervisors/provisioning/main.py` — deployer outcome stage +
  per-resource progress chunks (replacing the dead stub)
- `agents/supervisors/provisioning/graph/tools.py` — per-worker call timeout
- `agents/provisioning/deployer/watch.py` — quote the Ready=True message
- `agents/provisioning/deployer/submit.py` — 150 s watch bound
- `agents/provisioning/deployer/agent.py` — fence-aware tool commands,
  outcome-first status summary
- `agents/provisioning/deployer/tools/deployer_tools.py` — live
  `get_service_status`
- `ui/src/components/Chat/Chat.tsx`, `ui/src/styles.css` — outcome card
- `deploy/agents/{deployer,supervisor}.yaml` — the two coupled timeouts

## Verification — run live on the lab, 2026-09-04

Rebuilt `intent-supervisor`, `intent-deployer` and `intent-ui`, loaded them
into the Kind cluster, applied the changed manifests and restarted all three
deployments. Driven through the supervisor's own NDJSON stream (the UI is a
thin client over it).

1. **Outcome in-band.** Thread `verify2-1788513025`, L3VPN leaf01 wan1 ↔
   leaf02 wan1. Final message:
   > Deployed. 1 resource(s) reached Ready on the fabric:
   > Network/migr-fdbd562c18114de (applied and verified on all nodes).

   No out-of-band tooling. **PASS**

2. **Failure names the condition.** Thread `fail-1788513268`, deliberately
   invalid attachments. The stream carries the deployer stage `FAILED`, a
   progress line per resource, and:
   > deployer submitted Network/migr-14ae5c10580b412 but convergence failed:
   > attachment Ethernet1@leaf1: attachment "Ethernet1" not in site port map

   with the suggestion noting the objects were *not* rolled back. **PASS**

3. **Status question resolves the transaction.** Asked "What is the status of
   the deployment?" on the completed thread:
   > Deployed. Network/migr-fdbd562c18114de Ready=True
   > "applied and verified on all nodes" since 2026-09-04T09:13:11Z.

   The Network and its condition, not the capability blurb. **PASS**

The timeout branch was also exercised live (thread `final-1788512432`,
convergence took 133 s against a then-90 s bound): the operator got
"still converging … ask what is the status of the deployment", asked, and got
the resolved `Deployed`. The honest-timeout path and the resolution path work
together as designed.

### Two defects the unit tests could not have caught

- **The status query selected on the wrong correlation id.** `main.py` mints a
  fresh correlation id per HTTP request, so by the time the operator asks,
  `state["correlation_id"]` labels nothing on the cluster. The first live run
  answered `NotFound` — "nothing is on the cluster" — for a Network that was
  `Ready=True`. The submitting transaction's id is now persisted as
  `submitted_correlation_id` and is what the status query selects on. The unit
  test had seeded both ids to the same value, which is the one case that never
  happens in production; it now seeds them differently.
- **Convergence is slower than first measured.** The original repro observed
  ~35 s; a loaded fabric took 133 s (Network created 09:00:43, Ready 09:02:56).
  The watch bound is now 150 s and the deployer's call bound 210 s. It stays a
  bound, not a guarantee — past it the operator is told the truth and the
  status question resolves it.

## Known residual

Convergence past the watch bound still has no *push*: the operator is told
honestly that it is still converging and must ask. A true watch-and-notify
(controller condition → thread reopened unprompted) is not built. Root cause 1
is closed for convergence inside the bound; outside it, the operator has a
working answer but has to request it.

## Workarounds (no longer needed, kept for cluster-side debugging)

- `kubectl -n agentic-netops-intent get network <name> -o jsonpath='{.status.conditions}'`
- `kubectl -n agentic-netops-intent get events --field-selector involvedObject.name=<name>`
