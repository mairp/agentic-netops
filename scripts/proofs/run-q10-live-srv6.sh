#!/usr/bin/env bash
# Proof q10-live-ip-vrf-vpn (US4, T505) / q10-decline-ip-vrf-vpn (T506):
# a plain-language ip-vrf over srv6 request through the REAL tier on the
# live lab — the supervisor's chat API, the real mapper/allocator/deployer,
# the real SRv6 controller, the real devices.
#
# Two modes:
#   run-q10-live-srv6.sh --request "<text>" --confirm 2
#       T505. DESTRUCTIVE by construction: on this lab the bring-up sample
#       (config/samples/srv6service-ip-vrf-vpn.yaml, applied by provision.sh
#       T400) holds the only SRv6-verifiable attachments
#       (leaf01/wan1, leaf02/wan1 — srv6-probe-attachments, C8), so a second
#       live request on the same ports is terminal PortInUse (the
#       q9-port-in-use precedent). The receipt therefore runs the documented
#       swap: the sample is deleted (its own bring-up receipt lives in the
#       provision log), the chat request provisions IN ITS PLACE, the
#       created service must reach Ready with the controller's own data-path
#       probe pass, and afterwards the sample is restored and re-verified.
#       Every step is printed; the .out is self-describing.
#   run-q10-live-srv6.sh --request "<text>" --confirm 1 --decline
#       T506. No swap: the decline asserts the request changes nothing.
#
# Exits non-zero if the supervisor is unreachable, any wait times out, the
# end state fails, or the sample restore does not come back Ready.
set -uo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CTX="${CTX:-kind-agentic-netops}"
NS_AGENTS="agentic-netops-agents"
NS_INTENT="agentic-netops-intent"
SAMPLE_NAME="srv6-ip-vrf-vpn"
SAMPLE_FILE="${REPO_ROOT}/config/samples/srv6service-ip-vrf-vpn.yaml"
# Host port for the supervisor port-forward. NOT the lab's historical 9090:
# a docker-published Prometheus already owns host 9090 on this box (its Go
# 404s masqueraded as the supervisor's once), so the receipt forwards to a
# port nothing else claims and points the chat driver at it explicitly.
PF_PORT="${PF_PORT:-19090}"
REQUEST=""
CONFIRM_AT=0
DECLINE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --request) REQUEST="$2"; shift 2 ;;
    --confirm) CONFIRM_AT="$2"; shift 2 ;;
    --decline) DECLINE=1; shift ;;
    *) echo "run-q10-live-srv6.sh: unknown argument: $1" >&2; exit 2 ;;
  esac
done
[[ -n "$REQUEST" && "$CONFIRM_AT" -ge 1 ]] || { echo "run-q10-live-srv6.sh: --request and --confirm are required" >&2; exit 2; }

kc() { kubectl --context "$CTX" "$@"; }

# ---- preflight: the tier must be up (fail fast, never fabricate) ----
kc -n "$NS_AGENTS" get deploy supervisor >/dev/null \
  || { echo "PREFLIGHT FAIL: supervisor deployment not found" >&2; exit 3; }
kc -n "$NS_AGENTS" wait --for=condition=Available --timeout=60s deploy/supervisor >/dev/null \
  || { echo "PREFLIGHT FAIL: supervisor not Available" >&2; exit 3; }

# ---- reach the supervisor's chat API from the host ----
kc -n "$NS_AGENTS" port-forward svc/supervisor "${PF_PORT}:9090" >/dev/null 2>&1 &
PF_PID=$!
trap 'kill "$PF_PID" 2>/dev/null || true' EXIT
PF_OK=0
for _ in $(seq 1 30); do
  if curl -sS -o /dev/null --max-time 2 "http://localhost:${PF_PORT}/health"; then
    PF_OK=1; break
  fi
  sleep 1
done
(( PF_OK )) || { echo "PREFLIGHT FAIL: supervisor never answered on localhost:${PF_PORT}" >&2; exit 3; }
echo "=== supervisor reachable on localhost:${PF_PORT}"

