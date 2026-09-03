#!/usr/bin/env bash
# T055 / SC-005: assert EVERY denial listed in
# specs/002-agntcy-intent-tier/contracts/kubernetes-objects.md ("Identity
# contract" table) for BOTH cluster API identities of the tier:
#   system:serviceaccount:ainetops-agents:intent-deployer
#   system:serviceaccount:ainetops-agents:intent-allocator
#
# Each row of the contract table is one (identity, verb, resource, scope) check;
# every one must answer "no". The FR-016 guardrail is structural — the identity
# cannot express the action — so "no" is the assertion, not "the agent declines".
#
# Precondition: the RBAC from deploy/agents/namespace-rbac.yaml is applied to the
# target cluster (kubectl apply -f deploy/agents/namespace-rbac.yaml), the
# feature-001 resource types the tier writes are served (deploy/kubenet/crds/
# kubenet-crds.yaml for networks.network.kubenet.dev; srv6services.ainetops.io
# ships with the 001 control plane), and the caller holds cluster-admin
# (needed for --as impersonation; the probes assert on the TARGET identities,
# not on the caller).
#
# Usage: deploy/agents/tests/probes/rbac-denials.sh [kubectl-context]
# Exit: 0 = every denial held; 1 = at least one identity could do something it
#       must not (print the exact can-i line that answered "yes").

set -euo pipefail

CTX="${1:-}"
K() { if [[ -n "$CTX" ]]; then kubectl --context "$CTX" "$@"; else kubectl "$@"; fi; }

NS_AGENTS=ainetops-agents
IDENTITIES=(
  "system:serviceaccount:${NS_AGENTS}:intent-deployer"
  "system:serviceaccount:${NS_AGENTS}:intent-allocator"
)

fail=0
pass=0

# can_i_must_be_no <identity> <can-i args...>
# NOTE: `kubectl auth can-i` exits 1 when it answers "no" (that is the
# expected denial, not a probe error), so the answer is taken from stdout:
# the assertion passes IFF the server answers exactly "no". An empty answer
# (cluster unreachable, bad impersonation) is a probe failure, never a pass.
can_i_must_be_no() {
  local id=$1; shift
  local got
  got=$(K auth can-i --as="$id" "$@" 2>/dev/null) || true
  if [[ "$got" == "no" ]]; then
    pass=$((pass + 1))
    printf 'PASS  %-55s can-i %s  -> no\n' "${id##*:}" "$*"
  else
    fail=$((fail + 1))
    printf 'FAIL  %-55s can-i %s  -> %s (expected: no)\n' "${id##*:}" "$*" "${got:-<no answer>}"
  fi
}

for id in "${IDENTITIES[@]}"; do
  # --- contract table, verbatim (contracts/kubernetes-objects.md) -----------
  # no Role grants secrets anywhere
  can_i_must_be_no "$id" get secrets -n ainetops-system
  # intent-writer is namespaced to ainetops-intent, not kubenet-system
  can_i_must_be_no "$id" update networks -n kubenet-system
  # no rule mentions the SDC groups
  can_i_must_be_no "$id" create configs.config.sdcio.dev -A
  can_i_must_be_no "$id" get targets.inv.sdcio.dev -A
  # no rule mentions pods
  can_i_must_be_no "$id" create pods/exec -A
  # update/patch deliberately withheld on claims (Decision 11)
  can_i_must_be_no "$id" update claims -n kuid-system
  # --- the same denials for the served KUID claim groups (T032: the pinned
  # v0.0.13 serves ipam/as/genid .be.kuid.dev, not id.kuid.dev; the tier role
  # grants the same verb set on those groups — create/delete only, NO update)
  can_i_must_be_no "$id" update ipclaims -n kuid-system
  can_i_must_be_no "$id" update genidclaims -n kuid-system
  can_i_must_be_no "$id" update asclaims -n kuid-system
  # --- the tier must not read other namespaces' intent or the control plane
  can_i_must_be_no "$id" get networks -n ainetops-agents
  can_i_must_be_no "$id" get secrets -n ainetops-agents
  # --- cluster-scope writes are impossible for both identities
  can_i_must_be_no "$id" create namespaces
  can_i_must_be_no "$id" create clusterroles
done

# --- positive sanity checks: the guardrail is scoped, not total --------------
# intent-deployer MAY write service intent in ainetops-intent (otherwise the
# tier cannot do its job); intent-allocator MAY create/delete claims.
deployer_may() {
  local got
  got=$(K auth can-i --as="system:serviceaccount:${NS_AGENTS}:intent-deployer" "$@" 2>/dev/null) || true
  if [[ "$got" == "yes" ]]; then
    pass=$((pass + 1)); printf 'PASS  intent-deployer can-i %s  -> yes\n' "$*"
  else
    fail=$((fail + 1)); printf 'FAIL  intent-deployer can-i %s  -> %s (expected: yes)\n' "$*" "${got:-<no answer>}"
  fi
}
allocator_may() {
  local got
  got=$(K auth can-i --as="system:serviceaccount:${NS_AGENTS}:intent-allocator" "$@" 2>/dev/null) || true
  if [[ "$got" == "yes" ]]; then
    pass=$((pass + 1)); printf 'PASS  intent-allocator can-i %s  -> yes\n' "$*"
  else
    fail=$((fail + 1)); printf 'FAIL  intent-allocator can-i %s  -> %s (expected: yes)\n' "$*" "${got:-<no answer>}"
  fi
}
deployer_may create networks.network.kubenet.dev -n ainetops-intent
deployer_may create srv6services.ainetops.io -n ainetops-intent
deployer_may create events -n ainetops-intent
allocator_may create claims -n kuid-system
allocator_may delete claims -n kuid-system

echo
echo "rbac-denials: ${pass} assertions passed, ${fail} failed"
if [[ "$fail" -gt 0 ]]; then
  echo "SC-005 DENIED: the identity contract is violated — see FAIL lines above."
  exit 1
fi
echo "SC-005 RBAC half: every contract denial held for both identities."
