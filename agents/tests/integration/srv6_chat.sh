#!/usr/bin/env bash
# US4 (T503/T504) — integration chat driver for an SRv6 service request.
#
# Drives the provisioning supervisor's chat endpoint
# (POST /agent/prompt/stream, application/x-ndjson — there is no WebSocket
# route) turn by turn: it prints each turn's operator-facing text, replies
# with the confirmation word at the requested confirmation point, and at the
# end reports the objects created (SRv6Service, Network) plus whether any
# KUID claim survives for the request's correlation id.
#
# Usage:
#   srv6_chat.sh --request <text> [--confirm <n>] [--decline]
#
#   --request <text>   the first turn (the operator's SRv6 request)
#   --confirm <n>      reply "confirm" from confirmation point 1 up to point
#                      <n>; --confirm 1 --decline declines at the FIRST
#                      confirmation point instead
#   --decline          decline (instead of confirm) at point <n>
#
# Exits non-zero if the expected end state fails:
#   - decline path: an SRv6Service, a Network, or a live claim existing for
#     the request is a failure (a declined request changes nothing);
#   - confirm path: no SRv6Service for the service id is a failure.
#
# Environment:
#   SUPERVISOR_URL   default http://localhost:9090
#   KUBECTL          default kubectl
set -euo pipefail

SUPERVISOR_URL="${SUPERVISOR_URL:-http://localhost:9090}"
KUBECTL="${KUBECTL:-kubectl}"
CLAIM_NS="kuid-system"
CLAIM_LABEL="agentic-netops.io/correlation-id"

REQUEST=""
CONFIRM_AT=0
DECLINE=0

