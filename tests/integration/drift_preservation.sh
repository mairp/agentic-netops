#!/usr/bin/env bash
# Managed-path drift restoration and unmanaged-path preservation on the SR Linux
# fabric (FR-006, FR-008).
#
# Two properties, both read and written over gNMI against the native models:
#
#   managed   — an object the provider rendered is restored by the next resync
#               after it is mutated on the node.
#   unmanaged — an object no Network declares is NOT touched by that resync.
#
# This suite needs a network-instance that a Network actually rendered. It will
# NOT invent one: the bootstrap tenants (vlan100, VrfBlue) come from the
# startup-config and no controller owns them, so mutating those would test
# nothing and "pass" only because nothing was expected to happen. Pass the
# rendered network-instance in DRIFT_NI (Phase 5 T050 does exactly that with the
# vlan it just provisioned); without it the suite skips with a printed reason.
set -euo pipefail

GNMIC_BIN=${GNMIC_BIN:-gnmic}
GNMI_USER=${GNMI_USER:-admin}
GNMI_PASS=${GNMI_PASS:-admin}
GNMI_CACERT=${GNMI_CACERT:-./secrets/ca.crt}
GNMI_ENCODING=${GNMI_ENCODING:-json_ietf}
LEAF1=${LEAF1:-172.31.0.21:57400}
PROOF_DIR=${PROOF_DIR:-.wiggum/features/001-agentic-netops-srlinux-evpn-fabric/gates/proofs}
mkdir -p "$PROOF_DIR"

# A network-instance rendered by a Network on LEAF1 (e.g. vlan-131). Required.
DRIFT_NI=${DRIFT_NI:-}
# The controller's resync interval is 5 minutes; allow one interval plus slack.
RESYNC_WAIT=${RESYNC_WAIT:-360}
POLL=${POLL:-15}
# An interface no construct renders a description onto.
UNMANAGED_IF=${UNMANAGED_IF:-ethernet-1/4}
UNMANAGED_NOTE="lab-freeform-note-$(date +%s)"

_args_common=(--timeout 10s --username "$GNMI_USER" --password "$GNMI_PASS" --encoding "$GNMI_ENCODING" --tls-ca "$GNMI_CACERT")

die() { echo "[drift] ERROR: $*" >&2; exit 1; }

_get_value() {
  "$GNMIC_BIN" --address "$LEAF1" "${_args_common[@]}" get --path "$1" 2>/dev/null \
    | jq -r '[.[].updates[].values] | map(to_entries[].value) | .[0] // empty' 2>/dev/null | head -n1
}

_set_value() {
  "$GNMIC_BIN" --address "$LEAF1" "${_args_common[@]}" set --update-path "$1" --update-value "$2" >/dev/null 2>&1
}

_delete_path() {
  "$GNMIC_BIN" --address "$LEAF1" "${_args_common[@]}" set --delete "$1" >/dev/null 2>&1
}

managed_drift_restoration() {
  echo "[drift] managed-path drift restoration on network-instance ${DRIFT_NI}"
  local path="/network-instance[name=${DRIFT_NI}]/admin-state"
  local before after i
  before=$(_get_value "$path")
  [[ -n "$before" ]] || die "cannot read ${path}; the rendered network-instance ${DRIFT_NI} is not on ${LEAF1}"
  echo "$before" > "$PROOF_DIR/drift.ni-admin-state.before.txt"
  [[ "$before" == "enable" ]] || die "expected the rendered network-instance to be admin-state enable, found '${before}'"

  # Mutate the managed object on the node. This is a deliberate, scoped write
  # outside the executor, and it is the only one this suite makes.
  _set_value "$path" "disable" || die "could not mutate ${path}"
  after=$(_get_value "$path")
  [[ "$after" == "disable" ]] || die "the mutation did not take effect; nothing was drifted, so restoration cannot be observed"

  for ((i=0; i<RESYNC_WAIT; i+=POLL)); do
    after=$(_get_value "$path")
    if [[ "$after" == "$before" ]]; then
      echo "$after" > "$PROOF_DIR/drift.ni-admin-state.after.txt"
      echo "[drift] assertion passed: managed path restored to '${before}' within ${i}s"
      return 0
    fi
    sleep "$POLL"
  done
  echo "$after" > "$PROOF_DIR/drift.ni-admin-state.after.txt"
  die "managed path was not restored within ${RESYNC_WAIT}s (still '${after}', expected '${before}')"
}

unmanaged_path_preservation() {
  echo "[drift] unmanaged-path preservation on ${UNMANAGED_IF}"
  local path="/interface[name=${UNMANAGED_IF}]/description"
  local desc i
  _set_value "$path" "$UNMANAGED_NOTE" || die "could not write the unmanaged witness at ${path}"
  # Watch across a full resync interval: an immediate re-read would pass before
  # the reconciler ever ran and prove nothing.
  for ((i=0; i<RESYNC_WAIT; i+=POLL)); do
    desc=$(_get_value "$path")
    if [[ "$desc" != "$UNMANAGED_NOTE" ]]; then
      echo "${desc}" > "$PROOF_DIR/drift.if-desc.after.txt"
      _delete_path "$path" || true
      die "unmanaged path was overwritten by the reconciler after ${i}s (found '${desc}')"
    fi
    sleep "$POLL"
  done
  echo "$desc" > "$PROOF_DIR/drift.if-desc.after.txt"
  echo "[drift] assertion passed: unmanaged path survived a full resync interval"
  _delete_path "$path" || true
}

case "${1:-run}" in
  run)
    if [[ -z "$DRIFT_NI" ]]; then
      echo "SKIP-LIVE: drift suite requires DRIFT_NI (a network-instance rendered by a Network on ${LEAF1}); the bootstrap tenants are startup-config, not controller-managed, so drifting them would prove nothing"
      exit 0
    fi
    if ! command -v "$GNMIC_BIN" >/dev/null 2>&1 || [[ ! -s "$GNMI_CACERT" ]]; then
      echo "SKIP-LIVE: drift suite requires gnmic and ./secrets/ca.crt from a provisioned lab"
      exit 0
    fi
    managed_drift_restoration
    unmanaged_path_preservation
    ;;
  *) echo "usage: $0 run" >&2; exit 2 ;;
esac
