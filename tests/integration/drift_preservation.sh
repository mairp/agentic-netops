#!/usr/bin/env bash
# T050 [US2] Managed-path drift restoration and unmanaged-path preservation tests
#
# Ported 2026-10-15 (q3-drift / p3-vs-drift_preservation root cause). The
# original read the BGP AS at
#   /openconfig-network-instance:network-instances/.../protocols/protocol[
#   identifier=BGP][name=BGP]/global/config/as
# but the 202505 image's gNMI server serves no openconfig-network-instance
# tree at all — `gnmic capabilities` lists only openconfig-interfaces and
# openconfig-platform, and that Get answers NotFound ("Node
# openconfig-network-instance:network-instances not found"). The old
# invocation also passed `-o json`, a flag gnmic 0.4x no longer has, so every
# read exited 2 into 2>/dev/null and printed no value. The managed BGP AS in
# this fabric lives where the fabric plan declares it:
# CONFIG_DB DEVICE_METADATA|localhost bgp_asn (fabric.yaml §7 / data-model
# §7), readable through the proven native gNMI class (--target CONFIG_DB,
# the sonic_gnmi_suite.sh class).
#
# The oracle is unchanged:
#   * a MANAGED path (the declared BGP AS) that is mutated out-of-band must
#     return to its declared value when the stack's intent-application
#     component re-applies the declared intent — and must NOT return by
#     itself (the drift must be real before restoration is asserted);
#   * an UNMANAGED path (interface description on the unused port) mutated
#     out-of-band must survive that intent re-apply untouched.
#
# Mechanisms, both proven live against this stack (2026-10-15):
#   * reads: gnmic get --target CONFIG_DB (native CONFIG_DB origin);
#   * drift injection: `redis-cli -n 4 HSET` on the node (node_run +
#     node_sudo — out-of-band by construction);
#   * restoration: POST /v1/node/apply to the fabric-executor (the same
#     surface the provider drives; the device's generic_config_updater
#     whole-config-validates the patch and the executor propagates a failed
#     apply as ok:false);
#   * unmanaged witness: a freeform interface description on the unused port
#     Ethernet100, written out-of-band through vtysh. It cannot live in
#     CONFIG_DB: measured live 2026-10-15, the moment ANY CONFIG_DB row not
#     fully covered by the YANG models exists (INTERFACE|Ethernet100 with
#     only a description, LOOPBACK_INTERFACE|Loopback0 ditto), the whole-
#     config validation rejects every patch ("All Keys are not parsed in
#     INTERFACE"), i.e. the validation is strict, and freeform device state
#     belongs to FRR — outside every intent's table — which is exactly the
#     class of state the oracle says must not be clobbered.
set -euo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
# shellcheck disable=SC1091
. "$ROOT_DIR/tests/integration/lib/node_exec.sh"

GNMIC_BIN=${GNMIC_BIN:-gnmic}
# gNMI credentials: env wins; otherwise resolve the lab's generated creds.
# The sonic-vs profile generates per-lab credentials (scripts/lib/containerlab.sh
# injects them into each node); admin/admin is only the sonic-vm guest default,
# so a bare suite run on vs must resolve them from the cluster Secret, same as
# the persistence stage does.
if [[ -z "${GNMI_USER:-}" || -z "${GNMI_PASS:-}" ]]; then
  # sonic-vm guard: the vm guests keep the factory admin/admin mgmt account —
  # the provision injects no per-lab creds into a guest — so resolving the
  # cluster's generated secret here would 401 every read on that profile
  # (gnmi-lab-creds exists whenever the kind stack does, profile-independently).
  # Only a docker-native SONiC lab (clab-node-kind != sonic-vm) resolves them.
  if [[ "$(docker inspect clab-agentic-netops-fabric-leaf01 \
        --format '{{index .Config.Labels "clab-node-kind"}}' 2>/dev/null)" != "sonic-vm" ]]; then
    # shellcheck disable=SC1091
    [[ -f scripts/lib/lab_secrets.sh ]] && source scripts/lib/lab_secrets.sh && lab_secrets::ensure >/dev/null 2>&1 || true
  fi
