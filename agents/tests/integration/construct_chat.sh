#!/usr/bin/env bash
# US4 (T511-T514, T625) — integration chat driver for a LEGACY construct
# request (vlan / mac-vrf / ip-vrf / acl / mac-vrf with gateway) through the
# tier AFTER the mapper's SRv6 change: the receipt that the legacy pipeline
# still provisions exactly as before.
#
# Same mechanics as srv6_chat.sh (POST /agent/prompt/stream ndjson, turn by
# turn, reply "confirm" at the confirmation points) with LEGACY end-state
# assertions:
#   - confirm path: at least one Network carrying the conversation's
#     correlation-id label exists (the deployer stamps every object in the
#     transaction), its status is printed, and the kuid claims for the
#     correlation id are live; then the service is torn down again (Networks
#     deleted, claims waited away) so the next receipt starts clean.
#   - decline path: no Network, no claim and no SRv6Service for the
#     request's correlation id (a declined request changes nothing).
#
# Usage:
#   construct_chat.sh --request <text> [--confirm <n>] [--decline]
#
# Environment: SUPERVISOR_URL (default http://localhost:9090), KUBECTL.
set -uo pipefail

SUPERVISOR_URL="${SUPERVISOR_URL:-http://localhost:9090}"
KUBECTL="${KUBECTL:-kubectl}"
CLAIM_NS="kuid-system"
CLAIM_LABEL="agentic-netops.io/correlation-id"
# The tier assigns a NEW correlation id per stream (per POST /turn), so the
# submit transaction — and therefore the correlation label the deployer stamps
# onto the created objects and claims — carries the LAST turn's id, not the
# thread's first-turn id. The receipt checks the SUBMIT correlation; the
# first-turn id is still printed for the audit trail.
EXPECT_CLAIMS="1"  # minimum live claims; acl constructs claim nothing -> 0

REQUEST=""
CONFIRM_AT=0
DECLINE=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --request) [[ $# -ge 2 ]] || { echo "error: --request needs a value" >&2; exit 2; }; REQUEST="$2"; shift 2 ;;
        --confirm) [[ $# -ge 2 ]] || { echo "error: --confirm needs a value" >&2; exit 2; }; CONFIRM_AT="$2"; shift 2 ;;
        --decline) DECLINE=1; shift ;;
        --expect-claims) [[ $# -ge 2 ]] || { echo "error: --expect-claims needs a value" >&2; exit 2; }; EXPECT_CLAIMS="$2"; shift 2 ;;
        *) echo "error: unknown argument: $1" >&2; exit 2 ;;
    esac
done
[[ -n "$REQUEST" ]] || { echo "error: --request is required" >&2; exit 2; }
(( CONFIRM_AT >= 1 )) || { echo "error: --confirm must be >= 1" >&2; exit 2; }

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT
TURN_FILE="$WORKDIR/turn.ndjson"
THREAD_ID=""
CORRELATION_ID=""
SUBMIT_CORR=""
CORRELATIONS=""
CONFIRMATION_POINTS=0
DECLINED_AT=0

json_field() {
    sed -n 's/.*"'"$1"'"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$2" | head -1
}

send_turn() {
    local payload
    payload="$(python3 -c 'import json,sys; print(json.dumps({"prompt": sys.argv[1], "thread_id": sys.argv[2] or None}))' "$1" "$THREAD_ID")"
    curl -N -sS -X POST "$SUPERVISOR_URL/agent/prompt/stream" \
        -H 'Content-Type: application/json' \
        -d "$payload" > "$TURN_FILE"
}

print_turn() {
    python3 - "$TURN_FILE" <<'PYEOF'
import json, sys

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
        if kind in ("confirmation_request", "clarification_request") and chunk.get("prompt"):
            print("--- awaiting confirmation / clarification ---")
            print(chunk["prompt"])
        elif kind == "progress" and chunk.get("message"):
            print(chunk["message"])
        elif kind == "final" and chunk.get("message"):
            print(chunk["message"])
        elif kind == "error":
            print(f"refused: {chunk.get('reason', '(no reason given)')}")
PYEOF
}

post_turn() {
    send_turn "$1"
    echo "=== operator: $1"
    print_turn
    if [[ -z "$THREAD_ID" ]]; then
        THREAD_ID="$(json_field thread_id "$TURN_FILE")"
    fi
    if [[ -z "$CORRELATION_ID" ]]; then
        CORRELATION_ID="$(json_field correlation_id "$TURN_FILE")"
    fi
    # every turn re-stamps the submit correlation
    LAST_CORR="$(json_field correlation_id "$TURN_FILE")"
    [[ -n "$LAST_CORR" ]] && SUBMIT_CORR="$LAST_CORR"
    # the tier assigns one correlation PER STREAM: the allocator turn (whose id
    # the claimed identifiers carry) differs from the submit turn (whose id the
    # created Networks carry), so the receipt must scan ALL of them
    case " ${CORRELATIONS} " in
        *" ${LAST_CORR} "*) ;;
        *) CORRELATIONS="${CORRELATIONS:+${CORRELATIONS} }${LAST_CORR}" ;;
    esac
    local points
    points="$(grep -c '"type": "confirmation_request"' "$TURN_FILE" || true)"
    CONFIRMATION_POINTS=$((CONFIRMATION_POINTS + points))
    LAST_TURN_POINTS="$points"
}

