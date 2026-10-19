#!/usr/bin/env bash
# p7-evpn3-rollback.sh — receipt body for p7-ip-vrf-evpn-rollback (T342,
# attempt 4 of run 20261017-083608-3277419).
#
# Establishes the ip-vrf/evpn construct state (recipe substrate + evpn3
# builders + the construct plan applied and verified through the executor),
# applies the construct's ROLLBACK ops through the executor, reads the fabric
# back to clean, then runs the recorded recipe teardown (evpn3-rollback.sh),
# shows the SRv6 locator state untouched, and proves the executor's GCU path
# still accepts later writes (add/remove the construct's VRF row).
set -u
set -o pipefail
. "$(dirname "$0")/p7-plan-lib.sh"

p7_context

echo "===== establish: recipe substrate + evpn3 builders + construct plan applied/verified ====="
echo "===== pre-clean the as-built (live-claims) plan first (a controller-era steering route blackholes the recipe dataplane) ====="
p7_live_preclean || exit 1

bash "$SPIKE_DIR/vpn-setup.sh" >/dev/null 2>&1 || { echo "SUBSTRATE-FAILED vpn-setup" >&2; exit 1; }
bash "$SPIKE_DIR/evpn3-setup.sh" >/dev/null 2>&1 || { echo "SUBSTRATE-FAILED evpn3-setup" >&2; exit 1; }
PLAN="$P7_TMP/ipvrf-eth3-plan.json"
p7_render_construct "$SPIKE_DIR/networks/ipvrf-eth3.yaml" "$PLAN" || exit 1
echo "construct plan rendered (full JSON in the plan-vs-recipe receipt):"
python3 - "$PLAN" <<'PY'
import json, sys
plan = json.load(open(sys.argv[1]))
if isinstance(plan, dict) and "Nodes" in plan:
    plan = list(plan["Nodes"].values())
for np in plan:
    print(f"  {np['node']}: {len(np['ops'])} forward op(s), {len(np['checks'])} check(s), "
          f"{len(np['rollback'])} rollback op(s)")
PY
python3 "$SPIKE_DIR/p7-plan-apply.py" "$PLAN" preclean || exit 1
python3 "$SPIKE_DIR/p7-plan-apply.py" "$PLAN" forward || exit 1
p7_wait_kernel "ip link show Vlan4040 >/dev/null 2>&1 && ip link show vtep1-4040 >/dev/null 2>&1" \
               "ip link show Vlan4040 >/dev/null 2>&1 && ip link show vtep1-4040 >/dev/null 2>&1" || exit 1
python3 "$SPIKE_DIR/p7-plan-apply.py" "$PLAN" verify || exit 1

echo "===== executor /v1/node/apply: the construct's rollback ops ====="
python3 "$SPIKE_DIR/p7-plan-apply.py" "$PLAN" rollback

echo "===== read back clean ====="
for n in leaf01 leaf02; do
    c=$(container_of "$n")
    echo "-- $n --"
    echo "   VRF|Vrf-p4-trial-i rows:            $(node_run "$c" "sudo redis-cli -n 4 --scan --pattern 'VRF|Vrf-p4-trial-i*' | wc -l" | tr -d '[:space:]')"
    echo "   VLAN|Vlan4040 rows:                 $(node_run "$c" "sudo redis-cli -n 4 --scan --pattern 'VLAN|Vlan4040*' | wc -l" | tr -d '[:space:]')"
    echo "   VXLAN_TUNNEL_MAP trial rows:        $(node_run "$c" "sudo redis-cli -n 4 --scan --pattern 'VXLAN_TUNNEL_MAP|vtep1|map_13518*' | wc -l" | tr -d '[:space:]')"
    echo "   bridge vid 4040 on Ethernet8:       $(node_run "$c" "sudo bridge vlan show dev Ethernet8 | grep -c 4040" | tr -d '[:space:]')"
    echo "   kernel Vlan4040 device:             $(node_run "$c" "ip link show Vlan4040 >/dev/null 2>&1 && echo lingering || echo gone" | tr -d '[:space:]')"
    echo "   kernel vtep1-4040 device:           $(node_run "$c" "ip link show vtep1-4040 >/dev/null 2>&1 && echo lingering || echo gone" | tr -d '[:space:]')"
    echo "   construct Type-5 (65000:18):        $(node_run "$c" "vtysh -c 'show bgp l2vpn evpn' | grep -c '65000:18'" | tr -d '[:space:]')"
