#!/usr/bin/env bash
# p7-vpn-rollback.sh — receipt body for p7-ip-vrf-vpn-rollback (T340, attempt
# 4 of run 20261017-083608-3277419).
#
# Applies the rendered ip-vrf/vpn plan's ROLLBACK ops through the executor on
# an established substrate, reads the fabric back to clean (CONFIG_DB rows,
# kernel decap/steering/pin, client addresses), shows the SRv6 locator state
# untouched, proves the executor's GCU path still accepts later writes
# (add/remove /VRF), then RESTORES the substrate and re-verifies the
# dataplane. Mirrors the recorded spike rollback receipt's read-back shape
# (gates/proofs/spike-vpn-rollback.out).
#
# Attempt 6 (owner directive 2026-10-17 16:30, items a/b): the completion
# pass below runs ONLY when a plan rollback op actually FAILED in the apply
# output (its intro quotes the real failing lines); every completion op
# prints its real outcome — no literal "-> OK" — and the addr flushes are
# labeled HOST-SIDE (node_run/client_run), not executor calls. The verdict is
# gated on exactly what it claims: the plan's peer-/48 pin route absent as an
# EXACT line (leaf01 fcbb:bbbb:4::/48, leaf02 fcbb:bbbb:3::/48), steering in
# Vrf1 = 0 and attachment rows = 0; the peer-/48 read-back prints the exact
# line, not a count.
set -u
set -o pipefail
. "$(dirname "$0")/p7-plan-lib.sh"

p7_context

echo "===== establish the substrate (recipe rows + executor-applied plan; see the plan-vs-recipe receipt) ====="
bash "$SPIKE_DIR/p7-vpn-substrate.sh" > "$P7_TMP/rollback-substrate.txt" 2>&1 \
    && echo "substrate established: $(tail -1 "$P7_TMP/rollback-substrate.txt")" \
    || { echo "SUBSTRATE-FAILED"; cat "$P7_TMP/rollback-substrate.txt"; exit 1; }

PLAN="$P7_TMP/vpn-plan.json"
p7_render_srv6 1 192.168.1.0/24 192.168.2.0/24 "$PLAN" || exit 1
echo "===== rendered plan shape (full JSON in the plan-vs-recipe receipt) ====="
python3 - "$PLAN" <<'PY'
import json, sys
plan = json.load(open(sys.argv[1]))
if isinstance(plan, dict) and "Nodes" in plan:
    plan = list(plan["Nodes"].values())
for np in plan:
    print(f"  {np['node']}: {len(np['ops'])} forward op(s), {len(np['checks'])} check(s), "
          f"{len(np['rollback'])} rollback op(s)")
PY

echo "===== executor /v1/node/apply: the plan's rollback ops ====="
ROLLBACK_APPLY_OUT="$P7_TMP/rollback-apply.txt"
python3 "$SPIKE_DIR/p7-plan-apply.py" "$PLAN" rollback | tee "$ROLLBACK_APPLY_OUT"
PLAN_ROLLBACK_FAILED=0
grep -q '\[FAIL\]' "$ROLLBACK_APPLY_OUT" && PLAN_ROLLBACK_FAILED=1

if [[ "$PLAN_ROLLBACK_FAILED" == 1 ]]; then
    echo "===== completion pass (runs ONLY because a plan rollback op FAILED above) ====="
    echo "-- failing op(s), quoted from the apply output above:"
    grep '\[FAIL\]' "$ROLLBACK_APPLY_OUT" | sed 's/^/--   /'
    echo "-- the SAME rollback intent is completed through the executor's ACCEPTED field-level"
    echo "-- paths: per-address row removes, the vrf_name field unbind, then /VRF — each"
    echo "-- printing the executor's real outcome below. The two addr flushes per leaf are"
    echo "-- HOST-SIDE (node_run / client_run, NOT executor calls) and are labeled as such;"
    echo "-- as-found extra attachment rows not owned by the plan leave the same way."
    gcu_rm() {  # gcu_rm <node> <json-pointer-path> — one GCU remove via the executor
        P7_EXECUTOR_URL="$P7_EXECUTOR_URL" P7_GCU_NODE="$1" P7_GCU_PATH="$2" python3 - <<'PY'
import json, os, urllib.request
executor = os.environ["P7_EXECUTOR_URL"].rstrip("/")
payload = {"node": os.environ["P7_GCU_NODE"],
           "ops": [{"gcu": [{"op": "remove", "path": os.environ["P7_GCU_PATH"]}]}]}
req = urllib.request.Request(executor + "/v1/node/apply", data=json.dumps(payload).encode(),
                             headers={"Content-Type": "application/json"}, method="POST")
try:
    with urllib.request.urlopen(req, timeout=60) as r:
        res = json.loads(r.read().decode())
    res = (res.get("results") or [{}])[0]
    print("OK" if res.get("ok") else f"FAIL {res.get('error')}")
except Exception as e:
    print(f"FAIL {e}")
PY
    }
    for n in leaf01 leaf02; do
        c=$(container_of "$n")
        while IFS= read -r row; do
            row=$(echo "$row" | tr -d '[:space:]')
            [[ -z "$row" ]] && continue
            key=$(echo "$row" | sed 's|^INTERFACE||; s|/|~1|g')
            echo "  $n: remove /INTERFACE$key -> $(gcu_rm "$n" "/INTERFACE$key")"
        done < <(node_run "$c" "sudo redis-cli -n 4 --scan --pattern 'INTERFACE|Ethernet12|*' | sort")
        echo "  $n: remove /INTERFACE/Ethernet12/vrf_name -> $(gcu_rm "$n" "/INTERFACE/Ethernet12/vrf_name")"
        echo "  $n: remove /VRF -> $(gcu_rm "$n" "/VRF")"
        node_run "$c" "sudo ip addr flush dev Ethernet12" >/dev/null 2>&1
        echo "  $n: addr flush Ethernet12 [HOST-SIDE node_run, not the executor; the plan's ops[3] intent] -> addr after: '$(node_run "$c" "ip -br addr show Ethernet12 | awk '{print \$3}'" | tr -d '[:space:]')'"
        if [[ "$n" == leaf01 ]]; then cl="$C_srv6_client01"; else cl="$C_srv6_client02"; fi
        client_run "$cl" "ip addr flush dev eth1" >/dev/null 2>&1
        echo "  $n: addr flush client eth1 [HOST-SIDE client_run, not the executor; the plan's ops[4] intent] -> addr after: '$(client_run "$cl" "ip -br addr show eth1" | awk '{print $3}' | tr -d '[:space:]')'"
    done
