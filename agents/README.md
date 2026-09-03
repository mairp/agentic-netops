# AGNTCY intent tier — Python agent code

The multi-agent intent tier: a conversational LangGraph supervisor orchestrating
three specialist workers (mapper, allocator, deployer) over A2A carried on the
SLIM bus. This directory is the project root for the Python tier —
`pyproject.toml` + `uv.lock` live here, and the importable top-level packages
are `common/`, `config/`, `provisioning/`, and `supervisors/` (tests in
`tests/`).

```text
agents/
├── pyproject.toml            # exact upstream version pins (the fidelity contract)
├── uv.lock                   # CI installs from this lockfile (uv sync --frozen)
├── common/                   # schemas, exceptions (incl. AuthError), LLM, transport
├── config/                   # transport config: SLIM, endpoints, env-derived settings
├── provisioning/
│   ├── mapper/               # worker: NL request -> schema-validated Interpretation
│   ├── allocator/            # worker: KUID Claim + NormalizedServiceIntent contract
│   └── deployer/tools/       # worker: translator client + cluster submission
├── supervisors/
│   └── provisioning/graph/   # LangGraph state machine, nodes, and A2A tools
└── tests/                    # pytest suite
```

## Provenance: the reference tree is read-only

This tier reproduces the layout and behavior of the upstream reference
implementation it was extracted from. That reference tree is **read-only**:

- Copy behavior and structure, never vendor its proprietary southbound code
  (the Cisco CNC connector, RESTCONF clients, vendor NEDs). This repository
  deliberately replaced that southbound with an open Kubernetes-native fabric,
  and this tier restores only the *northbound intent tier* — it has no device
  sessions and is provably unable to acquire one.
- Do not modify the reference tree; record any divergence from it in the
  documentation of this tier instead.

## The three transport corrections (binding)

The upstream reference's documentation is wrong in exactly three places; this
repository follows the code, not that documentation — do not "fix" these back:

1. **The SLIM transport port is `46357`, not `:7080`.** Nothing listens on
   `:7080`; the gateway's data plane is on `46357` (controller port `46358`,
   not exposed).
2. **The variable is `TRANSPORT_SERVER_ENDPOINT`, not `TRANSPORT_ENDPOINT`.**
   Nothing reads the short name; use the long form everywhere.
3. **The browser transport is an NDJSON stream over `POST /agent/prompt/stream`
   — there is no WebSocket route.** Any documentation advertising
   `ws://localhost:9090/ws/provision` is wrong; the code streams
   `application/x-ndjson`. No WebSocket client or route exists or may be
   added in this repository.

## The `pkg/migration` single-translator rule

Translation from the normalized service-intent contract to fabric resources
exists in **exactly one implementation: Go, in `pkg/migration`** (this
repository). The Python agents never reimplement translation logic:

- The Go sidecar `cmd/intent-translator` (built by
  `docker/Dockerfile.intent-translator`) is a thin HTTP wrapper over
  `migration.ParseStrictBatch` → `ValidateAllOrNothing` → `migration.Translate`
  — the same path `cmd/migration-translator` uses — bound to pod-local
  `127.0.0.1:8090` inside the deployer Pod.
- The allocator/deployer call the sidecar's `POST /v1/translate`; they submit
  its output as declarative resources and never compute translation
  themselves.
- If a translation change is needed, it is made once, in `pkg/migration`, with
  its golden-file oracle tests — not in Python.

## Pins and build

- `pyproject.toml` pins the reference stack at its pinned versions
  (`agntcy-app-sdk==0.4.5`, `a2a-sdk==0.3.0`, `agntcy-identity-service-sdk==0.0.7`,
  `litellm[proxy]==1.75.3`, `ioa-observe-sdk==1.0.24`, `langgraph>=0.4.1`,
  `langgraph-supervisor`, `langchain-litellm>=0.3.0`, `langgraph-checkpoint-sqlite`,
  `pydantic>=2.11.4`, FastAPI/uvicorn/starlette) on
  `requires-python = ">=3.13,<4.0"`. Do not upgrade
  exact-pinned packages without a recorded decision.
- Container base images are pinned by digest under `intent_tier:` in
  `versions.lock.yaml`; the Dockerfiles in `docker/` use those digests.

## Develop

```bash
cd agents
uv sync                 # installs from uv.lock (add dev deps for the tooling below)
uv run ruff check .     # lint
uv run pytest           # tests
```

The CI `python-tier` job in `.github/workflows/ci.yaml` runs exactly
`uv sync --frozen`, `ruff check .`, and `pytest`.
