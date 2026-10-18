#!/usr/bin/env bash
# Proof q12-run-examples (US6, T548; SC-012): every SRv6 example the SERVED
# suggested-prompts endpoint offers is runnable on the live lab. The examples
# are fetched over the wire from GET /suggested-prompts (never copied from a
# file — the receipt witnesses the page, not the repo), each one is sent
# through the real tier by tests/integration/srv6_chat.sh --confirm 2, and
# each created SRv6Service must reach Ready=True by the controller's own
# condition (config apply, read-back verify, data-path probe pass).
#
# Destructive by construction: the served SRv6 examples bind leaf01/wan1 and
# leaf02/wan1 — the only SRv6-verifiable attachments on this profile (C7/C8)
# — so two examples are mutually exclusive. The documented swap (the
# q10-live T505 receipt) is generalised here: before each example the intent
# namespace's SRv6Services are deleted and waited gone; afterwards the
# bring-up sample (config/samples/srv6service-ip-vrf-vpn.yaml) is restored
# and re-verified Ready with a passing data path (the phase-7 end state).
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

kc() { kubectl --context "$CTX" "$@"; }

WORKDIR="$(mktemp -d)"
trap '[ -n "${PF_PID:-}" ] && kill "$PF_PID" 2>/dev/null; rm -rf "$WORKDIR"' EXIT

# ---- preflight: the tier must be up, and reachable over a port-forward ----
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

# ---- fetch the served SRv6 examples ----
curl -fsS --max-time 15 "$SUPERVISOR_URL/suggested-prompts" > "$WORKDIR/served.json" \
    || { echo "FAIL: /suggested-prompts did not answer" >&2; exit 1; }
python3 - "$WORKDIR/served.json" > "$WORKDIR/examples.txt" <<'PYEOF'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as fh:
    served = json.load(fh)
srv6 = [p for p in served if " over srv6" in p.lower()]
bad = [p for p in served if "mac-vrf over srv6" in p.lower() or "evpn" in p.lower()]
if bad:
    print("FAIL: the page serves an unsupported variant:", bad, file=sys.stderr)
    raise SystemExit(1)
if not srv6:
    print("FAIL: the page serves no SRv6 example", file=sys.stderr)
    raise SystemExit(1)
for p in srv6:
    print(p)
PYEOF
(( $? == 0 )) || exit 1
EXAMPLES="$(wc -l < "$WORKDIR/examples.txt")"
echo "=== served SRv6 examples to run: ${EXAMPLES}"
cat "$WORKDIR/examples.txt"

clear_srv6() {
    kc -n "$NS_INTENT" delete srv6services --all --ignore-not-found --timeout=180s >/dev/null \
        || { echo "SWAP FAIL: deleting the SRv6Services failed" >&2; return 1; }
    for _ in $(seq 1 60); do
        [[ "$(kc -n "$NS_INTENT" get srv6services --no-headers 2>/dev/null | wc -l)" == "0" ]] && break
        sleep 2
    done
    if [[ "$(kc -n "$NS_INTENT" get srv6services --no-headers 2>/dev/null | wc -l)" != "0" ]]; then
        echo "SWAP FAIL: SRv6Services still present after the delete window" >&2
        return 1
    fi
    # Settle before the next allocation: while the deleted services' client
    # /24 claims are still being released, the pinned kuid server's carve of
    # the NEXT claim can 500 ("ipclaims ... 192.168.N.0-24 not found") —
    # measured live (attempt 2's example 2). The next request only allocates
    # once the claim inventory has stopped moving.
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
    # PortInUse (the one live-found defect of the first q12-run-examples
    # attempt — the steer-assert failure path exited without the delete).
    clear_srv6 || return 1
    kc -n "$NS_INTENT" apply -f "$SAMPLE_FILE" >/dev/null 2>&1 || true
    kc -n "$NS_INTENT" wait --for=condition=Ready=True --timeout=300s srv6service/"$SAMPLE_NAME" >/dev/null 2>&1 || true
}