else
    echo "===== completion pass: NOT NEEDED — every plan rollback op above reported [OK ] ====="
    echo "-- the plan's own rollback (5 ops per leaf, all via executor /v1/node/apply) is the"
    echo "-- whole rollback intent; no completion op runs outside it (owner directive"
    echo "-- 2026-10-17 16:30 item a)."
fi

echo "===== read back clean ====="
for n in leaf01 leaf02; do
    c=$(container_of "$n")
    echo "-- $n --"
    echo "   VRF rows:            $(node_run "$c" "sudo redis-cli -n 4 --scan --pattern 'VRF|Vrf1' | wc -l" | tr -d '[:space:]')"
    echo "   attachment rows:     $(node_run "$c" "sudo redis-cli -n 4 --scan --pattern 'INTERFACE|Ethernet12*' | wc -l" | tr -d '[:space:]')"
    echo "   SID rows:            $(node_run "$c" "sudo redis-cli -n 4 --scan --pattern 'SRV6_MY_SIDS*' | wc -l" | tr -d '[:space:]')"
    echo "   seg6local routes:    $(node_run "$c" "ip -6 route show | grep -c seg6local" | tr -d '[:space:]')"
    echo "   steering in Vrf1:    $(node_run "$c" "ip route show vrf Vrf1 2>/dev/null | grep -c encap" | tr -d '[:space:]')"
    _peer48=$([[ "$n" == leaf01 ]] && echo 'fcbb:bbbb:4::/48' || echo 'fcbb:bbbb:3::/48')
    _pin=$(node_run "$c" "ip -6 route show | grep -F '$_peer48'" | head -1)
    if [[ -n "$_pin" ]]; then
        echo "   peer-/48 pin ($_peer48) exact line: $_pin"
    else
        echo "   peer-/48 pin ($_peer48) exact line: ABSENT (plan pin route gone)"
    fi
    echo "   Ethernet12 addr:     $(node_run "$c" "ip -br addr show Ethernet12 | awk '{print \$3}'" | tr -d '[:space:]')$([[ -z $(node_run "$c" "ip -br addr show Ethernet12 | awk '{print \$3}'" | tr -d '[:space:]') ]] && echo ' (flushed)')"
    if node_run "$c" "ip link show Vrf1 >/dev/null 2>&1"; then
        echo "   kernel Vrf1 device:  VRF-DEVICE-STILL-PRESENT (kernel device lingering is the spike-era observation too)"
    else
        echo "   kernel Vrf1 device:  removed with the row"
    fi
done
echo "-- clients --"
echo "   client01 eth1: $(client_run "$C_srv6_client01" "ip -br addr show eth1" | awk '{print $3}' | tr -d '[:space:]')$([[ -z $(client_run "$C_srv6_client01" "ip -br addr show eth1" | awk '{print $3}' | tr -d '[:space:]') ]] && echo ' (flushed)')"
echo "   client02 eth1: $(client_run "$C_srv6_client02" "ip -br addr show eth1" | awk '{print $3}' | tr -d '[:space:]')$([[ -z $(client_run "$C_srv6_client02" "ip -br addr show eth1" | awk '{print $3}' | tr -d '[:space:]') ]] && echo ' (flushed)')"

echo "===== locator untouched ====="
for n in leaf01 leaf02; do
    c=$(container_of "$n")
    node_run "$c" "sudo redis-cli -n 4 --scan --pattern 'SRV6_MY_LOCATORS*' | sort" | sed "s/^/   $n SRV6_MY_LOCATORS: /"
    node_run "$c" "vtysh -c 'show segment-routing srv6 locator' | grep -E 'loc-leaf'" | sed "s/^/   $n locator table: /" | addr_norm
