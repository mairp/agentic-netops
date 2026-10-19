#!/usr/bin/env bash
# executor_transport.sh — the executor transport suite (T178-T182).
#
# Proves, against a REAL guest, that the executor's southbound transport
# behaves per contracts/executor-transport.md:
#   T178 exit code, stdout and stderr of a command propagate from a real guest
#   T179 the stdin payload path (GCU patch delivered through stdin)
#   T180 the per-command timeout bounds a hung command
#   T181 a node absent from the site map is refused
#   T182 a wrong host key is refused, reported by node name
#
# Cases T178-T181 run against the LIVE executor (EXECUTOR_URL, default the
# kind bridge gateway http://172.30.0.1:8084). They are transport-agnostic:
# they pass whichever transport the executor resolved for the node (docker for
# sonic-vs, SSH for sonic-vm). T182 starts its own throwaway executor with a
# deliberately wrong known-hosts file, so it never touches the live one.
#
# Env:
#   EXECUTOR_URL   executor base URL (default http://172.30.0.1:8084)
#   EXECUTOR_NODE  node to exercise (default leaf01)
#   SKIP_T180=1    skip the ~90s timeout case (short smoke runs)
#
# Exit 0 only when every enabled case passes.

set -u

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=tests/integration/lib/node_exec.sh
source "${ROOT_DIR}/tests/integration/lib/node_exec.sh"

EXECUTOR_URL="${EXECUTOR_URL:-http://172.30.0.1:8084}"
EXECUTOR_NODE="${EXECUTOR_NODE:-leaf01}"
CONTAINER="${CONTAINER:-clab-agentic-netops-fabric-${EXECUTOR_NODE}}"
TMPDIR_FX="$(mktemp -d /tmp/fx-transport.XXXXXX)"
trap 'rm -rf "${TMPDIR_FX}"' EXIT

PASS=0
FAIL=0

pass() { echo "PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $*"; FAIL=$((FAIL + 1)); }

# fx_post <base-url> <path> <node> <payload-file> <out-body> — POST
# {"node": node, "ops": payload}; saves the response body, sets HTTP_CODE.
fx_post() {
  local base=$1 path=$2 node=$3 payload=$4 outbody=$5
  HTTP_CODE=$(python3 - "$base" "$path" "$node" "$payload" "$outbody" <<'PY'
import json, sys, urllib.request, urllib.error
base, path, node, payload, outbody = sys.argv[1:6]
body = json.dumps({"node": node, "ops": json.load(open(payload))}).encode()
req = urllib.request.Request(base + path, data=body,
                             headers={"Content-Type": "application/json"})
try:
    with urllib.request.urlopen(req, timeout=140) as r:
        open(outbody, "wb").write(r.read())
        print(r.status)
except urllib.error.HTTPError as e:
    open(outbody, "wb").write(e.read())
    print(e.code)
except Exception as e:
    open(outbody, "w").write(json.dumps({"error": str(e)}))
    print(0)
PY
  )
}

# ---- T178: exit code, stdout, stderr propagate from a real guest ------------
t178() {
  echo "===== T178: exit code / stdout / stderr propagation ====="
  cat >"${TMPDIR_FX}/t178-fail.json" <<'JSON'
[{"shell": ["echo AI-T178-STDOUT; echo AI-T178-STDERR 1>&2; exit 7"]}]
JSON
  fx_post "${EXECUTOR_URL}" "/v1/node/apply" "${EXECUTOR_NODE}" \
    "${TMPDIR_FX}/t178-fail.json" "${TMPDIR_FX}/t178-fail.resp"
  python3 - "${TMPDIR_FX}/t178-fail.resp" <<'PY' >"${TMPDIR_FX}/t178-fail.eval"
import json, sys
r = json.load(open(sys.argv[1]))
res = (r.get("results") or [{}])[0]
out = res.get("output", "") or ""
err = res.get("error", "") or ""
checks = {
    "resp_not_ok": r.get("ok") is False,
    "op_not_ok": res.get("ok") is False,
    "stdout_propagated": "AI-T178-STDOUT" in out,
    "stderr_propagated": "AI-T178-STDERR" in out,
    "exit_code_propagated": "7" in err,
}
print("RESULT=%s" % ("PASS" if all(checks.values()) else "FAIL"))
for k, v in checks.items():
    print("%s=%s" % (k, v))
PY
  local result
  result=$(grep '^RESULT=' "${TMPDIR_FX}/t178-fail.eval" | cut -d= -f2)
  if [[ "$result" != "PASS" ]]; then
    fail "T178 propagation case failed:"
    sed 's/^/    /' "${TMPDIR_FX}/t178-fail.eval" | tail -6
    return
  fi

  cat >"${TMPDIR_FX}/t178-ok.json" <<'JSON'
[{"shell": ["echo AI-T178-OK"]}]
JSON
  fx_post "${EXECUTOR_URL}" "/v1/node/apply" "${EXECUTOR_NODE}" \
    "${TMPDIR_FX}/t178-ok.json" "${TMPDIR_FX}/t178-ok.resp"
  if grep -q '"ok": *true' "${TMPDIR_FX}/t178-ok.resp" \
    && grep -q "AI-T178-OK" "${TMPDIR_FX}/t178-ok.resp"; then
    pass "T178 exit code, stdout and stderr propagate"
  else
    fail "T178 success path wrong"
  fi
}

