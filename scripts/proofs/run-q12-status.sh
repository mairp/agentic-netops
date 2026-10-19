#!/usr/bin/env bash
# Proof q12-status (US6, T547; SC-012): "Show the status of my services." is
# answered from the cluster, and the answer names every service with its type
# and Ready state. The deployer resolves the thread's submitted objects by
# their correlation-id label (submit.py list_by_correlation queries every
# allow-listed kind — SRv6Service as well as Network — so one correlation id
# selects either transport) and _summary_status restates each object's type —
# FR-013's wording for SRv6 ("ip-vrf over srv6"), the bare construct for a
# VXLAN Network — beside the controller's own Ready verdict.
#
# On the live lab the status question is answered on the thread that just
# provisioned (graph state carries the transaction's correlation id), so the
# receipt witnesses BOTH transports end to end, one thread each:
#   thread 1 — a VXLAN ip-vrf service (the Network path): the answer names
#              Network/<id> (ip-vrf) with Ready=True;
#   thread 2 — an SRv6 ip-vrf service (the served plain example, via
#              tests/integration/srv6_chat.sh): the answer names
#              SRv6Service/<id> (ip-vrf over srv6) with Ready=True.
# A fabric carrying both transports resolves from one code path; the unit
# case test_the_service_listing_covers_srv6services_as_well_as_networks pins
# the listing itself.
#
# Destructive by construction: the two services bind the same only-verifiable
# attachments (C7), so the documented swap runs between the threads (every
# SRv6Service and Network deleted and waited gone) and the bring-up sample is
# restored and re-verified at the end (the phase-7 end state).
#
# Env: SUPERVISOR_URL, PF_PORT (default 19090), CTX, KUBECTL.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CTX="${CTX:-kind-agentic-netops}"
NS_AGENTS="agentic-netops-agents"
NS_INTENT="agentic-netops-intent"
SAMPLE_NAME="srv6-ip-vrf-vpn"
SAMPLE_FILE="${REPO_ROOT}/config/samples/srv6service-ip-vrf-vpn.yaml"
PF_PORT="${PF_PORT:-19090}"
READY_TIMEOUT="${READY_TIMEOUT:-330s}"
VXLAN_REQUEST="Deploy an ip-vrf between leaf01 wan1 and leaf02 wan1 for tenant green with prefix 10.5.0.0/24"
STATUS_QUESTION="Show the status of my services."

kc() { kubectl --context "$CTX" "$@"; }

WORKDIR="$(mktemp -d)"
trap '[ -n "${PF_PID:-}" ] && kill "$PF_PID" 2>/dev/null; rm -rf "$WORKDIR"' EXIT

# ---- preflight ----
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
export SUPERVISOR_URL="http://localhost:${PF_PORT}"
echo "=== supervisor reachable on $SUPERVISOR_URL"

# ---- the served plain SRv6 example (thread 2's request) ----
curl -fsS --max-time 15 "$SUPERVISOR_URL/suggested-prompts" > "$WORKDIR/served.json" \
    || { echo "FAIL: /suggested-prompts did not answer" >&2; exit 1; }
SRV6_REQUEST="$(python3 - "$WORKDIR/served.json" <<'PYEOF'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as fh:
    served = json.load(fh)
plain = [p for p in served if " over srv6" in p.lower() and "preferring spine01" not in p]
if len(plain) != 1:
    print(f"FAIL: expected exactly one plain served SRv6 example, got {len(plain)}", file=sys.stderr)
    raise SystemExit(1)
print(plain[0])
PYEOF
)" || exit 1
echo "=== SRv6 request (the served plain example): $SRV6_REQUEST"