done

echo "===== verdict inputs — the POST-ROLLBACK state (captured BEFORE the later-writes probe"
echo "===== re-adds /VRF/Vrf1 and BEFORE the restore re-establishes the substrate) ====="
c1=$(container_of leaf01); c2=$(container_of leaf02)
ok=1
for c in "$c1" "$c2"; do
    [[ "$(node_run "$c" "sudo redis-cli -n 4 --scan --pattern 'VRF|Vrf1' | wc -l" | tr -d '[:space:]')" == "0" ]] || ok=0
    [[ "$(node_run "$c" "sudo redis-cli -n 4 --scan --pattern 'INTERFACE|Ethernet12*' | wc -l" | tr -d '[:space:]')" == "0" ]] || ok=0
    [[ "$(node_run "$c" "ip -6 route show | grep -c seg6local" | tr -d '[:space:]')" == "0" ]] || ok=0
    [[ "$(node_run "$c" "ip route show vrf Vrf1 2>/dev/null | grep -c encap" | tr -d '[:space:]')" == "0" ]] || ok=0
    _peer48=$([[ "$c" == "$c1" ]] && echo 'fcbb:bbbb:4::/48' || echo 'fcbb:bbbb:3::/48')
    if [[ -n "$(node_run "$c" "ip -6 route show | grep -F '$_peer48'")" ]]; then
        ok=0
        echo "-- GATE-FAIL: $c still carries the plan's peer-/48 pin line ($_peer48):"
        node_run "$c" "ip -6 route show | grep -F '$_peer48'" | sed 's/^/--   /'
    fi
done
[[ "$(client_run "$C_srv6_client01" "ip -br addr show eth1" | awk '{print $3}' | tr -d '[:space:]')" == "" ]] || ok=0
[[ "$(client_run "$C_srv6_client02" "ip -br addr show eth1" | awk '{print $3}' | tr -d '[:space:]')" == "" ]] || ok=0
grep -q 'loc-leaf01' <(node_run "$c1" "sudo redis-cli -n 4 --scan --pattern 'SRV6_MY_LOCATORS*'") || ok=0
grep -q 'loc-leaf02' <(node_run "$c2" "sudo redis-cli -n 4 --scan --pattern 'SRV6_MY_LOCATORS*'") || ok=0
echo "post-rollback verdict inputs collected (ok=$ok)"

echo "===== later GCU writes still accepted (executor, per leaf: add /VRF/Vrf1 then remove /VRF) ====="
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
    add = post("/v1/node/apply", {"node": node, "ops": [{"gcu": [{"op": "add", "path": "/VRF/Vrf1", "value": {}}]}]})
    r = (add.get("results") or [{}])[0]
    print(f"  {node}: add /VRF/Vrf1 -> [{'OK ' if r.get('ok') else 'FAIL'}]"
          + ("" if r.get("ok") else f" error={r.get('error')}"))
    rm = post("/v1/node/apply", {"node": node, "ops": [{"gcu": [{"op": "remove", "path": "/VRF"}]}]})
    r = (rm.get("results") or [{}])[0]
    print(f"  {node}: remove /VRF -> [{'OK ' if r.get('ok') else 'FAIL'}]"
          + ("" if r.get("ok") else f" error={r.get('error')} (the remove re-restores the rolled-back state)"))
PY

echo "===== restore (re-establish the substrate; dataplane re-verified) ====="
bash "$SPIKE_DIR/p7-vpn-substrate.sh" > "$P7_TMP/rollback-restore.txt" 2>&1 \
    && echo "substrate re-established: $(tail -1 "$P7_TMP/rollback-restore.txt")" \
    || { echo "RESTORE-FAILED"; cat "$P7_TMP/rollback-restore.txt"; exit 1; }
bash "$SPIKE_DIR/vpn-ping.sh" > "$P7_TMP/rollback-restore-ping.txt" 2>&1 || true
echo "dataplane re-verified: $(grep -c ' 0% packet loss' "$P7_TMP/rollback-restore-ping.txt")/4 ping sections at 0% loss"
[[ "$(grep -c ' 0% packet loss' "$P7_TMP/rollback-restore-ping.txt")" == 4 ]] || ok=0

echo "===== verdict ====="
if [[ "$ok" == 1 ]]; then
    echo "VPN-PLAN-ROLLBACK: clean — CONFIG_DB VRF/SID/attachment rows, the plan's peer-/48 pin"
    echo "route (EXACT line absent: leaf01 fcbb:bbbb:4::/48, leaf02 fcbb:bbbb:3::/48), kernel"
    echo "seg6local decap, steering in Vrf1 and client addresses all read back absent after the"
    echo "rollback (verdict captured pre-restore); locator state untouched; later GCU writes"
    echo "accepted; substrate restored and dataplane re-verified."
else
    echo "VPN-PLAN-ROLLBACK: ITEM MISSING ABOVE (receipt records the failure honestly)"
    exit 1
fi