# ---- T179: the stdin payload path (GCU patch delivered through stdin) -------
t179() {
  echo "===== T179: stdin payload (GCU patch) ====="
  # A syntactically valid patch whose target row does not exist: the guest's
  # GCU parses it (the stdin path works) and rejects the CONTENT — the error
  # text names the missing row, which no shell-arg mangling could produce.
  # Zero mutation: the row never exists, so nothing changes on the node.
  cat >"${TMPDIR_FX}/t179.json" <<'JSON'
[{"gcu": [{"op": "remove", "path": "/VLAN/Vlan4242"}]}]
JSON
  fx_post "${EXECUTOR_URL}" "/v1/node/apply" "${EXECUTOR_NODE}" \
    "${TMPDIR_FX}/t179.json" "${TMPDIR_FX}/t179.resp"
  python3 - "${TMPDIR_FX}/t179.resp" <<'PY' >"${TMPDIR_FX}/t179.eval"
import json, sys
r = json.load(open(sys.argv[1]))
res = (r.get("results") or [{}])[0]
blob = (res.get("error", "") or "") + " " + (res.get("output", "") or "")
checks = {
    "op_not_ok": res.get("ok") is False,
    "gcu_named_row": "4242" in blob,
}
print("RESULT=%s" % ("PASS" if all(checks.values()) else "FAIL"))
for k, v in checks.items():
    print("%s=%s" % (k, v))
PY
  local result
  result=$(grep '^RESULT=' "${TMPDIR_FX}/t179.eval" | cut -d= -f2)
  if [[ "$result" == "PASS" ]]; then
    pass "T179 stdin payload reaches the guest GCU"
  else
    fail "T179 GCU stdin payload not delivered as expected:"
    sed 's/^/    /' "${TMPDIR_FX}/t179.resp" | head -4
  fi
}

# ---- T180: the per-command timeout bounds a hung command --------------------
t180() {
  echo "===== T180: per-command timeout ====="
  cat >"${TMPDIR_FX}/t180.json" <<'JSON'
[{"shell": ["sleep 300"]}]
JSON
  local t0 t1 elapsed
  t0=$(date +%s)
  fx_post "${EXECUTOR_URL}" "/v1/node/apply" "${EXECUTOR_NODE}" \
    "${TMPDIR_FX}/t180.json" "${TMPDIR_FX}/t180.resp"
  t1=$(date +%s)
  elapsed=$((t1 - t0))
  if (( elapsed >= 80 && elapsed <= 130 )) \
    && grep -q '"ok": *false' "${TMPDIR_FX}/t180.resp" \
    && grep -qiE "deadline|context" "${TMPDIR_FX}/t180.resp"; then
    pass "T180 hung command bounded by the per-op timeout (${elapsed}s)"
  else
    fail "T180 timeout behavior wrong (elapsed=${elapsed}s)"
  fi
}

# ---- T181: a node absent from the site map is refused -----------------------
t181() {
  echo "===== T181: unmapped node refused ====="
  cat >"${TMPDIR_FX}/t181.json" <<'JSON'
[{"shell": ["echo should-not-run"]}]
JSON
  fx_post "${EXECUTOR_URL}" "/v1/node/apply" "nosuch-node" \
    "${TMPDIR_FX}/t181.json" "${TMPDIR_FX}/t181.resp"
  if [[ "$HTTP_CODE" == "400" ]] && grep -q "not in site map" "${TMPDIR_FX}/t181.resp"; then
    pass "T181 unmapped node refused with 400"
  else
    fail "T181 unmapped node not refused (code=$HTTP_CODE)"
  fi
}

