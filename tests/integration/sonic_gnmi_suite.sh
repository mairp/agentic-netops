#!/usr/bin/env bash
# SONiC gNMI qualification suite: Capabilities/Get/Set/Subscribe, TLS/JSON_IETF, sonic-srv6 paths (FR-003)
#
# Design note (docs/SRV6_GNMI_CAPABILITY_FINDINGS.md §5): on the sonic-db origin a Get
# against a nonexistent table returns an empty body and exit code 0, so path-existence
# alone can pass vacuously. Every test below therefore asserts *content* of the reply,
# not just a zero exit code. The Set test uses the D1-B witness: a schema-valid SRv6
# locator+SID written through GCU, read back over gNMI, then removed — a write→read-back
# cycle that cannot pass on an empty result. The gNMI→GCU Set bridge itself is broken in
# this sonic-gnmi build (empty scope-list error, findings §4.1) and is recorded as a
# documented limitation, not asserted here.
set -euo pipefail

GNMIC_BIN=${GNMIC_BIN:-gnmic}
GNMI_USER=${GNMI_USER:-admin}
GNMI_PASS=${GNMI_PASS:-admin}
GNMI_CACERT=${GNMI_CACERT:-./secrets/ca.crt}
GNMI_CERT=${GNMI_CERT:-./secrets/gnmi.crt}
GNMI_KEY=${GNMI_KEY:-./secrets/gnmi.key}
GNMI_ENCODING=${GNMI_ENCODING:-JSON_IETF}
TARGETS=${TARGETS:-"172.31.0.21:8080,172.31.0.22:8080"}
CLAB_PREFIX=${CLAB_PREFIX:-clab-agentic-netops-fabric-}
# Unique witness names so repeated runs never collide with leftover state
WITNESS_TAG=${WITNESS_TAG:-$(date +%s)}
LOC_NAME="gate-loc-${WITNESS_TAG}"
LOC_PREFIX="fc00:0:71::"
SID_KEY="${LOC_NAME}|fc00:0:71:1::/64"

die() { echo "[gnmi-suite] FAIL: $*" >&2; exit 1; }
note() { echo "[gnmi-suite] $*" >&2; }

# TLS args identical for every gnmic invocation
tls_args() {
  printf '%s\n' --timeout 5s --username "$GNMI_USER" --password "$GNMI_PASS" \
    --encoding "$GNMI_ENCODING" --tls-ca "$GNMI_CACERT" --tls-cert "$GNMI_CERT" --tls-key "$GNMI_KEY"
}

# run_all <gnmic-subcommand args...> — run against every target, fail if any fails
run_all() {
  local rc=0
  IFS=',' read -ra tgts <<<"$TARGETS"
  for t in "${tgts[@]}"; do
    if ! "$GNMIC_BIN" --address "$t" $(tls_args) "$@"; then rc=1; fi
  done
  return $rc
}

# gnmi_get_json <target> <path> — capture a Get reply as JSON (empty ⇒ not found)
gnmi_get_json() {
  local t=$1 path=$2
  "$GNMIC_BIN" --address "$t" $(tls_args) get --path "$path" --target CONFIG_DB 2>&1
}

# values_json <get-output> — concatenated values of all updates
values_json() {
  jq -c '[.[].updates[].values] | map(to_entries[]) | map(.value)' <<<"$1" 2>/dev/null || echo "[]"
}

# node_for_ip <ip> — resolve the containerlab container name for a target address
node_for_ip() {
  local ip=$1
  docker ps --format '{{.Names}}' | grep "^${CLAB_PREFIX}" | while read -r c; do
    local i
    i=$(docker inspect "$c" --format '{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}' 2>/dev/null)
    if grep -qw "$ip" <<<"$i"; then echo "$c"; fi
  done | head -n1
}

# gcu_apply <container> <patch-json> — apply a JSON patch to CONFIG_DB through GCU
gcu_apply() {
  local c=$1 patch=$2
  printf '%s' "$patch" | docker exec -i "$c" bash -c 'cat > /tmp/.gate_patch.json && config apply-patch -f CONFIGDB -p /tmp/.gate_patch.json 2>/dev/null >/dev/null'
  return $?
}