clear_intent() {
    kc -n "$NS_INTENT" delete srv6services --all --ignore-not-found --timeout=180s >/dev/null \
        || { echo "SWAP FAIL: deleting the SRv6Services failed" >&2; return 1; }
    kc -n "$NS_INTENT" delete networks --all --ignore-not-found --timeout=180s >/dev/null \
        || { echo "SWAP FAIL: deleting the Networks failed" >&2; return 1; }
    for _ in $(seq 1 60); do
        LEFT="$(kc -n "$NS_INTENT" get srv6services,networks --no-headers 2>/dev/null | wc -l)"
        [[ "$LEFT" == "0" ]] && break
        sleep 2
    done
    if [[ "$(kc -n "$NS_INTENT" get srv6services,networks --no-headers 2>/dev/null | wc -l)" != "0" ]]; then
        echo "SWAP FAIL: objects still present after the delete window" >&2
        return 1
    fi
    # Settle before the next allocation: while deleted services' client /24
    # claims are still releasing, the pinned kuid server's carve of the next
    # claim can 500 ("ipclaims ... not found") — measured live. The next
    # thread only allocates once the claim inventory stopped moving.
    local zero=0 cur
    for _ in $(seq 1 36); do
        cur="$(kc -n kuid-system get ipclaims -o name 2>/dev/null | grep -v 'srv6-client-v4\.' || true)"
        if [[ -z "$cur" ]]; then
            zero=$((zero + 1))
            if [[ "$zero" -ge 2 ]]; then
                echo "=== claim inventory settled: no service claim left across two polls"
                return 0
            fi
        else
            zero=0
        fi
        sleep 5
    done
    echo "SWAP FAIL: the client-/24 claim inventory never settled (leftover: ${cur:-none})" >&2
    return 1
}

restore_sample() {
    # Frees the attachments FIRST: a receipt service that still holds
    # leaf01/wan1+leaf02/wan1 (C7) would leave a re-applied sample stuck
    # PortInUse.
    clear_intent || return 1
    kc -n "$NS_INTENT" apply -f "$SAMPLE_FILE" >/dev/null 2>&1 || true
    kc -n "$NS_INTENT" wait --for=condition=Ready=True --timeout=300s srv6service/"$SAMPLE_NAME" >/dev/null 2>&1 || true
}

# status_turn <thread-id> <outfile>: ask the status question on a thread that
# already submitted, streaming to <outfile>.
status_turn() {
    curl -N -sS --max-time 180 -X POST "$SUPERVISOR_URL/agent/prompt/stream" \
        -H 'Content-Type: application/json' \
        -d "$(python3 -c 'import json,sys; print(json.dumps({"prompt": sys.argv[1], "thread_id": sys.argv[2]}))' \
             "$STATUS_QUESTION" "$1")" > "$2"
}

# print_stream <outfile>: every operator-facing chunk of a stream.
print_stream() {
    python3 - "$1" <<'PYEOF'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as fh:
    for line in fh:
        line = line.strip()
        if not line:
            continue
        try:
            chunk = json.loads(line)
        except json.JSONDecodeError:
            continue
        kind = chunk.get("type")
        if kind == "progress" and chunk.get("message"):
            print(f"progress: {chunk['message']}")
        elif kind == "final" and chunk.get("message"):
            print(f"final: {chunk['message']}")
        elif kind == "error":
            print(f"error: {chunk.get('reason', '(no reason given)')}")
PYEOF
}

# final_message <outfile> <outfile-out>: the stream's final message, one line.
final_message() {
    python3 - "$1" > "$2" <<'PYEOF'
import json
import sys

final = ""
with open(sys.argv[1], encoding="utf-8") as fh:
    for line in fh:
        line = line.strip()
        if not line:
            continue
        try:
            chunk = json.loads(line)
        except json.JSONDecodeError:
            continue
        if chunk.get("type") == "final" and chunk.get("message"):
            final = chunk["message"]
if not final:
    print("FAIL: the stream carried no final message", file=sys.stderr)
    raise SystemExit(1)
print(final)
PYEOF
}