N=0
while IFS= read -r EXAMPLE; do
    N=$((N + 1))
    echo
    echo "==================================================================="
    echo "=== example ${N}/${EXAMPLES}: $EXAMPLE"
    echo "==================================================================="
    clear_srv6 || { restore_sample; exit 1; }
    echo "=== swap done: no SRv6Service holds the attachments"

    # One bounded retry for a measured pinned-kuid-server defect: the server's
    # own saveAll can 404 on the per-prefix object it just carved
    # ("kuid-system.srv6-client-v4.192.168.N.0-24 not found" — see
    # GATE8-EVIDENCE.md), surfacing as an allocator 500 and a refusal. It
    # heals on re-observation (attempt 3's example 1 survived the same
    # internal error server-side), so retry the example once after cleaning
    # the orphaned claim of the failed attempt.
    ATTEMPT=1
    while :; do
        bash "${REPO_ROOT}/tests/integration/srv6_chat.sh" --request "$EXAMPLE" --confirm 2 \
            | tee "$WORKDIR/turn-${N}.out"
        SERVICE_ID="$(sed -n 's/.* service_id=\([^ ]*\).*/\1/p' "$WORKDIR/turn-${N}.out" | head -1)"
        [[ -n "$SERVICE_ID" ]] && break
        if [[ "$ATTEMPT" -eq 1 ]] \
            && grep -q "worker 'allocator' is unavailable" "$WORKDIR/turn-${N}.out"; then
            echo "=== the pinned kuid server's carve refused the request (measured"
            echo "    upstream defect); cleaning the orphan claim and retrying once"
            CID="$(sed -n 's/.* correlation_id=\([^ ]*\).*/\1/p' "$WORKDIR/turn-${N}.out" | head -1)"
            [[ -n "$CID" ]] && kc -n kuid-system delete ipclaims -l "agentic-netops.io/correlation-id=${CID}" --ignore-not-found >/dev/null 2>&1
            ATTEMPT=$((ATTEMPT + 1))
            clear_srv6 || { restore_sample; exit 1; }
            continue
        fi
        echo "RUN FAIL: the tier conversation did not create the service for example ${N}" >&2
        grep -E "refused|FAIL" "$WORKDIR/turn-${N}.out" | tail -2 >&2
        restore_sample
        exit 1
    done

    echo "=== waiting for SRv6Service ${SERVICE_ID} to reach Ready (controller apply,"
    echo "    read-back verify, data-path probe)"
    kc -n "$NS_INTENT" wait --for=condition=Ready=True --timeout="$READY_TIMEOUT" "srv6service/${SERVICE_ID}" \
        || { echo "READY FAIL: ${SERVICE_ID} never reached Ready" >&2; restore_sample; exit 1; }
    kc -n "$NS_INTENT" get "srv6service/${SERVICE_ID}" -o jsonpath='conditions: {.status.conditions}{"\n"}dataPath: {.status.dataPath.result}{"\n"}specPath: {.spec.path.preferredSpine}{"\n"}activePath: {.status.activePath}{"\n"}'
    echo
    SPEC_SPINE="$(kc -n "$NS_INTENT" get "srv6service/${SERVICE_ID}" -o jsonpath='{.spec.path.preferredSpine}')"
    if [[ "$EXAMPLE" == *"preferring spine01"* ]]; then
        [[ "$SPEC_SPINE" == "spine01" ]] \
            || { echo "STEER FAIL: spec.path.preferredSpine='${SPEC_SPINE}', expected spine01" >&2; restore_sample; exit 1; }
        echo "OK: example ${N} reached Ready and steers via spine01 (spec.path.preferredSpine=${SPEC_SPINE})"
    else
        [[ -z "$SPEC_SPINE" ]] \
            || { echo "STEER FAIL: the plain example must not steer (spec.path.preferredSpine='${SPEC_SPINE}')" >&2; restore_sample; exit 1; }
        echo "OK: example ${N} reached Ready, unsteered (spec.path absent)"
    fi
done < "$WORKDIR/examples.txt"

# ---- restore the phase-7 end state ----
echo
echo "=== restore: clearing the receipt services and bringing back the sample"
clear_srv6 || exit 1
kc -n "$NS_INTENT" apply -f "$SAMPLE_FILE" >/dev/null \
    || { echo "RESTORE FAIL: sample re-apply failed" >&2; exit 3; }
kc -n "$NS_INTENT" wait --for=condition=Ready=True --timeout=300s srv6service/"$SAMPLE_NAME" \
    || { echo "RESTORE FAIL: sample did not come back Ready" >&2; exit 1; }
DP="$(kc -n "$NS_INTENT" get srv6service/"$SAMPLE_NAME" -o jsonpath='{.status.dataPath.result}')"
SPEC_SPINE="$(kc -n "$NS_INTENT" get srv6service/"$SAMPLE_NAME" -o jsonpath='{.spec.path.preferredSpine}')"
echo "=== restored: srv6service/${SAMPLE_NAME} Ready, data path=${DP}, spec.path.preferredSpine='${SPEC_SPINE}' (unsteered)"
[[ "$DP" == "pass" ]] || { echo "RESTORE FAIL: restored sample data path not pass" >&2; exit 1; }
[[ -z "$SPEC_SPINE" ]] || { echo "RESTORE FAIL: restored sample must be unsteered" >&2; exit 1; }
echo "=== all ${EXAMPLES} served SRv6 example(s) reached Ready; lab restored"
