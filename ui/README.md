# Intent-tier operator chat surface

Vite + React + TypeScript app served on port 3000. It is the operator's entry
point to the intent tier: a plain-language service request in, an NDJSON status
stream out (the supervisor's `POST /agent/prompt/stream` — there is no
WebSocket route; see `agents/README.md`).

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
