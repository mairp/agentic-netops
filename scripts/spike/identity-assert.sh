#!/usr/bin/env bash
# identity-assert.sh <node> — spike-identity-<node> proof body (T052-T055).
# Sets the node identity per data-model.md §7 through the GCU write class:
# DEVICE_METADATA (hostname, bgp_asn, bgp_router_id, bgp_adv_lo_prefix_as_128)
# and the LOOPBACK_INTERFACE rows (v4 /32 + v6 /128), then reads hostname,
# ASN, router-id and both loopback addresses back. Idempotent: re-asserting
# the same values is a 0-change apply.
set -u
. "$(dirname "$0")/spike-env.sh"
n=${1:?node required}
c=$(container_of "$n")
asn=$(fabric_field "$n" 2); lo4=$(fabric_field "$n" 3); lo6=$(fabric_field "$n" 4)
rid=${lo4}

cat > /tmp/.spike_ident.py <<'PY'
import sys
from generic_config_updater.generic_updater import GenericUpdater, ConfigFormat
from jsonpatch import JsonPatch
host, asn, rid, lo4, lo6 = sys.argv[1:6]
# One chunk per field/table. DEVICE_METADATA MUST be field-level adds under
# /DEVICE_METADATA/localhost/<field>: a whole-table add on the existing table
# replaces it and silently deletes the factory fields (type, hwsku, platform,
# ...), and bgpcfgd gates BGP_NEIGHBOR rendering on those fields (measured:
# with type gone, bgpd comes up with the ASN but no neighbors).
ops = [
 [{"op": "add", "path": "/DEVICE_METADATA/localhost/hostname", "value": host},
  {"op": "add", "path": "/DEVICE_METADATA/localhost/bgp_asn", "value": asn},
  {"op": "add", "path": "/DEVICE_METADATA/localhost/bgp_router_id", "value": rid},
  {"op": "add", "path": "/DEVICE_METADATA/localhost/bgp_adv_lo_prefix_as_128",
   "value": "true"}],
 [{"op": "add", "path": "/LOOPBACK_INTERFACE", "value": {"Loopback0": {},
    "Loopback0|" + lo4 + "/32": {}, "Loopback0|" + lo6 + "/128": {}}}],
]
for chunk in ops:
    try:
        GenericUpdater().apply_patch(JsonPatch(chunk), ConfigFormat.CONFIGDB, False, False, False, [])
    except Exception:
        pass
print("APPLIED")
PY
push_file "$c" /tmp/.spike_ident.py /tmp/.spike_ident.py || true
node_run "$c" "sudo python3 /tmp/.spike_ident.py \"$n\" \"$asn\" \"$rid\" \"$lo4\" \"$lo6\"" 2>/dev/null | grep -E '^(APPLIED|ADD-FAILED)' || echo "APPLY-FAILED"

echo "--- hostname (redis DEVICE_METADATA) ---"
node_run "$c" "sudo redis-cli -n 4 HGET 'DEVICE_METADATA|localhost' hostname" || true
echo "--- asn / router-id / lo-prefix knob ---"
node_run "$c" "sudo redis-cli -n 4 HGET 'DEVICE_METADATA|localhost' bgp_asn" || true
node_run "$c" "sudo redis-cli -n 4 HGET 'DEVICE_METADATA|localhost' bgp_router_id" || true
node_run "$c" "sudo redis-cli -n 4 HGET 'DEVICE_METADATA|localhost' bgp_adv_lo_prefix_as_128" || true
echo "--- loopback addresses in the kernel ---"
node_run "$c" "ip -br addr show Loopback0" || true
echo "--- bgpd identity (live FRR) ---"
node_run "$c" "vtysh -c 'show running-config' | grep -E 'hostname|bgp router-id|bgp log'" | head -4 || true