# set_reply_word — the confirmation word for the CURRENT point. Runs in the
# caller's shell (NOT in $() — a command substitution would lose the
# DECLINED_AT assignment and repost "decline" forever).
set_reply_word() {
    if (( DECLINE )) && (( CONFIRMATION_POINTS == CONFIRM_AT )); then
        DECLINED_AT="$CONFIRMATION_POINTS"
        WORD="decline"
    else
        WORD="confirm"
    fi
}

# ---------------- run the conversation ----------------
# The driver answers EVERY confirmation point the tier offers, up to the
# CONFIRM_AT-th (decline mode answers that one with "decline"). The reply to
# a point comes AFTER the point was counted, so the loop is driven by the
# last turn's point count — a cumulative guard would stop one reply short and
# leave the service stuck at "Deploy this service?".
post_turn "$REQUEST"
OWED="$LAST_TURN_POINTS"

while (( OWED > 0 )); do
    set_reply_word
    post_turn "$WORD"
    OWED="$LAST_TURN_POINTS"
done

# A decline receipt must witness a real confirmation point: if the tier never
# offered one (refusal, transport race, classifier drift), there is nothing
# that was declined and the run must fail rather than print a vacuous OK.
if (( DECLINE && DECLINED_AT == 0 )); then
    echo "FAIL: the tier never offered confirmation point ${CONFIRM_AT}, so nothing was declined" >&2
    exit 1
fi

echo "=== session: thread_id=$THREAD_ID correlation_id=$CORRELATION_ID submit_correlation=$SUBMIT_CORR confirmation_points=$CONFIRMATION_POINTS"

# ---------------- claims for the thread's correlations ----------------
# Served kuid claims (vlan/genid/extcomm/ip) are labeled with the correlation;
# identifiers that hit the Lease fallback (the pinned server's broken served
# pools) instead hold the correlation in spec.holderIdentity / the
# allocation-correlation annotation. Claims may carry ANY of the thread's
# per-stream correlations (the allocator turn's, not just the submit turn's).
claims_for() {
    local found="" kind corr
    for corr in $CORRELATIONS; do
        for kind in genidclaims vlanclaims extcommclaims ipclaims; do
            found="$found$("$KUBECTL" get -n "$CLAIM_NS" "$kind" -l "$CLAIM_LABEL=$corr" -o name 2>/dev/null || true)"
        done
    done
    found="$found$("$KUBECTL" get -n "$CLAIM_NS" leases -o json 2>/dev/null \
        | python3 -c '
import json, sys

corrs = [c for c in sys.argv[1].split() if c]
if not corrs:
    sys.exit(0)
try:
    doc = json.load(sys.stdin)
except json.JSONDecodeError:
    sys.exit(0)
for item in doc.get("items", []):
    meta = item.get("metadata", {})
    spec = item.get("spec", {})
    held = (meta.get("annotations", {}).get("agentic-netops.io/allocation-correlation")
            or spec.get("holderIdentity") or "")
    if any(c in held for c in corrs):
        print("lease." + meta.get("name", ""))
' "$CORRELATIONS" 2>/dev/null || true)"
    printf '%s' "$found"
}

# ---------------- objects for the submit correlation id ----------------
# fully-qualified "<namespace>/<name>" so the teardown deletes in the right ns
networks_for() {
    "$KUBECTL" get networks -A -l "$CLAIM_LABEL=$SUBMIT_CORR" \
        -o jsonpath='{range .items[*]}{.metadata.namespace}{"/"}{.metadata.name}{"\n"}{end}' 2>/dev/null || true
}