# assert_status <answer-file> <kind> <name> <type-wording>
assert_status() {
    local file="$1" kind="$2" name="$3" stype="$4"
    grep -F "${kind}/${name}" "$file" >/dev/null \
        || { echo "STATUS FAIL: the answer does not name ${kind}/${name}: $(cat "$file")" >&2; return 1; }
    grep -F "(${stype})" "$file" >/dev/null \
        || { echo "STATUS FAIL: the answer does not restate the type (${stype}): $(cat "$file")" >&2; return 1; }
    grep -F "Ready=True" "$file" >/dev/null \
        || { echo "STATUS FAIL: the answer does not report Ready=True: $(cat "$file")" >&2; return 1; }
    echo "OK: the status answer names ${kind}/${name} (${stype}) Ready=True"
}

# vxlan_turn <outfile> <prompt> — one turn on the FIXED thread (the thread
# must pre-exist the status question; graph.py answers a status query only
# on a thread that already submitted). Mirrors tests/integration/srv6_chat.sh
# post_turn/print_turn without that driver's unconditional teardown — the
# service must stay live for the status turn (construct_chat.sh would delete
# it, measured 09:25).
vxlan_turn() {
    local file="$1" prompt="$2" payload
    payload="$(python3 -c 'import json,sys; print(json.dumps({"prompt": sys.argv[1], "thread_id": sys.argv[2]}))' "$prompt" "$THREAD_A")"
    curl -N -sS --max-time 240 -X POST "$SUPERVISOR_URL/agent/prompt/stream" \
        -H 'Content-Type: application/json' -d "$payload" > "$file"
    echo "=== operator: $prompt"
    print_stream "$file"
}

# points_in <file>: how many confirmation points the turn offered.
points_in() { grep -c '"type": "confirmation_request"' "$1" 2>/dev/null || true; }

# ============================== thread 1: VXLAN ==============================
echo
echo "=== thread 1: a VXLAN ip-vrf service, then the status question on its thread"
clear_intent || { restore_sample; exit 1; }
THREAD_A="q12-status-vxlan-$(date +%s)"

vxlan_turn "$WORKDIR/vxlan-turn.out" "$VXLAN_REQUEST"
POINTS="$(points_in "$WORKDIR/vxlan-turn.out")"
while [[ "${POINTS:-0}" -gt 0 ]]; do
    vxlan_turn "$WORKDIR/vxlan-turn-2.out" "confirm"
    POINTS="$(points_in "$WORKDIR/vxlan-turn-2.out")"
done
grep -qE "Submitted Network/|Deployed\." "$WORKDIR/vxlan-turn.out" "$WORKDIR/vxlan-turn-2.out" \
    || { echo "CHAT FAIL: the VXLAN conversation produced no submission" >&2; restore_sample; exit 1; }

NETS="$(kc -n "$NS_INTENT" get networks --no-headers 2>/dev/null | wc -l)"
[[ "$NETS" == "1" ]] || { echo "STATE FAIL: expected exactly one Network, got ${NETS}" >&2; restore_sample; exit 1; }
NET_NAME="$(kc -n "$NS_INTENT" get networks -o jsonpath='{.items[0].metadata.name}')"
echo "=== waiting for Network ${NET_NAME} to reach Ready"
kc -n "$NS_INTENT" wait --for=condition=Ready=True --timeout="$READY_TIMEOUT" "network/${NET_NAME}" \
    || { echo "READY FAIL: ${NET_NAME} never reached Ready" >&2; restore_sample; exit 1; }

echo "=== asking on the same thread: \"$STATUS_QUESTION\""
status_turn "$THREAD_A" "$WORKDIR/vxlan-status.ndjson" || { echo "STATUS FAIL: the status turn failed" >&2; restore_sample; exit 1; }
print_stream "$WORKDIR/vxlan-status.ndjson"
final_message "$WORKDIR/vxlan-status.ndjson" "$WORKDIR/vxlan-answer.txt" || { restore_sample; exit 1; }
echo "=== the answer: $(cat "$WORKDIR/vxlan-answer.txt")"
assert_status "$WORKDIR/vxlan-answer.txt" "Network" "$NET_NAME" "ip-vrf" || { restore_sample; exit 1; }