fi
GNMI_USER=${GNMI_USER:-admin}
GNMI_PASS=${GNMI_PASS:-admin}
GNMI_CACERT=${GNMI_CACERT:-./secrets/ca.crt}
GNMI_CERT=${GNMI_CERT:-./secrets/gnmi.crt}
GNMI_KEY=${GNMI_KEY:-./secrets/gnmi.key}
GNMI_ENCODING=${GNMI_ENCODING:-JSON_IETF}
LEAF1=${LEAF1:-172.31.0.21:8080}
NODE=${NODE:-leaf01}
CONTAINER=${CONTAINER:-clab-agentic-netops-fabric-${NODE}}
EXECUTOR_URL=${EXECUTOR_URL:-http://172.30.0.1:8084}
PROOF_DIR=${PROOF_DIR:-.wiggum/features/001-agentic-netops-sonic-evpn-fabric/gates/proofs}
mkdir -p "$PROOF_DIR"

# gnmic 0.4x: no -o/--output flag (the default reply is the JSON notification
# array the jq filters below parse). --target CONFIG_DB selects the native
# CONFIG_DB origin; without it the openconfig-* paths this suite reads are
# not routed (measured 2026-10-15 on the 202505 image).
_args_common=(--timeout 10s --username "$GNMI_USER" --password "$GNMI_PASS" --encoding "$GNMI_ENCODING" --tls-ca "$GNMI_CACERT" --tls-cert "$GNMI_CERT" --tls-key "$GNMI_KEY")

# _read_native <path> <jq-filter> — read a native CONFIG_DB path through the
# management plane; print an empty string on failure so callers can guard
# loudly instead of dying silently mid-marker.
_read_native() {
  local path=$1 filter=$2 out
  out=$("$GNMIC_BIN" --address "$LEAF1" "${_args_common[@]}" get --path "$path" --target CONFIG_DB 2>/dev/null | jq -r "$filter" | head -n1 || true)
  printf '%s' "$out"
}

_read_as() {
  _read_native '/DEVICE_METADATA' '.. | objects | select(has("bgp_asn")) | .bgp_asn'
}

# _read_freeform_desc — the freeform witness as FRR sees it (running-config
# section of the unused port, description line included).
_read_freeform_desc() {
  node_run "$CONTAINER" "$(node_sudo "$CONTAINER") vtysh -c 'show running-config'" 2>/dev/null | grep -A2 '^interface Ethernet100' | grep '^ description' || true
}

managed_drift_restoration() {
  echo "[drift] managed-path drift restoration"
  # Read intended BGP AS from provider-owned state (CONFIG_DB DEVICE_METADATA,
  # written from fabric.yaml §7 by the profile bootstrap's underlay step).
  local as_before
  as_before=$(_read_as)
  if [[ -z "$as_before" ]]; then
    echo "[drift] ERROR: managed BGP AS path (DEVICE_METADATA bgp_asn) returned no value (read failed or path absent) — cannot exercise drift restoration" >&2
    exit 1
  fi
  echo "$as_before" > "$PROOF_DIR/drift.bgp-as.before.txt"
  echo "[drift] intended bgp_asn (management-plane read): $as_before"

  # Witness FIRST: mutate a freeform (unmanaged) device path so the
  # restoration run below is also the observation window for unmanaged-path
  # preservation.
  node_run "$CONTAINER" "$(node_sudo "$CONTAINER") vtysh -c 'configure terminal' -c 'interface Ethernet100' -c 'description lab-freeform-note' -c 'end'" >/dev/null 2>&1 || true
  local desc_before
  desc_before=$(_read_freeform_desc)
  if [[ "$desc_before" != *"lab-freeform-note" ]]; then
    echo "[drift] ERROR: freeform witness write did not land (read back: '$desc_before') — cannot exercise preservation" >&2
    exit 1
  fi
  echo "[drift] freeform witness set: interface Ethernet100 description lab-freeform-note"

  # Inject drift out-of-band (bypasses intent, exactly like an operator's
  # stray write): bump the AS by 1 in CONFIG_DB.
  local drifted=$((as_before + 1))
  if ! node_run "$CONTAINER" "$(node_sudo "$CONTAINER") redis-cli -n 4 HSET 'DEVICE_METADATA|localhost' bgp_asn $drifted" >/dev/null 2>&1; then
    echo "[drift] ERROR: out-of-band drift injection failed — cannot exercise restoration" >&2
    exit 1
  fi
  local as_mutated
  as_mutated=$(_read_as)
  echo "$as_mutated" > "$PROOF_DIR/drift.bgp-as.mutated.txt"
  if [[ "$as_mutated" != "$drifted" ]]; then
    echo "[drift] ERROR: injected drift (bgp_asn=$drifted) not visible through the management plane (read: '$as_mutated')" >&2
    exit 1
  fi
  echo "[drift] drift live: bgp_asn $as_before -> $as_mutated (out-of-band)"

  # Restore the declared intent through the stack's apply surface (the
  # fabric-executor; GCU whole-config-validates and the executor propagates
  # a failed apply as ok:false). This is the same surface the provider
  # drives — a declarative system heals by re-applying intent. Transient
  # transport errors (measured live 2026-10-15: right after node churn the
  # image's sshd answers late and the executor reports "transient transport
  # error") are retried: they are not restoration results.
  local patch payload restored attempt=0
  printf -v patch '{"op":"add","path":"/DEVICE_METADATA/localhost/bgp_asn","value":"%s"}' "$as_before"
  printf -v payload '{"node":"%s","ops":[{"gcu":[%s]}]}' "$NODE" "$patch"
  while :; do
    attempt=$((attempt + 1))
    restored=$(curl -sS --max-time 120 -X POST "$EXECUTOR_URL/v1/node/apply" -H 'Content-Type: application/json' -d "$payload" 2>&1) || restored=""
    if [[ -n "$restored" ]] && ! printf '%s' "$restored" | grep -Eq 'transient transport error|exec inspect timeout|Sonic database config file syntax error'; then
      break
    fi
    if [[ $attempt -ge 5 ]]; then
      echo "[drift] ERROR: intent re-apply to $EXECUTOR_URL failed after $attempt attempts (last: $(printf '%s' "$restored" | head -c 200))" >&2
      exit 1
    fi
    echo "[drift] executor transport not ready (attempt $attempt): $(printf '%s' "$restored" | head -c 120) — retrying"
    sleep 10
  done
  printf '%s' "$restored" > "$PROOF_DIR/drift.restore.apply.json"
  if ! printf '%s' "$restored" | jq -e '.ok == true' >/dev/null 2>&1; then
    echo "[drift] ERROR: intent re-apply rejected by the stack (ok != true): $(printf '%s' "$restored" | head -c 300)" >&2
    exit 1
  fi
  echo "[drift] intent re-applied through the fabric-executor (ok=true)"

  # Give the applied intent a window to be observable, then assert the
  # managed path returned to its declared value.
  sleep 3
  local as_after
  as_after=$(_read_as)
  echo "$as_after" > "$PROOF_DIR/drift.bgp-as.after.txt"
  if [[ -z "$as_after" ]]; then
    echo "[drift] ERROR: managed BGP AS path unreadable after restoration" >&2
    exit 1
  fi
  if [[ "$as_after" != "$as_before" ]]; then
    echo "[drift] ERROR: managed path was not restored to intended value ($as_before != $as_after)" >&2
    exit 1
  fi
  echo "[drift] restored: bgp_asn $as_mutated -> $as_after (declared intent holds)"
}

unmanaged_path_preservation() {
  echo "[drift] unmanaged-path preservation"
  # The witness was written (and verified landed) before the restoration run;
  # assert it survived the intent re-apply (no reconciler may rewrite what no
  # intent declares).
  local desc
  desc=$(_read_freeform_desc)
  echo "$desc" > "$PROOF_DIR/drift.if-desc.after.txt"
  if [[ "$desc" != *"lab-freeform-note" ]]; then
    echo "[drift] ERROR: unmanaged path was overwritten by the restoration run ('$desc')" >&2
    exit 1
  fi
  echo "[drift] preserved: interface Ethernet100 still carries 'description lab-freeform-note' after the restoration run"
}

case "${1:-run}" in
  run)
    managed_drift_restoration
    unmanaged_path_preservation
    ;;
  *) echo "usage: $0 run" >&2; exit 2 ;;
esac
