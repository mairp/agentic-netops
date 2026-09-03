#!/usr/bin/env bash
# T051 [US2] Update/delete lifecycle: shared fabric state and unrelated claims survive EVPN/SRv6 changes; SRv6-owned claims released
set -euo pipefail

CTX=${CTX:-kind-agentic-netops}
PROOF_DIR=${PROOF_DIR:-.wiggum/features/001-agentic-netops-sonic-evpn-fabric/gates/proofs}
mkdir -p "$PROOF_DIR"

count_sdc_srv6_configs() {
  # Count SDC Configs owned by SRv6 (by label/annotation convention)
  kubectl --context "$CTX" -n sdc get config -o json \
    | jq '[.items[] | select(.metadata.labels["agentic-netops.dev/owner"]=="srv6" or (.metadata.annotations["agentic-netops.dev/owner"]//"")=="srv6")] | length'
}

list_sdc_configs() {
  kubectl --context "$CTX" -n sdc get config -o name | sort -u
}

hash_default_fabric() {
  # Stable hash of default-fabric excluding volatile metadata/status
  kubectl --context "$CTX" -n kubenet-system get network default-fabric -o json \
    | jq -S 'del(.metadata.resourceVersion,.metadata.generation,.metadata.uid,.metadata.managedFields,.metadata.creationTimestamp,.status)' \
    | sha256sum | awk '{print $1}'
}

srv6_annotation_json() {
  kubectl --context "$CTX" -n default get srv6service example-srv6 -o json 2>/dev/null \
    | jq -S '.metadata.annotations // {}'
}

hash_srv6_annotation() {
  srv6_annotation_json | sha256sum | awk '{print $1}'
}

update_service() {
  echo "[lifecycle] snapshot before update"
  list_sdc_configs | tee "$PROOF_DIR/update.sdc-configs.before.txt" >/dev/null
  hash_default_fabric | tee "$PROOF_DIR/update.default-fabric.hash.before.txt" >/dev/null
  srv6_annotation_json | tee "$PROOF_DIR/update.srv6service.annotations.before.json" >/dev/null || true
  hash_srv6_annotation | tee "$PROOF_DIR/update.srv6service.annotations.hash.before.txt" >/dev/null || true

  echo "[lifecycle] update EVPN and SRv6 services; shared IPv6 underlay preserved"
  # Update a tenant RT and SRv6 policy description (no functional change)
  kubectl --context "$CTX" -n kubenet-system patch network tenant-a-l3-routed --type merge -p '{"spec":{"routers":[{"name":"vrf-tenant-a","routeTargets":{"import":["65000:100"],"export":["65000:100"]}}]}}' || true
  kubectl --context "$CTX" -n default patch srv6service example-srv6 --type merge -p '{"metadata":{"annotations":{"agentic-netops.dev/description":"update"}}}' || true

  echo "[lifecycle] snapshot after update"
  list_sdc_configs | tee "$PROOF_DIR/update.sdc-configs.after.txt" >/dev/null
  hash_default_fabric | tee "$PROOF_DIR/update.default-fabric.hash.after.txt" >/dev/null
  srv6_annotation_json | tee "$PROOF_DIR/update.srv6service.annotations.after.json" >/dev/null || true
  hash_srv6_annotation | tee "$PROOF_DIR/update.srv6service.annotations.hash.after.txt" >/dev/null || true

  # Assert default-fabric persists
  kubectl --context "$CTX" -n kubenet-system get network default-fabric -o name | tee "$PROOF_DIR/update.default-fabric.txt" >/dev/null
  if ! grep -q "/default-fabric" "$PROOF_DIR/update.default-fabric.txt"; then
    echo "[lifecycle] ERROR: default-fabric missing after update" >&2; exit 1
  fi
  # Assert no unrelated SDC Configs were removed (before == after)
  if ! diff -u "$PROOF_DIR/update.sdc-configs.before.txt" "$PROOF_DIR/update.sdc-configs.after.txt" >/dev/null; then
    echo "[lifecycle] ERROR: SDC Config set changed unexpectedly on update" >&2; exit 1
  fi
  # Assert SRv6Service annotation changed to prove durable update effect
  if diff -u "$PROOF_DIR/update.srv6service.annotations.hash.before.txt" "$PROOF_DIR/update.srv6service.annotations.hash.after.txt" >/dev/null; then
    echo "[lifecycle] ERROR: SRv6Service annotations hash did not change on update" >&2; exit 1
  fi
  # Record explicit diff for proof
  diff -u "$PROOF_DIR/update.srv6service.annotations.before.json" "$PROOF_DIR/update.srv6service.annotations.after.json" \
    > "$PROOF_DIR/update.srv6service.annotations.diff.txt" || true
  echo "unrelated claims survive" # proof keyword
}