usage() {
    cat <<'EOF'
Usage: srv6_chat.sh --request <text> [--confirm <n>] [--decline]

  --request <text>   first turn: the operator's SRv6 service request
  --confirm <n>      confirm at confirmation point <n> (1 = first mapper
                     confirmation, 2 = allocator deployment confirmation);
                     earlier points are confirmed automatically
  --decline          decline at point <n> instead of confirming
                     (with --confirm 1: declines at the first confirmation)

Environment: SUPERVISOR_URL (default http://localhost:9090), KUBECTL.
EOF
}

if [[ $# -eq 0 ]]; then
    usage
    exit 2
fi

while [[ $# -gt 0 ]]; do
    case "$1" in
        --request)
            [[ $# -ge 2 ]] || { echo "error: --request needs a value" >&2; usage >&2; exit 2; }
            REQUEST="$2"; shift 2 ;;
        --confirm)
            [[ $# -ge 2 ]] || { echo "error: --confirm needs a value" >&2; usage >&2; exit 2; }
            CONFIRM_AT="$2"; shift 2 ;;
        --decline)
            DECLINE=1; shift ;;
        -h|--help)
            usage; exit 0 ;;
        *)
            echo "error: unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
done

if [[ -z "$REQUEST" ]]; then
    echo "error: --request is required" >&2
    usage >&2
    exit 2
fi
if (( CONFIRM_AT < 1 )); then
    echo "error: --confirm must be >= 1" >&2
    usage >&2
    exit 2
fi

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT
TURN_FILE="$WORKDIR/turn.ndjson"
THREAD_ID=""
CORRELATION_ID=""
SERVICE_ID=""
CONFIRMATION_POINTS=0
DECLINED_AT=0

# json_field <key> <file> — first "key": "value" occurrence in the ndjson file.
json_field() {
    sed -n 's/.*"'"$1"'"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$2" | head -1
}

send_turn() {
    local prompt="$1"
    local payload
    payload="$(python3 -c 'import json,sys; print(json.dumps({"prompt": sys.argv[1], "thread_id": sys.argv[2] or None}))' "$prompt" "$THREAD_ID")"
    curl -N -sS -X POST "$SUPERVISOR_URL/agent/prompt/stream" \
        -H 'Content-Type: application/json' \
        -d "$payload" > "$TURN_FILE"
}

print_turn() {
    # Every operator-facing chunk of the turn: clarification prompts,
    # confirmation prompts, progress messages, the final message, errors.
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

# post_turn <prompt> — send one turn, print it, harvest ids and count the
# confirmation points this turn produced.
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
    if [[ -z "$SERVICE_ID" ]]; then
        SERVICE_ID="$(json_field serviceId "$TURN_FILE")"
    fi
    local points
    points="$(grep -c '"type": "confirmation_request"' "$TURN_FILE" || true)"
    CONFIRMATION_POINTS=$((CONFIRMATION_POINTS + points))
    LAST_TURN_POINTS="$points"
}

# reply_word — the confirmation word for the CURRENT point. Runs in the
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
# leave the service stuck at "Deploy this service?" (the T505 failure).
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
    echo "CHAT FAIL: the tier never offered confirmation point ${CONFIRM_AT}, so nothing was declined" >&2
    exit 1
fi

echo "=== session: thread_id=$THREAD_ID correlation_id=$CORRELATION_ID service_id=$SERVICE_ID confirmation_points=$CONFIRMATION_POINTS"

# ---------------- report the objects created ----------------
echo "=== objects created"
"$KUBECTL" get srv6services.agentic-netops.io -A || true
echo "--- networks matching the request's service id"
"$KUBECTL" get networks -A || true
if [[ -n "$SERVICE_ID" ]]; then
    "$KUBECTL" get networks -A -o name | grep "$SERVICE_ID" || echo "(no Network for $SERVICE_ID)"
fi

echo "=== claim existence check (namespace $CLAIM_NS, correlation id ${CORRELATION_ID:-none})"
CLAIMS_FOUND=0
# ipclaims included: an ip-vrf over SRv6 claims the endpoints' client /24s
# from the srv6-client-v4 pool under the thread's correlation id (SC-010)
for KIND in genidclaims vlanclaims extcommclaims ipclaims; do
    if [[ -n "$CORRELATION_ID" ]]; then
        FOUND="$("$KUBECTL" get -n "$CLAIM_NS" "$KIND" -l "$CLAIM_LABEL=$CORRELATION_ID" -o name 2>/dev/null || true)"
    else
        FOUND=""
    fi
    if [[ -n "$FOUND" ]]; then
        echo "$FOUND"
        CLAIMS_FOUND=1
    fi
done
if (( ! CLAIMS_FOUND )); then
    echo "(no live claim for this request)"
fi

# ---------------- assert the expected end state ----------------
# Scope every check to THIS request's objects: the lab legitimately holds
# other services (the bring-up sample among them), so a decline fails only
# when THIS request's objects exist — an empty service id means the request
# never reached a mapped object, and only the correlation-id claim check
# then applies.
SRV6_OBJECT=""
NETWORK_OBJECT=""
if [[ -n "$SERVICE_ID" ]]; then
    SRV6_OBJECT="$("$KUBECTL" get srv6services.agentic-netops.io -A -o name 2>/dev/null | grep -F "$SERVICE_ID" || true)"
    NETWORK_OBJECT="$("$KUBECTL" get networks -A -o name 2>/dev/null | grep -F "$SERVICE_ID" || true)"
fi

if (( DECLINE )); then
    # A declined request changes nothing: no SRv6Service, no Network, no claim.
    if [[ -n "$SRV6_OBJECT" ]]; then
        echo "FAIL: SRv6Service exists after decline: $SRV6_OBJECT" >&2
        exit 1
    fi
    if [[ -n "$NETWORK_OBJECT" ]]; then
        echo "FAIL: Network exists after decline: $NETWORK_OBJECT" >&2
        exit 1
    fi
    if (( CLAIMS_FOUND )); then
        echo "FAIL: a claim still exists after decline (claims must be released)" >&2
        exit 1
    fi
    echo "OK: declined at confirmation point ${DECLINED_AT:-$CONFIRM_AT}; no SRv6Service, no Network, no claim."
    exit 0
fi

if [[ -z "$SRV6_OBJECT" ]]; then
    echo "FAIL: no SRv6Service found for service id $SERVICE_ID after confirmation" >&2
    exit 1
fi
echo "OK: SRv6Service created for $SERVICE_ID."
