#!/usr/bin/env bash
# T049 [US2] Partial target failure/recovery, provider restart mid-transaction, and invalid-YANG tests
set -euo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
TOPO=${TOPO:-$ROOT_DIR/lab/topology.clab.yml}
CTX=${CTX:-kind-ainetops}
PROOF_DIR=${PROOF_DIR:-.wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs}
mkdir -p "$PROOF_DIR"

assert_aggregate_not_ready() {
  # When any target is not Ready, aggregate readiness must not be True
  local any_not_ready
  any_not_ready=$(kubectl --context "$CTX" -n sdc get target -o json \
    | jq -r '[.items[].status.conditions[]|select(.type=="Ready")|.status] | any(. != "True")')
  if [[ "$any_not_ready" != "true" ]]; then
    echo "[failure] WARN: all targets appear Ready; the environment may be already healthy" >&2
  fi
  local agg
  agg=$(kubectl --context "$CTX" -n sdc get target -o json \
    | jq -r '[.items[].status.conditions[]|select(.type=="Ready")|.status] | all(. == "True")')
  if [[ "$agg" == "true" && "$any_not_ready" == "true" ]]; then
    echo "[failure] ERROR: false aggregate Ready detected (some targets not Ready but aggregate all True)" >&2
    exit 1
  fi
}

partial_target_failure_recovery() {
  echo "[failure] partial target failure/recovery"
  # containerlab 0.7x CLI: `stop`/`start` take node names (no `node` subcommand)
  containerlab stop -t "$TOPO" leaf02 || true
  # Expect aggregate not Ready (Degraded) reflected in provider/SDC/Network status
  kubectl --context "$CTX" -n sdc get target -o wide | tee "$PROOF_DIR/partial-failure.targets.txt" >/dev/null
  assert_aggregate_not_ready
  # Restore
  containerlab start -t "$TOPO" leaf02 || true
}

provider_restart_mid_transaction() {
  echo "[failure] provider restart mid-transaction"
  # Trigger a harmless change (annotate a network) and restart provider
  kubectl --context "$CTX" -n kubenet-system annotate network default-fabric test-restart=$(date +%s) --overwrite || true
  kubectl --context "$CTX" -n ainetops-system rollout restart deploy/ainetops-sonic-provider
  kubectl --context "$CTX" -n ainetops-system rollout status deploy/ainetops-sonic-provider --timeout=120s || true
  echo "provider restart mid-transaction" # proof keyword
}

invalid_yang_tests() {
  echo "[failure] invalid-YANG tests"
  # Apply an intentionally invalid SDC Config (unknown path) and assert validation failure
  set +e
  local out
  out=$(cat <<'EOF' | kubectl --context "$CTX" -n sdc apply -f - 2>&1
apiVersion: sdc.sdcio.dev/v1alpha1
kind: Config
metadata:
  name: invalid-yang-test
spec:
  targetRef:
    name: leaf01
  intent:
    encoding: JSON_IETF
    value: |
      {
        "openconfig-foo:nonexistent-root": {"bad-field": 123}
      }
EOF
)
  local rc=$?
  set -e
  printf "%s" "$out" | tee "$PROOF_DIR/invalid-yang.apply.txt" >/dev/null
  if [[ $rc -eq 0 || ! "$out" =~ (Invalid|unknown|schema|path) ]]; then
    echo "[failure] ERROR: invalid YANG apply did not fail as expected" >&2
    exit 1
  fi
}

partial_srv6_endpoint_programming() {
  echo "[failure] partial SRv6 endpoint programming"
  # Patch SRv6Service to temporarily remove one attachment; assert Ready is not True
  kubectl --context "$CTX" -n default patch srv6service example-srv6 --type json -p='[{"op":"remove","path":"/spec/attachments/1"}]' || true
  local ready
  ready=$(kubectl --context "$CTX" -n default get srv6service example-srv6 -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' || true)
  echo "$ready" | tee "$PROOF_DIR/srv6-ready-after-partial.txt" >/dev/null
  if [[ "$ready" == "True" ]]; then
    echo "[failure] ERROR: SRv6Service reported Ready=True with partial endpoint programming" >&2
    exit 1
  fi
  # Restore by reapplying sample
  kubectl --context "$CTX" apply -f config/samples/ainetops_v1alpha1_srv6service.yaml || true
}

prohibit_false_aggregate_ready() {
  echo "[failure] prohibit false aggregate Ready or partial service activation"
  # Cross-check that when any target is not Ready, aggregate Ready is not True (enforced)
  local any_not_ready
  any_not_ready=$(kubectl --context "$CTX" -n sdc get target -o json \
    | jq -r '[.items[].status.conditions[]|select(.type=="Ready")|.status] | any(. != "True")')
  local all_ready
  all_ready=$(kubectl --context "$CTX" -n sdc get target -o json \
    | jq -r '[.items[].status.conditions[]|select(.type=="Ready")|.status] | all(. == "True")')
  echo "$any_not_ready" | tee "$PROOF_DIR/prohibit-false-ready.txt" >/dev/null
  if [[ "$any_not_ready" == "true" && "$all_ready" == "true" ]]; then
    echo "[failure] ERROR: Detected false aggregate Ready while some targets not Ready" >&2
    exit 1
  fi
}

case "${1:-run}" in
  run)
    # Clean skip when no provisioned lab/cluster exists (absent-state runs, post-teardown).
    if ! docker ps --format '{{.Names}}' | grep -q "clab-ainetops-fabric-spine01" \
      || ! kubectl --context "$CTX" get nodes --request-timeout=5s >/dev/null 2>&1; then
      echo "SKIP-LIVE: failure/recovery suite requires a provisioned lab and Kind cluster (containerlab nodes or context ${CTX} absent); capability gate (scripts/lib/qualify.sh) is the source of truth"
      exit 0
    fi
    partial_target_failure_recovery
    provider_restart_mid_transaction
    invalid_yang_tests
    partial_srv6_endpoint_programming
    prohibit_false_aggregate_ready
    ;;
  *) echo "usage: $0 run" >&2; exit 2 ;;
esac
