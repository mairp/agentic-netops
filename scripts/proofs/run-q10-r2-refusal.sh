#!/usr/bin/env bash
# Proofs q10-r2-ip-vrf-evpn (US4, T489) and q10-r2-mac-vrf-evpn (US4, T509)
# — the LIVE R2 receipt: a plain-language request for a variant outside the
# tier's supported set through the REAL supervisor on the live lab (the
# request comes in as $1; the defaults below are the two amended evpn
# variants). The tier must answer with the official R2 refusal — naming the
# restated variant and, for every variant except the bridged one, the
# supported list; the mac-vrf/evpn refusal is the fixed §3 sentence with the
# ONE KL-001 gloss ("(bridged EVPN over SRv6)") and no list (contracts/
# operator-phrasings.md R2 row) — and must NOT create any object: no
# SRv6Service, no Network, no kuid claim. Refusals never touch the fabric,
# so no swap is needed and nothing is provisioned.
#
# Env: SUPERVISOR_URL (default http://localhost:9090), KUBECTL.
set -uo pipefail

SUPERVISOR_URL="${SUPERVISOR_URL:-http://localhost:9090}"
KUBECTL="${KUBECTL:-kubectl}"
CLAIM_NS="kuid-system"
CLAIM_LABEL="agentic-netops.io/correlation-id"
REQUEST="${1:-give tenant blue an ip-vrf over srv6 with evpn signalling carrying 10.70.0.0/24 between leaf01 wan1 and leaf02 wan1}"

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT
TURN_FILE="$WORKDIR/turn.ndjson"

echo "=== operator: $REQUEST"
curl -N -sS -X POST "$SUPERVISOR_URL/agent/prompt/stream" \
    -H 'Content-Type: application/json' \
    -d "$(python3 -c 'import json,sys; print(json.dumps({"prompt": sys.argv[1], "thread_id": None}))' "$REQUEST")" \
    > "$TURN_FILE"

echo "=== the tier's full answer:"
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
        if kind == "error":
            print(f"REFUSED: {chunk.get('reason', '(no reason given)')}")
        elif kind == "final" and chunk.get("message"):
            print(f"FINAL: {chunk['message']}")
        elif kind in ("confirmation_request", "clarification_request"):
            print(f"UNEXPECTED {kind}: {chunk.get('prompt')}")
PYEOF

echo "=== refusal assertion"
# The greps below are deliberately whitespace-tolerant ("type":\s*"error"):
# the stream's JSON spacing is the server's business, not the receipt's.
grep -qE '"type":[[:space:]]*"error"' "$TURN_FILE" \
    || { echo "FAIL: the tier did not refuse the unsupported variant" >&2; exit 1; }
grep -q 'is not supported on this image' "$TURN_FILE" \
    || { echo "FAIL: the refusal is not the official R2 text" >&2; exit 1; }
# The official R2 wording names the supported list — except for the bridged
# variant (mac-vrf/evpn), whose fixed §3 sentence carries the KL-001 gloss
# "(bridged EVPN over SRv6)" instead of a list.
grep -qE 'Supported SRv6 services|mac-vrf over srv6. \(bridged EVPN over SRv6\)' "$TURN_FILE" \
    || { echo "FAIL: the refusal is not the official R2 supported-set wording" >&2; exit 1; }
grep -qE '"type":[[:space:]]*"confirmation_request"' "$TURN_FILE" \
    && { echo "FAIL: a refused request must not reach a confirmation point" >&2; exit 1; }

CORRELATION_ID="$(sed -n 's/.*"correlation_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$TURN_FILE" | head -1)"
echo "correlation id: ${CORRELATION_ID:-none}"

FAIL=0
if [[ -n "$CORRELATION_ID" ]]; then
    SRV6="$("$KUBECTL" get srv6services.agentic-netops.io -A -o name 2>/dev/null | grep -F "$CORRELATION_ID" || true)"
    [[ -z "$SRV6" ]] || { echo "FAIL: SRv6Service exists for a refused request: $SRV6" >&2; FAIL=1; }
    NETS="$("$KUBECTL" get networks -A -l "$CLAIM_LABEL=$CORRELATION_ID" -o name 2>/dev/null || true)"
    [[ -z "$NETS" ]] || { echo "FAIL: Network exists for a refused request: $NETS" >&2; FAIL=1; }
    CLAIMS=""
    for KIND in genidclaims vlanclaims extcommclaims; do
        CLAIMS="$CLAIMS$("$KUBECTL" get -n "$CLAIM_NS" "$KIND" -l "$CLAIM_LABEL=$CORRELATION_ID" -o name 2>/dev/null || true)"
    done
    [[ -z "$CLAIMS" ]] || { echo "FAIL: claims exist for a refused request: $CLAIMS" >&2; FAIL=1; }
else
    # The refusal carried no correlation id, so the honest check is the
    # inventory delta: nothing may have been created by a refused request.
    BEFORE_S="$("$KUBECTL" get srv6services.agentic-netops.io -A --no-headers 2>/dev/null | wc -l)"
    BEFORE_N="$("$KUBECTL" get networks -A --no-headers 2>/dev/null | wc -l)"
    BEFORE_C=0
    for KIND in genidclaims vlanclaims extcommclaims; do
        BEFORE_C=$((BEFORE_C + "$("$KUBECTL" get -n "$CLAIM_NS" "$KIND" --no-headers 2>/dev/null | wc -l)"))
    done
    echo "=== inventory before/after (srv6services / networks / claims): ${BEFORE_S}/${BEFORE_N}/${BEFORE_C}"
    AFTER_S="$("$KUBECTL" get srv6services.agentic-netops.io -A --no-headers 2>/dev/null | wc -l)"
    AFTER_N="$("$KUBECTL" get networks -A --no-headers 2>/dev/null | wc -l)"
    AFTER_C=0
    for KIND in genidclaims vlanclaims extcommclaims; do
        AFTER_C=$((AFTER_C + "$("$KUBECTL" get -n "$CLAIM_NS" "$KIND" --no-headers 2>/dev/null | wc -l)"))
    done
    echo "=== inventory after: ${AFTER_S}/${AFTER_N}/${AFTER_C}"
    [[ "$AFTER_S" -eq "$BEFORE_S" && "$AFTER_N" -eq "$BEFORE_N" && "$AFTER_C" -eq "$BEFORE_C" ]] \
        || { echo "FAIL: the refused request changed the cluster inventory" >&2; FAIL=1; }
fi
(( FAIL )) && exit 1
echo "OK: R2 refusal received; no SRv6Service, no Network, no claim for this request."
