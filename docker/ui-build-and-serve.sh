#!/bin/sh
# ui-build-and-serve.sh — regenerate the runtime .env from VITE_* values,
# rebuild, and serve ui/ (feature 002, T022).
#
# In the cluster the ui-env ConfigMap injects the VITE_*_API_URL values as pod
# environment. Vite bakes VITE_* variables into the bundle at build time, so
# the runtime .env must be regenerated BEFORE the production build that the
# server serves — the same pattern the subject's docker/ui-build-and-serve.sh
# uses. There is no WebSocket client anywhere: the UI consumes the NDJSON
# stream over POST /agent/prompt/stream.
set -e

cd /app

# Regenerate the runtime .env from the VITE_* environment values.
: > .env
for var in VITE_SUPERVISOR_API_URL VITE_MAPPER_API_URL VITE_ALLOCATOR_API_URL VITE_DEPLOYER_API_URL; do
  value=$(printenv "$var" || true)
  if [ -n "$value" ]; then
    printf '%s=%s\n' "$var" "$value" >> .env
  fi
done
if [ -s .env ]; then
  echo "[ui-build-and-serve] regenerated runtime .env:"
  cat .env
else
  echo "[ui-build-and-serve] no VITE_* environment values; using build-time defaults"
fi

# Rebuild the bundle with the runtime environment in effect.
echo "[ui-build-and-serve] building UI with runtime environment variables..."
npm run build

# Serve the built application on port 3000 (local vite binary; no network).
echo "[ui-build-and-serve] serving UI on port 3000..."
exec npx --no-install vite preview --host 0.0.0.0 --port 3000
