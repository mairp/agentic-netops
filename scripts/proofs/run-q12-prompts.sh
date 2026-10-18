#!/usr/bin/env bash
# Proof q12-prompts (US6, T545; SC-012): the LIVE suggested-prompts endpoint.
# GET /suggested-prompts on the running supervisor must offer one runnable
# SRv6 example per supported variant of lab/profiles/sonic-vm/
# srv6-supported.yaml — ip-vrf/vpn ("ip-vrf over srv6") and steering (the
# same service "preferring spine01") — and no example for a variant the
# profile does not support (no "mac-vrf over srv6", no "with evpn
# signalling": variants outside the supported set are refused by contract,
# and the chat page never offers an example the tier would refuse, (V:x)).
#
# The list is fetched over the wire and compared with the reviewed file
# agents/supervisors/provisioning/suggested_prompts.json, so the receipt also
# witnesses that the deployed supervisor serves that file and not a stale
# copy. Read-only: no request is sent, no state changes.
#
# Env: SUPERVISOR_URL, PF_PORT (default 19090 — the port-forward this receipt
# establishes; not the lab's historical 9090, which a docker-published
# Prometheus owns on this box), CTX.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CTX="${CTX:-kind-agentic-netops}"
NS_AGENTS="agentic-netops-agents"
PF_PORT="${PF_PORT:-19090}"

kc() { kubectl --context "$CTX" "$@"; }
WORKDIR="$(mktemp -d)"
trap '[ -n "${PF_PID:-}" ] && kill "$PF_PID" 2>/dev/null; rm -rf "$WORKDIR"' EXIT

# ---- reach the supervisor the way the operator's UI does ----
kc -n "$NS_AGENTS" wait --for=condition=Available --timeout=60s deploy/supervisor >/dev/null \
    || { echo "PREFLIGHT FAIL: supervisor not Available" >&2; exit 3; }
kc -n "$NS_AGENTS" port-forward svc/supervisor "${PF_PORT}:9090" >/dev/null 2>&1 &
PF_PID=$!
PF_OK=0
for _ in $(seq 1 30); do
    curl -sS -o /dev/null --max-time 2 "http://localhost:${PF_PORT}/health" && { PF_OK=1; break; }
    sleep 1
done
(( PF_OK )) || { echo "PREFLIGHT FAIL: supervisor never answered on localhost:${PF_PORT}" >&2; exit 3; }
SUPERVISOR_URL="http://localhost:${PF_PORT}"

PROMPTS_FILE="${REPO_ROOT}/agents/supervisors/provisioning/suggested_prompts.json"

echo "=== supervisor reachable on $SUPERVISOR_URL"
echo "=== GET $SUPERVISOR_URL/suggested-prompts"
curl -fsS --max-time 15 "$SUPERVISOR_URL/suggested-prompts" > "$WORKDIR/served.json" \
    || { echo "FAIL: the suggested-prompts endpoint did not answer" >&2; exit 1; }

python3 - "$WORKDIR/served.json" "$PROMPTS_FILE" <<'PYEOF'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as fh:
    served = json.load(fh)
with open(sys.argv[2], encoding="utf-8") as fh:
    reviewed = json.load(fh)

if not isinstance(served, list) or not all(isinstance(p, str) for p in served):
    print("FAIL: the served list is not a JSON array of strings", file=sys.stderr)
    raise SystemExit(1)

print(f"=== served {len(served)} prompts:")
for prompt in served:
    print(f"  - {prompt}")

if served != reviewed:
    print("FAIL: the served list differs from the reviewed file "
          "agents/supervisors/provisioning/suggested_prompts.json", file=sys.stderr)
    raise SystemExit(1)
print("OK: the served list equals the reviewed file (no stale deployed copy)")

srv6 = [p for p in served if " over srv6" in p.lower()]
print(f"=== SRv6 examples served: {len(srv6)}")
for prompt in srv6:
    print(f"  - {prompt}")

plain = [p for p in srv6 if "preferring spine01" not in p]
steered = [p for p in srv6 if "preferring spine01" in p]
if len(plain) != 1:
    print(f"FAIL: expected exactly one plain ip-vrf/vpn example, got {len(plain)}", file=sys.stderr)
    raise SystemExit(1)
print(f"OK: one ip-vrf over srv6 (signalling vpn) example: {plain[0]}")
if len(steered) != 1:
    print(f"FAIL: expected exactly one steering example, got {len(steered)}", file=sys.stderr)
    raise SystemExit(1)
print(f"OK: one steering example for the supported 'steering' variant: {steered[0]}")

unsupported = [p for p in served
               if "mac-vrf over srv6" in p.lower() or "evpn" in p.lower()]
if unsupported:
    print("FAIL: the page offers an example for an unsupported variant:", file=sys.stderr)
    for prompt in unsupported:
        print(f"  - {prompt}", file=sys.stderr)
    raise SystemExit(1)
print("OK: no example for an unsupported variant "
      "(no mac-vrf over srv6, no evpn signalling wording)")

print("DONE: one SRv6 example per supported variant, none for an unsupported one.")
PYEOF