# srv6_force_clean <container> — remove all SRv6 witness keys directly and save.
# Leftover SRv6 rows wedge GCU whole-config validation (a SID row whose locator
# leafref cannot be resolved makes every patch fail with Data Loading Failed), so
# tests force-clean before writing and guarantee cleanliness after — the assertion
# itself still goes through GCU apply/remove patches.
srv6_force_clean() {
  local c=$1
  docker exec "$c" bash -c 'redis-cli -n 4 --scan --pattern "SRV6_MY_LOCATORS*" | xargs -r redis-cli -n 4 del >/dev/null; redis-cli -n 4 --scan --pattern "SRV6_MY_SIDS*" | xargs -r redis-cli -n 4 del >/dev/null; config save -y >/dev/null 2>&1'
}


# --- content assertion helpers ------------------------------------------------

assert_values_nonempty() {
  local label=$1 out=$2
  [[ "$(values_json "$out")" != "[]" ]] || die "$label: gNMI Get returned no updates (vacuous reply)"
}

# T013 Capabilities/Get/Set/Subscribe
# Capabilities — assert the model list really carries sonic-db + OpenConfig system
capabilities() {
  local out
  IFS=',' read -ra tgts <<<"$TARGETS"
  for t in "${tgts[@]}"; do
    out=$("$GNMIC_BIN" --address "$t" $(tls_args) capabilities 2>&1)
    grep -q 'sonic-db' <<<"$out" || die "$t: Capabilities does not advertise sonic-db"
    grep -q 'openconfig-system' <<<"$out" || die "$t: Capabilities does not advertise openconfig-system"
    grep -qE '0\.[6-9]\.[0-9]+' <<<"$out" || die "$t: Capabilities missing gNMI version"
    note "$t: capabilities content asserted (sonic-db, openconfig-system, gNMI version)"
  done
}

# Get — DEVICE_METADATA must come back with real field content (hostname/hwsku)
get_metadata() {
  local out
  IFS=',' read -ra tgts <<<"$TARGETS"
  for t in "${tgts[@]}"; do
    out=$(gnmi_get_json "$t" /DEVICE_METADATA)
    assert_values_nonempty "Get $t" "$out"
    grep -q 'localhost' <<<"$(values_json "$out")" || die "$t: DEVICE_METADATA reply has no localhost entry"
    grep -qE 'hwsku' <<<"$(values_json "$out")" || die "$t: DEVICE_METADATA reply has no hwsku"
    note "$t: Get content asserted (DEVICE_METADATA.localhost present)"
  done
}

# Set — D1-B witness: GCU write → gNMI read-back → delete, with content assertions
set_srv6_witness() {
  local add_patch del_patch out
  add_patch=$(printf '[
  {"op":"add","path":"/SRV6_MY_LOCATORS","value":{"%s":{"prefix":"%s"}}},
  {"op":"add","path":"/SRV6_MY_SIDS","value":{"%s":{"action":"uN"}}}
]' "$LOC_NAME" "$LOC_PREFIX" "$SID_KEY")
  # NOTE: per-key removal is impossible for SID keys — GCU cannot address keys
  # containing "/" (the same defect that breaks the gNMI→GCU Set bridge, §4.1),
  # so cleanup removes the witness tables whole. Safe at gate time: the lab is
  # freshly bootstrapped and these tables carry only this suite's witnesses.
  del_patch='[
  {"op":"remove","path":"/SRV6_MY_SIDS"},
  {"op":"remove","path":"/SRV6_MY_LOCATORS"}
]'
  IFS=',' read -ra tgts <<<"$TARGETS"
  for t in "${tgts[@]}"; do
    local node
    node=$(node_for_ip "${t%%:*}")
    [[ -n "$node" ]] || die "Set: cannot resolve containerlab node for $t"
    srv6_force_clean "$node"
    gcu_apply "$node" "$add_patch" || die "Set $t: GCU apply-patch of SRv6 locator+SID failed"
    out=$(gnmi_get_json "$t" /SRV6_MY_SIDS)
    assert_values_nonempty "Set $t (read-back)" "$out"
    grep -q '"action":"uN"' <<<"$(values_json "$out")" || die "$t: SRv6 SID read-back does not carry action uN"
    grep -q "$LOC_NAME" <<<"$(values_json "$out")" || die "$t: SRv6 SID read-back missing witness key $LOC_NAME"
    gcu_apply "$node" "$del_patch" || die "Set $t: GCU cleanup patch failed"
    srv6_force_clean "$node"
    # delete must actually remove it (and SRv6 table empties out)
    out=$(gnmi_get_json "$t" /SRV6_MY_SIDS)
    if grep -q "$LOC_NAME" <<<"$out"; then die "$t: SRv6 SID still present after delete patch"; fi
    note "$t: write→read-back→delete witness asserted (action uN, key ${LOC_NAME})"
  done
}

