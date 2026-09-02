#!/usr/bin/env bash
# US2 / FR-016 / SC-005: the tier's structural denials — the identities
# CANNOT express the action (the guardrail holds even if an agent
# misbehaves). Covers the full tier identity set, not just the two
# token-bearing writers asserted by rbac-denials.sh:
#
#   identity-denials (must answer "no"):
#     intent-supervisor / intent-mapper / intent-ui  -> no cluster API at
#       all: no networks, no events, no secrets (their ServiceAccounts
#       are automountServiceAccountToken: false — they hold no token);
#     intent-allocator -> claim-only: no networks, no events in
#       ainetops-intent;
#     intent-deployer  -> scoped writer: no secrets/pods, nothing outside
#       ainetops-intent.
#   positive controls (must answer "yes"): the deployer IS the writer
#     identity for networks + events in ainetops-intent (FR-019's
#     submission path).
#
# Precondition: deploy/agents/namespace-rbac.yaml applied; caller holds
# cluster-admin (for --as impersonation).
#
# Usage: deploy/agents/tests/probes/us2-denials.sh [kubectl-context]
# Exit: 0 = every denial held and every control present; 1 otherwise.

set -euo pipefail

CTX="${1:-}"
K() { if [[ -n "$CTX" ]]; then kubectl --context "$CTX" "$@"; else kubectl "$@"; fi; }

NS_AGENTS=ainetops-agents
NS_INTENT=ainetops-intent
SA_SUP="system:serviceaccount:${NS_AGENTS}:intent-supervisor"
SA_MAP="system:serviceaccount:${NS_AGENTS}:intent-mapper"
SA_UI="system:serviceaccount:${NS_AGENTS}:intent-ui"
SA_ALC="system:serviceaccount:${NS_AGENTS}:intent-allocator"
SA_DEP="system:serviceaccount:${NS_AGENTS}:intent-deployer"

fail=0
pass=0

# answer is taken from stdout: a probe passes IFF the server answers the
# exact expected word. Empty (unreachable cluster, bad impersonation) is a
# probe failure, never a pass.
can_i_expect() {
  local id=$1 expect=$2; shift 2
  local got
  got=$(K auth can-i --as="$id" "$@" 2>/dev/null) || true
  if [[ "$got" == "$expect" ]]; then
    pass=$((pass + 1))
    printf 'PASS  %-16s can-i %s  -> %s\n' "${id##*:}" "$*" "$got"
  else
    fail=$((fail + 1))
    printf 'FAIL  %-16s can-i %s  -> %q (expected %s)\n' "${id##*:}" "$*" "${got:-<empty>}" "$expect"
  fi
}

automount_expect_false() {
  local name=$1
  local got
  got=$(K -n "$NS_AGENTS" get sa "$name" -o jsonpath='{.automountServiceAccountToken}' 2>/dev/null) || true
  if [[ "$got" == "false" ]]; then
    pass=$((pass + 1))
    printf 'PASS  %-16s automountServiceAccountToken=false (no token to use)\n' "$name"
  else
    fail=$((fail + 1))
    printf 'FAIL  %-16s automountServiceAccountToken=%q (expected false)\n' "$name" "${got:-<unset>}"
  fi
}

echo "== US2 structural denials (FR-016): identity cannot express the action"

# --- identity denials -------------------------------------------------------
# The identity-less tier: supervisor, mapper, ui hold no token and have no
# cluster API grants whatsoever.
for id in "$SA_SUP" "$SA_MAP" "$SA_UI"; do
  can_i_expect "$id" no create networks -n "$NS_INTENT"
  can_i_expect "$id" no create events   -n "$NS_INTENT"
  can_i_expect "$id" no get    secrets  -n "$NS_AGENTS"
done
# The allocator is claim-only: it cannot write intent resources or events.
can_i_expect "$SA_ALC" no create networks -n "$NS_INTENT"
can_i_expect "$SA_ALC" no create events   -n "$NS_INTENT"
# The deployer is scoped: nothing outside ainetops-intent, no secrets/pods.
can_i_expect "$SA_DEP" no create networks -n "$NS_AGENTS"
can_i_expect "$SA_DEP" no create networks -n default
can_i_expect "$SA_DEP" no create secrets  -n "$NS_INTENT"
can_i_expect "$SA_DEP" no create pods     -n "$NS_INTENT"
can_i_expect "$SA_DEP" no create pods     -n "$NS_AGENTS"

# --- structural: no token at all for the identity-less SAs ------------------
automount_expect_false intent-supervisor
automount_expect_false intent-mapper
automount_expect_false intent-ui

# --- positive controls: the deployer IS the writer identity -----------------
can_i_expect "$SA_DEP" yes create networks -n "$NS_INTENT"
can_i_expect "$SA_DEP" yes create events   -n "$NS_INTENT"

echo
echo "us2-denials: ${pass} passed, ${fail} failed"
[[ "$fail" -eq 0 ]] || exit 1