if (( ! DECLINE )); then
  # ---- the documented swap: free the only verifiable attachments ----
  echo "=== swap: deleting the bring-up sample ${SAMPLE_NAME} (frees leaf01/wan1, leaf02/wan1;"
  echo "    the sample's own receipt lives in the provision log; restored at the end)"
  kc -n "$NS_INTENT" get srv6service/"$SAMPLE_NAME" >/dev/null 2>&1 \
    || { echo "SWAP FAIL: sample ${SAMPLE_NAME} not present — refusing to run against an unknown lab state" >&2; exit 3; }
  kc -n "$NS_INTENT" delete srv6service/"$SAMPLE_NAME" --timeout=180s >/dev/null \
    || { echo "SWAP FAIL: sample delete failed" >&2; exit 3; }
fi

# ---- the request through the real tier ----
restore_sample() {
  # Best-effort restore so a failed run never leaves the lab without the
  # bring-up sample (the swap deleted it). Runs on the CHAT FAIL path only;
  # the success path restores explicitly below.
  kc -n "$NS_INTENT" get srv6service/"$SAMPLE_NAME" >/dev/null 2>&1 && return 0
  echo "=== chat failed: restoring the bring-up sample before exiting" >&2
  kc -n "$NS_INTENT" apply -f "$SAMPLE_FILE" >/dev/null 2>&1 || true
  kc -n "$NS_INTENT" wait --for=condition=Ready=True --timeout=300s srv6service/"$SAMPLE_NAME" >/dev/null 2>&1 || true
}
CHAT_ARGS=(--request "$REQUEST" --confirm "$CONFIRM_AT")
(( DECLINE )) && CHAT_ARGS+=(--decline)
SUPERVISOR_URL="http://localhost:${PF_PORT}" bash "${REPO_ROOT}/agents/tests/integration/srv6_chat.sh" "${CHAT_ARGS[@]}" \
  || { echo "CHAT FAIL: the tier conversation did not reach its expected end state" >&2; restore_sample; exit 1; }

if (( DECLINE )); then
  echo "=== decline receipt complete: nothing on the cluster, no claim"
  exit 0
fi

# ---- the created service: exactly one, Ready, data path passed ----
CREATED="$(kc -n "$NS_INTENT" get srv6services -o name | head -1)"
COUNT="$(kc -n "$NS_INTENT" get srv6services --no-headers 2>/dev/null | wc -l)"
echo "=== srv6services after the request: ${COUNT} (${CREATED})"
if [[ "$COUNT" != "1" || -z "$CREATED" ]]; then
  echo "STATE FAIL: expected exactly one SRv6Service, got ${COUNT}" >&2; exit 1
fi
echo "=== waiting for ${CREATED} to reach Ready (includes the controller's"
echo "    config apply, read-back verify and data-path probe ping)"
kc -n "$NS_INTENT" wait --for=condition=Ready=True --timeout=300s "$CREATED" || exit 1
kc -n "$NS_INTENT" get "$CREATED" -o jsonpath='{.status.conditions}' ; echo
DP="$(kc -n "$NS_INTENT" get "$CREATED" -o jsonpath='{.status.dataPath.result}')"
echo "=== data path: result=${DP} (controller probe ping over the SRv6 path)"
if [[ "$DP" != "pass" ]]; then
  echo "TRAFFIC FAIL: data path did not pass" >&2; exit 1
fi

# ---- restore: remove the receipt service, bring the sample back ----
echo "=== restore: deleting the receipt service (controller rolls the devices back,"
echo "    releases the claims) and re-applying the bring-up sample"
kc -n "$NS_INTENT" delete "$CREATED" --timeout=180s >/dev/null \
  || { echo "RESTORE FAIL: receipt service delete failed" >&2; exit 3; }
kc -n "$NS_INTENT" apply -f "$SAMPLE_FILE" >/dev/null \
  || { echo "RESTORE FAIL: sample re-apply failed" >&2; exit 3; }
kc -n "$NS_INTENT" wait --for=condition=Ready=True --timeout=300s srv6service/"$SAMPLE_NAME" \
  || { echo "RESTORE FAIL: sample did not come back Ready" >&2; exit 1; }
DP="$(kc -n "$NS_INTENT" get srv6service/"$SAMPLE_NAME" -o jsonpath='{.status.dataPath.result}')"
echo "=== restored: srv6service/${SAMPLE_NAME} Ready, data path result=${DP}"
[[ "$DP" == "pass" ]] || { echo "RESTORE FAIL: restored sample data path not pass" >&2; exit 1; }
echo "=== live receipt complete"