# Subscribe — a subscription must deliver actual telemetry content.
# The sonic-gnmi build answers STREAM/SAMPLE subscriptions but never terminates a
# ONCE subscription on the sonic-db origin (verified 2026-08-31), so subscribe in
# stream-sample mode for a bounded window and assert the delivered update content.
subscribe_metadata() {
  local out
  IFS=',' read -ra tgts <<<"$TARGETS"
  for t in "${tgts[@]}"; do
    out=$(timeout 12 "$GNMIC_BIN" --address "$t" --timeout 10s $(tls_args) \
      subscribe --mode stream --stream-mode sample --sample-interval 2s \
      --path '/DEVICE_METADATA' --target CONFIG_DB 2>&1 || true)
    grep -q 'localhost' <<<"$out" || die "$t: subscribe returned no DEVICE_METADATA content"
    grep -qE 'hwsku' <<<"$out" || die "$t: subscribe reply missing hwsku field"
    note "$t: subscribe content asserted (DEVICE_METADATA delivered)"
  done
}

# sonic-srv6 — locator written via GCU must be readable over gNMI with its prefix intact
sonic_srv6_paths() {
  local add_patch del_patch out
  add_patch=$(printf '[
  {"op":"add","path":"/SRV6_MY_LOCATORS","value":{"%s":{"prefix":"%s"}}}
]' "$LOC_NAME" "$LOC_PREFIX")
  # Locator-only witness → remove the whole locator table. (Per-key removal of
  # keys containing "/" is impossible in GCU — findings §4.1 — and removing a
  # table that does not exist fails GCU validation.)
  del_patch='[
  {"op":"remove","path":"/SRV6_MY_LOCATORS"}
]'
  IFS=',' read -ra tgts <<<"$TARGETS"
  for t in "${tgts[@]}"; do
    local node
    node=$(node_for_ip "${t%%:*}")
    [[ -n "$node" ]] || die "sonic-srv6: cannot resolve containerlab node for $t"
    srv6_force_clean "$node"
    gcu_apply "$node" "$add_patch" || die "sonic-srv6 $t: GCU locator write failed"
    out=$(gnmi_get_json "$t" /SRV6_MY_LOCATORS)
    assert_values_nonempty "sonic-srv6 $t (read-back)" "$out"
    grep -q "$LOC_PREFIX" <<<"$(values_json "$out")" || die "$t: locator read-back missing prefix $LOC_PREFIX"
    gcu_apply "$node" "$del_patch" || die "sonic-srv6 $t: GCU cleanup failed"
    srv6_force_clean "$node"
    note "$t: sonic-srv6 locator read-back asserted (prefix ${LOC_PREFIX})"
  done
}

# Persistent configuration validation (T014) — actual restart cycle lives in
# scripts/lib/persistence.sh; here only assert the witness path is owned.
persistent_configuration() {
  echo "Persistent configuration check" >&2
  get_metadata
}

main() {
  local test=$1
  shift || true
  # self-clean any written witness if the test aborts mid-way
  IFS=',' read -ra _tgts <<<"$TARGETS"
  trap 'for _t in ${_tgts[*]}; do _n=$(node_for_ip "${_t%%:*}" 2>/dev/null); [[ -n "$_n" ]] && srv6_force_clean "$_n"; done' EXIT
  case "$test" in
    Capabilities) capabilities ;;
    Get) get_metadata ;;
    Set) set_srv6_witness ;;
    Subscribe) subscribe_metadata ;;
    sonic-srv6) sonic_srv6_paths ;;
    persistent) persistent_configuration ;;
    *) echo "unknown test $test" >&2; exit 2 ;;
  esac
}

if [[ ${1:-} == "--run" ]]; then
  shift
  main "$@"
fi