# ---- T182: a wrong host key is refused, reported by node name ---------------
t182() {
  echo "===== T182: wrong host key refused by name ====="
  local guest_ip
  guest_ip=$(node_guest_addr "${CONTAINER}")
  if [[ -z "$guest_ip" ]]; then
    fail "T182 cannot resolve guest address from ${CONTAINER}"
    return
  fi
  local key kh port
  kh="${TMPDIR_FX}/t182-known-hosts"; port=18084
  # The AUTH key must be one the guest accepts (the per-lab executor key);
  # the KNOWN-HOSTS content must be deliberately WRONG (a throwaway keypair),
  # so authentication succeeds and host-key verification fails by name.
  ssh-keygen -q -t ed25519 -N '' -f "${TMPDIR_FX}/t182-wronghost" </dev/null 2>/dev/null
  printf '%s %s\n' "$guest_ip" "$(cat "${TMPDIR_FX}/t182-wronghost.pub")" >"$kh"
  chmod 600 "$kh"
  key="${ROOT_DIR}/secrets/fabric-executor.key"
  if [[ ! -f "$key" ]]; then
    fail "T182 executor key ${key} missing (run the sonic-vm bring-up first)"
    return
  fi
  # The ssh transport multiplexes with ControlMaster=auto. The LIVE executor
  # (and the reconciler polling it) keeps masters on the default
  # /tmp/.fx-ssh-%C socket — a throwaway executor sharing that path would
  # ride an existing master and skip host-key verification entirely. The
  # transport therefore accepts FABRIC_SSH_CONTROL_PATH: the throwaway gets
  # its own socket directory, so its connections are always fresh and must
  # verify the (wrong) host key. The live executor is untouched.
  local cpath="${TMPDIR_FX}/ssh-ctl-%C"
  mkdir -p "${TMPDIR_FX}/ssh-ctl"
  local exe="${TMPDIR_FX}/fabric-executor"
  (go build -tags agentic_netops_k8s -o "$exe" ./cmd/fabric-executor) || {
    fail "T182 executor build failed"; return;
  }
  FABRIC_NODE_MAP="{\"${EXECUTOR_NODE}\":\"${CONTAINER}\"}" \
  FABRIC_NODE_TRANSPORT="{\"${EXECUTOR_NODE}\":{\"kind\":\"ssh\",\"addr\":\"${guest_ip}\",\"user\":\"admin\"}}" \
  FABRIC_SSH_KEY="$key" FABRIC_SSH_KNOWN_HOSTS="$kh" \
  FABRIC_SSH_CONTROL_PATH="$cpath" \
  FABRIC_EXECUTOR_BIND="127.0.0.1:${port}" \
    "$exe" >"${TMPDIR_FX}/t182-executor.log" 2>&1 &
  local pid=$!
  local up=0
  for _ in $(seq 1 40); do
    if curl -sf "http://127.0.0.1:${port}/healthz" >/dev/null 2>&1; then up=1; break; fi
    sleep 0.5
  done
  if (( ! up )); then
    kill "$pid" 2>/dev/null
    fail "T182 throwaway executor did not come up"
    sed 's/^/    /' "${TMPDIR_FX}/t182-executor.log" | head -4
    return
  fi
  cat >"${TMPDIR_FX}/t182.json" <<'JSON'
[{"shell": ["echo hi"]}]
JSON
  fx_post "http://127.0.0.1:${port}" "/v1/node/apply" "${EXECUTOR_NODE}" \
    "${TMPDIR_FX}/t182.json" "${TMPDIR_FX}/t182.resp"
  kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
  if grep -q "\"${EXECUTOR_NODE}\"" "${TMPDIR_FX}/t182.resp" \
    && grep -qi "host key" "${TMPDIR_FX}/t182.resp" \
    && grep -q '"ok": *false' "${TMPDIR_FX}/t182.resp"; then
    pass "T182 wrong host key refused, reported by node name"
  else
    fail "T182 wrong host key not refused by name"
    sed 's/^/    /' "${TMPDIR_FX}/t182.resp" | head -4
  fi
}

echo "===== executor_transport.sh: executor=${EXECUTOR_URL} node=${EXECUTOR_NODE} ====="

# The live executor must be up before anything else.
if ! curl -sf "${EXECUTOR_URL}/healthz" >/dev/null 2>&1; then
  echo "FAIL: executor not reachable at ${EXECUTOR_URL}" >&2
  exit 1
fi

t178
t179
if [[ "${SKIP_T180:-0}" == "1" ]]; then
  echo "SKIP: T180 (SKIP_T180=1)"
else
  t180
fi
t181
t182

echo "===== executor_transport.sh: PASS=${PASS} FAIL=${FAIL} ====="
(( FAIL == 0 )) || exit 1
exit 0