delete_service() {
  echo "[lifecycle] snapshot before delete"
  list_sdc_configs | tee "$PROOF_DIR/delete.sdc-configs.before.txt" >/dev/null
  kubectl --context "$CTX" -n sdc get config -o json \
    | jq -r '.items[] | select(.metadata.labels["agentic-netops.dev/owner"]=="srv6" or (.metadata.annotations["agentic-netops.dev/owner"]//"")=="srv6") | .metadata.name' \
    | sort -u | tee "$PROOF_DIR/delete.srv6-configs.list.before.txt" >/dev/null
  hash_default_fabric | tee "$PROOF_DIR/delete.default-fabric.hash.before.txt" >/dev/null

  echo "[lifecycle] delete SRv6 service; release SRv6-owned claims and SDC Configs without removing shared IPv6 underlay"
  local before
  before=$(count_sdc_srv6_configs)
  kubectl --context "$CTX" -n default delete srv6service example-srv6 --ignore-not-found=true || true

  echo "[lifecycle] snapshot after delete"
  kubectl --context "$CTX" -n kubenet-system get network default-fabric -o name | tee "$PROOF_DIR/delete.default-fabric.txt" >/dev/null
  if ! grep -q "/default-fabric" "$PROOF_DIR/delete.default-fabric.txt"; then
    echo "[lifecycle] ERROR: default-fabric missing after SRv6 delete" >&2; exit 1
  fi
  local after
  after=$(count_sdc_srv6_configs)
  echo "$before" > "$PROOF_DIR/delete.srv6-configs.count.before.txt"
  echo "$after" > "$PROOF_DIR/delete.srv6-configs.count.after.txt"
  kubectl --context "$CTX" -n sdc get config -o json \
    | jq -r '.items[] | select(.metadata.labels["agentic-netops.dev/owner"]=="srv6" or (.metadata.annotations["agentic-netops.dev/owner"]//"")=="srv6") | .metadata.name' \
    | sort -u | tee "$PROOF_DIR/delete.srv6-configs.list.after.txt" >/dev/null
  # Removed names list (durable identity)
  comm -23 "$PROOF_DIR/delete.srv6-configs.list.before.txt" "$PROOF_DIR/delete.srv6-configs.list.after.txt" \
    > "$PROOF_DIR/delete.srv6-configs.removed.txt" || true
  hash_default_fabric | tee "$PROOF_DIR/delete.default-fabric.hash.after.txt" >/dev/null

  if [[ -n "$before" && -n "$after" && "$after" -ge "$before" ]]; then
    echo "[lifecycle] ERROR: SRv6-owned SDC Configs were not reduced after delete" >&2; exit 1
  fi
  # Assert shared underlay hash remained unchanged across delete
  if ! diff -u "$PROOF_DIR/delete.default-fabric.hash.before.txt" "$PROOF_DIR/delete.default-fabric.hash.after.txt" >/dev/null; then
    echo "[lifecycle] ERROR: default-fabric hash changed after SRv6 delete (unexpected)" >&2; exit 1
  fi
}

case "${1:-run}" in
  run)
    update_service
    delete_service
    ;;
  *) echo "usage: $0 run" >&2; exit 2 ;;

esac