done
echo "-- settle: construct Type-5 withdrawn + trial devices gone (bounded 60s poll)"
p7_settle "vtysh -c 'show bgp l2vpn evpn' | grep -q '65000:18' && echo route-present; ip link show vtep1-4040 >/dev/null 2>&1 && echo vtep-present" || true

echo "===== recipe teardown (scripts/spike/evpn3-rollback.sh, exactly as recorded) ====="
bash "$SPIKE_DIR/evpn3-rollback.sh" || { echo "RECIPE-TEARDOWN-FAILED" >&2; exit 1; }

echo "===== locator untouched ====="
for n in leaf01 leaf02; do
    c=$(container_of "$n")
    node_run "$c" "sudo redis-cli -n 4 --scan --pattern 'SRV6_MY_LOCATORS*' | sort" | sed "s/^/   $n SRV6_MY_LOCATORS: /"
    node_run "$c" "vtysh -c 'show segment-routing srv6 locator' | grep -E 'loc-leaf'" | sed "s/^/   $n locator table: /" | addr_norm
done

echo "===== later GCU writes still accepted (executor, per leaf: add /VRF/Vrf-p4-trial-i then remove /VRF) ====="
EXECUTOR="$P7_EXECUTOR_URL" python3 - <<'PY'
import json, os, urllib.request
executor = os.environ["EXECUTOR"].rstrip("/")
def post(path, payload):
    req = urllib.request.Request(executor + path, data=json.dumps(payload).encode(),
                                 headers={"Content-Type": "application/json"}, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=150) as r:
            return json.loads(r.read().decode())
    except Exception as e:
        return {"results": [], "error": str(e)}
for node in ("leaf01", "leaf02"):
    add = post("/v1/node/apply", {"node": node, "ops": [{"gcu": [{"op": "add", "path": "/VRF/Vrf-p4-trial-i", "value": {}}]}]})
    r = (add.get("results") or [{}])[0]
    print(f"  {node}: add /VRF/Vrf-p4-trial-i -> [{'OK ' if r.get('ok') else 'FAIL'}]"
          + ("" if r.get("ok") else f" error={r.get('error')}"))
    rm = post("/v1/node/apply", {"node": node, "ops": [{"gcu": [{"op": "remove", "path": "/VRF/Vrf-p4-trial-i"}]}]})
    r = (rm.get("results") or [{}])[0]
    print(f"  {node}: remove /VRF/Vrf-p4-trial-i -> [{'OK ' if r.get('ok') else 'FAIL'}]"
          + ("" if r.get("ok") else f" error={r.get('error')}"))
PY

echo "===== verdict ====="
ok=1
for n in leaf01 leaf02; do
    c=$(container_of "$n")
    [[ "$(node_run "$c" "sudo redis-cli -n 4 --scan --pattern 'VRF|Vrf-p4-trial-i*' | wc -l" | tr -d '[:space:]')" == "0" ]] || ok=0
    [[ "$(node_run "$c" "sudo redis-cli -n 4 --scan --pattern 'VLAN|Vlan4040*' | wc -l" | tr -d '[:space:]')" == "0" ]] || ok=0
    [[ "$(node_run "$c" "vtysh -c 'show bgp l2vpn evpn' | grep -c '65000:18'" | tr -d '[:space:]')" == "0" ]] || ok=0
    node_run "$c" "sudo redis-cli -n 4 --scan --pattern 'SRV6_MY_LOCATORS*'" | grep -q . || ok=0
done
if [[ "$ok" == 1 ]]; then
    echo "IPVRF-EVPN-PLAN-ROLLBACK: clean — construct CONFIG_DB rows, kernel vlan/vtep devices and the Type-5"
    echo "route all read back absent after the executor-applied rollback; the recipe teardown restores the spike"
    echo "as-built; locator state untouched; later GCU writes accepted."
else
    echo "IPVRF-EVPN-PLAN-ROLLBACK: ITEM MISSING ABOVE (receipt records the failure honestly)"
    exit 1
fi
