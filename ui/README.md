# Intent-tier operator chat surface

Vite + React + TypeScript app served on port 3000. It is the operator's entry
point to the intent tier: a plain-language service request in, an NDJSON status
stream out (the supervisor's `POST /agent/prompt/stream` — there is no
WebSocket route; see `agents/README.md`).

The console's workflow canvas and conversation panel are separated by a
draggable divider (pointer or arrow keys; Home/End snap to minimum/full-screen;
double-click toggles between maximized — the conversation fills the screen with
the canvas collapsed to its heading bar — and the default height); the chosen
height persists in `localStorage` under `agentic-netops-chat-height`
(`src/components/ResizeHandle/`).

Each section zooms independently (`src/hooks/useSectionZoom.ts`, controls in
`src/components/ZoomControls/`): the workflow canvas (50–200%, also
Ctrl/⌘+wheel), the conversation (80–150%), and the navigation sidebar
(80–150%). Levels persist under `agentic-netops-zoom-*`. The canvas itself is
grabbable: drag anywhere to pan the layout (handy when zoomed in), double-click
the background or press the % control to reset zoom and position.

The conversation column is wide (1200px cap) and the composer is a raised,
rounded card in the DeepSeek-harness style: a multi-line textarea that grows
with the draft (Enter sends, Shift+Enter newlines) with the send button pinned
bottom-right (`src/components/Chat/`).

While an exchange is in flight, the canvas shows the live SLIM traffic: the
speaking agent breathes and blinks, its link and the `A2A · SLIM` rail stream
flowing dashes and travelling packets, and every backend event fires a ripple —
driven by the NDJSON stream itself, settling back to idle shortly after the
last event (`src/components/MainArea/`, `src/styles.css`).

## Development

```bash
npm ci
npm run dev          # http://localhost:3000
```

Configure the supervisor endpoint via `.env` (see `.env.example`).

## Verification (CI `ui` job)

```bash
npm ci
npm run typecheck    # tsc --noEmit
npm run build        # vite build -> dist/
```

## Container

Built by `docker/Dockerfile.ui` on the digest-pinned `node:20-alpine` image
(`intent_tier.node` in `versions.lock.yaml`). The runtime stage re-generates
`.env` from pod `VITE_*` environment (the `ui-env` ConfigMap) via
`docker/ui-build-and-serve.sh` before serving the built app.
