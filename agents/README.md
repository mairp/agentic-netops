# AGNTCY intent tier — Python agent code (feature 002)

The multi-agent intent tier: a conversational LangGraph supervisor orchestrating
three specialist workers (mapper, allocator, deployer) over A2A carried on the
SLIM bus. This directory is the project root for the Python tier —
`pyproject.toml` + `uv.lock` live here, and the importable top-level packages
are `common/`, `config/`, `provisioning/`, and `supervisors/` (tests in
`tests/`).

```text
agents/
├── pyproject.toml            # pins: research.md Decision 1 (fidelity contract)
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

## The subject tree is a read-only reference

The subject project (`/root/AI-NETWORK-SERVICES-DEVNET-2606`, the
`AI-NETWORK-SERVICES-DEVNET-2606` devnet) is the byte-for-byte reference for
this tier's layout and behavior. It is **read-only**:

- Copy behavior and structure, never vendor its proprietary southbound code
  (the Cisco CNC connector, RESTCONF clients, vendor NEDs). Feature 001
  deliberately replaced that southbound with an open Kubernetes-native fabric,
  and this tier restores only the *northbound intent tier* — it has no device
  sessions and is provably unable to acquire one (FR-016/FR-029).
- Do not modify the subject tree; record any divergence from it in this
  feature's `specs/002-agntcy-intent-tier/` artifacts instead.

## The three REVERSE.md corrections (binding)

`REVERSE.md` documents where the subject's README lies. This repository
follows the code, not the README, in exactly three places — do not "fix"
these back to the README values:

1. **The SLIM transport port is `46357`, not `:7080`.** Nothing listens on
   `:7080`; the gateway's data plane is on `46357` (controller port `46358`,
   not exposed). `README.md:236` in the subject is wrong (Finding 1).
2. **The variable is `TRANSPORT_SERVER_ENDPOINT`, not `TRANSPORT_ENDPOINT`.**
   Nothing in the subject reads the short name; use the long form everywhere
   (`config/config.py:8` in the subject).
3. **The browser transport is an NDJSON stream over `POST /agent/prompt/stream`
   — there is no WebSocket route.** The subject's README advertises
   `ws://localhost:9090/ws/provision` (Finding 2); the code streams
   `application/x-ndjson`. No WebSocket client or route exists or may be
   added in this repository.

## The `pkg/migration` single-translator rule

Translation from the normalized service-intent contract to fabric resources
exists in **exactly one implementation: Go, in `pkg/migration`** (this
repository). The Python agents never reimplement translation logic (FR-011):

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

- `pyproject.toml` pins the subject's stack at its pinned versions
  (`agntcy-app-sdk==0.4.5`, `a2a-sdk==0.3.0`, `agntcy-identity-service-sdk==0.0.7`,
  `litellm[proxy]==1.75.3`, `ioa-observe-sdk==1.0.24`, `langgraph>=0.4.1`,
  `langgraph-supervisor`, `langchain-litellm>=0.3.0`, `langgraph-checkpoint-sqlite`,
  `pydantic>=2.11.4`, FastAPI/uvicorn/starlette) on
  `requires-python = ">=3.13,<4.0"` — research.md Decision 1. Do not upgrade
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