if (( DECLINE )); then
    echo "=== decline end-state check"
    NETS="$(networks_for)"
    if [[ -n "$NETS" ]]; then
        echo "FAIL: Network exists after decline: $NETS" >&2
        exit 1
    fi
    CLAIMS="$(claims_for)"
    if [[ -n "$CLAIMS" ]]; then
        echo "FAIL: claims survive after decline: $CLAIMS" >&2
        exit 1
    fi
    SRV6="$("$KUBECTL" get srv6services.agentic-netops.io -A -o name 2>/dev/null | grep -F "$CORRELATION_ID" || true)"
    if [[ -n "$SRV6" ]]; then
        echo "FAIL: SRv6Service exists after decline: $SRV6" >&2
        exit 1
    fi
    echo "OK: declined at confirmation point ${DECLINED_AT}; no Network, no claim, no SRv6Service."
    exit 0
fi

# ---------------- confirm path: the legacy pipeline provisioned ----------------
NETS="$(networks_for)"
if [[ -z "$NETS" ]]; then
    echo "FAIL: no Network carries the submit correlation label $CLAIM_LABEL=$SUBMIT_CORR" >&2
    "$KUBECTL" get networks -A || true
    exit 1
fi
echo "=== Networks for this request:"
echo "$NETS"
echo "=== Network status (printed as observed; convergence is the lab's device-level tier):"
while IFS= read -r obj; do
    [[ -z "$obj" ]] && continue
    "$KUBECTL" get "$obj" -o jsonpath='{.metadata.name}: {.status.conditions[*].type}{"\n"}' 2>/dev/null || true
done <<< "$NETS"
CLAIMS="$(claims_for)"
if (( EXPECT_CLAIMS > 0 )) && [[ -z "$CLAIMS" ]]; then
    echo "FAIL: no live kuid claim or lease for this thread (the legacy pipeline claims identifiers)" >&2
    exit 1
fi
echo "=== live identifiers for the thread (expected >= $EXPECT_CLAIMS):"
echo "${CLAIMS:-(none)}"
N_CLAIMS=0
[[ -n "$CLAIMS" ]] && N_CLAIMS="$(printf '%s\n' "$CLAIMS" | wc -l)"
if (( N_CLAIMS < EXPECT_CLAIMS )); then
    echo "FAIL: expected at least $EXPECT_CLAIMS live claims, found $N_CLAIMS" >&2
    exit 1
fi
echo "OK: legacy provision complete for submit correlation id $SUBMIT_CORR."

# ---------------- teardown so the next receipt starts clean ----------------
echo "=== teardown: deleting the receipt's Networks, waiting for the claims to release"
while IFS= read -r obj; do
    [[ -z "$obj" ]] && continue
    ns="${obj%%/*}"; name="${obj#*/}"
    "$KUBECTL" delete -n "$ns" "network.network.kubenet.dev/$name" --timeout=180s >/dev/null \
        || { echo "TEARDOWN FAIL: $obj delete failed" >&2; exit 3; }
done <<< "$NETS"
for _ in $(seq 1 60); do
    [[ -z "$(claims_for)" ]] && break
    sleep 2
done
CLAIMS="$(claims_for)"
if [[ -n "$CLAIMS" ]]; then
    # Disclosed lab limitation: the Lease fallback creates plain Leases with no
    # owner reference, so nothing in the cluster releases them when the
    # receipt's Networks are deleted (the kuid ipam GC only reclaims
    # owner-referenced ipclaims). The test releases the thread's fallback
    # leases explicitly so the next receipt starts from a clean pool.
    echo "=== note: fallback leases are not GC-reclaimed; releasing this thread's leases explicitly"
    LEASE_NAMES="$("$KUBECTL" -n kuid-system get leases -o json 2>/dev/null | python3 -c '
import json, sys
corrs = set(sys.argv[1].split())
for l in json.load(sys.stdin).get("items", []):
    a = l.get("metadata", {}).get("annotations", {})
    if a.get("agentic-netops.io/correlation-id") in corrs:
        print(l["metadata"]["name"])
' "$CORRELATIONS")"
    for _ln in $LEASE_NAMES; do
        "$KUBECTL" -n kuid-system delete lease "$_ln" --timeout=60s --ignore-not-found >/dev/null \
            || { echo "TEARDOWN FAIL: lease release for $_ln failed" >&2; exit 3; }
    done
    sleep 2
    CLAIMS="$(claims_for)"
    if [[ -n "$CLAIMS" ]]; then
        echo "TEARDOWN FAIL: claims still live after explicit release: $CLAIMS" >&2
        exit 3
    fi
    echo "=== teardown complete after explicit lease release"
    exit 0
fi
echo "=== teardown complete: no Network, no claim"

# ---------------- teardown so the next receipt starts clean ----------------
echo "=== teardown: deleting the receipt's Networks, waiting for the claims to release"
