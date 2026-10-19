#!/usr/bin/env bash
# construct-trial.sh <construct> — p4-*-trial proof body (T189 vlan, T195
# mac-vrf, T201 ip-vrf, T207 mac-vrf-gw, T213 acl).
#
# Renders the construct's Network through pkg/fabricplan (cmd/fabricplan-print)
# for the target node kind with the profile port map — exactly what the
# provider renders — then applies every node's ops through the fabric-executor
# and verifies the declared checks. It prints the rendered plan, each op and
# check result, a DIFFS section naming every op that failed or check that did
# not hold, and finally applies the plan's rollback ops best-effort so the
# trial leaves no service state behind.
#
# The trial is an observation, not an assertion: it exits 0 when it ran to
# completion; the DIFFS section carries the verdict.
#
# Env: EXECUTOR_URL (default http://127.0.0.1:8084), KIND (default sonic-vm),
# PORTMAP (default lab/profiles/sonic-vm/port-map.json), GO (default
# /usr/lib/go-1.24/bin, prepended to PATH when present).
set -u
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CONSTRUCT=${1:?construct required: vlan|macvrf|ipvrf|macvrfgw|acl}
EXECUTOR_URL=${EXECUTOR_URL:-http://127.0.0.1:8084}
KIND=${KIND:-sonic-vm}
PORTMAP=${PORTMAP:-$REPO_ROOT/lab/profiles/sonic-vm/port-map.json}
NET="$REPO_ROOT/scripts/spike/networks/$CONSTRUCT.yaml"
[[ -f "$NET" ]] || { echo "no trial network for construct $CONSTRUCT: $NET" >&2; exit 2; }
[[ -f "$PORTMAP" ]] || { echo "no port map: $PORTMAP" >&2; exit 2; }
GODIR=${GO:-/usr/lib/go-1.24/bin}
if [[ -d "$GODIR" ]]; then
  export PATH="$GODIR:$PATH"
fi

echo "===== rendered $CONSTRUCT plan (kind=$KIND portmap=$PORTMAP) ====="
PLAN_JSON=$(go run -mod=vendor "$REPO_ROOT/cmd/fabricplan-print" \
  -f "$NET" -portmap "$PORTMAP" -kind "$KIND" -vtep vtep1) || exit 1
printf '%s\n' "$PLAN_JSON"

EXECUTOR_URL="$EXECUTOR_URL" PLAN_JSON="$PLAN_JSON" python3 - <<'PY'
import json, os, sys, urllib.request, urllib.error

executor = os.environ["EXECUTOR_URL"].rstrip("/")
plan = json.loads(os.environ["PLAN_JSON"])

def post(path, payload, timeout=120):
    req = urllib.request.Request(executor + path,
                                 data=json.dumps(payload).encode(),
                                 headers={"Content-Type": "application/json"},
                                 method="POST")
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return json.loads(r.read().decode())
    except urllib.error.HTTPError as e:
        try:
            return json.loads(e.read().decode())
        except Exception:
            return {"ok": False, "error": "HTTP %d" % e.status}

def short(s, n=160):
    s = (s or "").replace("\n", " ⏎ ")
    return s if len(s) <= n else s[:n] + "…"

diffs = []
for np in plan:
    node = np["node"]
    print(f"===== {node}: apply {len(np['ops'])} op(s) =====")
    res = post("/v1/node/apply", {"node": node, "ops": np["ops"]})
    for r in res.get("results", []):
        status = "OK " if r.get("ok") else "FAIL"
        line = f"  [{status}] {r.get('kind','?')}"
        if not r.get("ok"):
            line += f" error={short(r.get('error'))}"
            diffs.append(f"{node} {r.get('kind','?')}: {short(r.get('error'), 200)}")
        elif r.get("output"):
            line += f" out={short(r.get('output'), 100)}"
        print(line)
    if not res.get("results") and not res.get("ok"):
        line = f"  [FAIL] apply rejected: {short(res.get('error'))}"
        print(line)
        diffs.append(f"{node} apply: {short(res.get('error'), 200)}")

    if np.get("checks"):
        print(f"===== {node}: verify {len(np['checks'])} check(s) =====")
        vres = post("/v1/node/verify", {"node": node, "checks": np["checks"]})
        for r in vres.get("results", []):
            status = "OK " if r.get("ok") else "FAIL"
            line = f"  [{status}] {r.get('check','?')}"
            if not r.get("ok"):
                line += f" error={short(r.get('error'))}"
                diffs.append(f"{node} {r.get('check','?')}: {short(r.get('error') or r.get('actual'), 200)}")
            print(line)

print("===== rollback (best-effort, plan-declared) =====")
for np in plan:
    node = np["node"]
    if not np.get("rollback"):
        continue
    res = post("/v1/node/apply", {"node": node, "ops": np["rollback"]})
    oks = sum(1 for r in res.get("results", []) if r.get("ok"))
    print(f"  {node}: {oks}/{len(res.get('results', []))} rollback op(s) OK")

print("===== DIFFS: ops that failed or checks that did not hold =====")
if diffs:
    for d in diffs:
        print("  - " + d)
else:
    print("  none")
PY