# ============================== thread 2: SRv6 ===============================
echo
echo "=== thread 2: an SRv6 ip-vrf service, then the status question on its thread"
clear_intent || { restore_sample; exit 1; }

    # One bounded retry for the measured pinned-kuid-server carve defect
    # (see run-q12-run-examples.sh and GATE8-EVIDENCE.md).
    ATTEMPT_B=1
    while :; do
        bash "${REPO_ROOT}/agents/tests/integration/srv6_chat.sh" --request "$SRV6_REQUEST" --confirm 2 \
            | tee "$WORKDIR/srv6-turn.out"
        THREAD_B="$(sed -n 's/.* thread_id=\([^ ]*\).*/\1/p' "$WORKDIR/srv6-turn.out" | head -1)"
        SRV6_NAME="$(sed -n 's/.* service_id=\([^ ]*\).*/\1/p' "$WORKDIR/srv6-turn.out" | head -1)"
        [[ -n "$THREAD_B" && -n "$SRV6_NAME" ]] && break
        if [[ "$ATTEMPT_B" -eq 1 ]] \
            && grep -q "worker 'allocator' is unavailable" "$WORKDIR/srv6-turn.out"; then
            echo "=== the pinned kuid server's carve refused the request; retrying once"
            CID="$(sed -n 's/.* correlation_id=\([^ ]*\).*/\1/p' "$WORKDIR/srv6-turn.out" | head -1)"
            [[ -n "$CID" ]] && kc -n kuid-system delete ipclaims -l "agentic-netops.io/correlation-id=${CID}" --ignore-not-found >/dev/null 2>&1
            ATTEMPT_B=$((ATTEMPT_B + 1))
            clear_intent || { restore_sample; exit 1; }
            continue
        fi
        echo "CHAT FAIL: the SRv6 conversation did not create a service" >&2
        grep -E "refused|FAIL" "$WORKDIR/srv6-turn.out" | tail -2 >&2
        restore_sample
        exit 1
    done

echo "=== waiting for SRv6Service ${SRV6_NAME} to reach Ready"
kc -n "$NS_INTENT" wait --for=condition=Ready=True --timeout="$READY_TIMEOUT" "srv6service/${SRV6_NAME}" \
    || { echo "READY FAIL: ${SRV6_NAME} never reached Ready" >&2; restore_sample; exit 1; }

echo "=== asking on the same thread: \"$STATUS_QUESTION\""
status_turn "$THREAD_B" "$WORKDIR/srv6-status.ndjson" || { echo "STATUS FAIL: the status turn failed" >&2; restore_sample; exit 1; }
print_stream "$WORKDIR/srv6-status.ndjson"
final_message "$WORKDIR/srv6-status.ndjson" "$WORKDIR/srv6-answer.txt" || { restore_sample; exit 1; }
echo "=== the answer: $(cat "$WORKDIR/srv6-answer.txt")"
assert_status "$WORKDIR/srv6-answer.txt" "SRv6Service" "$SRV6_NAME" "ip-vrf over srv6" || { restore_sample; exit 1; }

# ======================= restore the phase-7 end state ======================
echo
echo "=== restore: clearing the receipt services and bringing back the sample"
clear_intent || exit 1
kc -n "$NS_INTENT" apply -f "$SAMPLE_FILE" >/dev/null \
    || { echo "RESTORE FAIL: sample re-apply failed" >&2; exit 3; }
kc -n "$NS_INTENT" wait --for=condition=Ready=True --timeout=300s srv6service/"$SAMPLE_NAME" \
    || { echo "RESTORE FAIL: sample did not come back Ready" >&2; exit 1; }
DP="$(kc -n "$NS_INTENT" get srv6service/"$SAMPLE_NAME" -o jsonpath='{.status.dataPath.result}')"
echo "=== restored: srv6service/${SAMPLE_NAME} Ready, data path=${DP}"
[[ "$DP" == "pass" ]] || { echo "RESTORE FAIL: restored sample data path not pass" >&2; exit 1; }
echo "=== status receipt complete: both transports answered with type and Ready"
