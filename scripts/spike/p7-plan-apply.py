#!/usr/bin/env python3
"""p7-plan-apply.py — drive a rendered fabricplan through the fabric-executor
the way the srv6 controller does (T339-T344 receipts, attempt 4 of run
20261017-083608-3277419).

    p7-plan-apply.py <plan.json> <mode>

  <plan.json>  either {"Nodes": {...}} (debug/srv6-plan-dump) or a list
               (cmd/fabricplan-print); both are normalised here.
  mode:
    forward    apply each node's forward ops  (per-op OK/FAIL; FAIL -> rc 1)
    verify     run each node's declared checks (per-check OK/FAIL; FAIL -> rc 1)
    rollback   apply each node's rollback ops (per-op, honest FAILs kept,
               best-effort -> always rc 0)
    preclean   apply each node's rollback ops silently per-op; the p7
               idempotency pattern: the plan's own rollback removes the rows
               the forward ops are about to add (the executor's GCU path
               fails an add of an already-existing row), then the forward
               apply is exercised for real (per-node summary -> rc 0)
    decap-repair  re-assert each node's End.DT46 decap op AFTER the kernel
               converged: the decap shell reads the VRF device's table id
               live, and vrfmgrd can churn the device right after the GCU
               re-add, so an immediate apply can carry a stale id (observed
               live 2026-10-17). The op is the renderer's own (idempotent
               `ip -6 route replace`); the assert checks each SID's kernel
               route carries `vrftable` == the device's CURRENT table id.
"""
import json
import os
import sys
import time
import urllib.error
import urllib.request

EXECUTOR = os.environ.get("P7_EXECUTOR_URL", "http://127.0.0.1:8084").rstrip("/")
TIMEOUT = 150


def post(path, payload):
    req = urllib.request.Request(
        EXECUTOR + path,
        data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT) as r:
            return json.loads(r.read().decode())
    except urllib.error.HTTPError as e:
        try:
            return json.loads(e.read().decode())
        except Exception:
            return {"error": "HTTP %d" % e.status}
    except Exception as e:  # connection refused etc.
        return {"error": str(e)}


def short(s, n=170):
    s = (s or "").replace("\n", " ⏎ ")
    return s if len(s) <= n else s[:n] + "…"


def nodes_of(plan_raw):
    plan = json.load(open(plan_raw)) if isinstance(plan_raw, str) else plan_raw
    if isinstance(plan, dict) and "Nodes" in plan:
        plan = list(plan["Nodes"].values())
    elif isinstance(plan, dict):
        plan = list(plan.values())
    return plan


def main():
    plan = nodes_of(sys.argv[1])
    mode = sys.argv[2]
    diffs = []
    for np in plan:
        node = np["node"]
        if mode in ("forward", "rollback"):
            ops = np["ops"] if mode == "forward" else np["rollback"]
            label = "forward" if mode == "forward" else "rollback"
            print(f"===== {node}: {label} {len(ops)} op(s) via /v1/node/apply =====")
            res = post("/v1/node/apply", {"node": node, "ops": ops})
            for i, r in enumerate(res.get("results", [])):
                kind = r.get("kind") or (", ".join(sorted(ops[i].keys())) if i < len(ops) else "?")
                ok = r.get("ok")
                print(f"  [{'OK ' if ok else 'FAIL'}] {kind}"
                      + ("" if ok else f" error={short(r.get('error'))}"))
                if not ok and mode == "forward":
                    diffs.append(f"{node} {kind}: {short(r.get('error'), 200)}")
            if not res.get("results"):
                line = f"  [FAIL] apply rejected: {short(res.get('error'))}"
                print(line)
                diffs.append(f"{node} apply: {short(res.get('error'), 200)}")
        elif mode == "preclean":
            res = post("/v1/node/apply", {"node": node, "ops": np["rollback"]})
            n = len(res.get("results", []))
            oks = sum(1 for r in res.get("results", []) if r.get("ok"))
            print(f"  preclean {node}: {oks}/{n} rollback op(s) applied "
                  f"(absent-row removals tolerated before the forward apply)")
        elif mode == "decap-repair":
            import re
            dec = [op for op in np["ops"]
                   if any("seg6local" in s for s in op.get("shell", []))]
            if not dec:
                print(f"  decap-repair {node}: no seg6local op(s) in plan — skipped")
                continue
            # The VRF device's table id can keep moving for tens of seconds
            # as async vrfmgrd events land after a GCU write (measured live
            # 2026-10-17), so converge: re-assert the renderer's own decap op
            # (idempotent `ip -6 route replace`), assert each SID's kernel
            # route carries `vrftable` == the device's CURRENT table id, and
            # accept only when the assert holds AND still holds after a
            # re-poll — re-asserting while the id moves. Bounded.
            sids = sorted(set(re.findall(
                r"fcbb:bbbb:[0-9a-f]{1,4}:[0-9a-f]{1,4}::/64",
                " ".join(s for op in dec for s in op.get("shell", [])))))
            checks = [{"type": "command", "expect": "vrftable", "command":
                       "ip -6 route show | grep '^%s ' | grep \"vrftable "
                       "$(ip -d link show Vrf1 2>/dev/null | grep -o 'table [0-9]*' "
                       "| cut -d' ' -f2)\"" % sid} for sid in sids]
            stable = False
            res = {}
            for attempt in range(1, 9):
                res = post("/v1/node/apply", {"node": node, "ops": dec})
                oks = bool(res.get("results")) and all(
                    r.get("ok") for r in res.get("results", []))
                print(f"  [{'OK ' if oks else 'FAIL'}] decap-repair {node} "
                      f"re-assert (converge round {attempt})"
                      + ("" if oks else f" error={short(res.get('error'))}"))
                if not oks:
                    diffs.append(f"{node} decap re-assert round {attempt}: "
                                 f"{short(res.get('error'), 200)}")
                    break
                time.sleep(4)  # let the write land before asserting
                vres = post("/v1/node/verify", {"node": node, "checks": checks})
                for sid, r in zip(sids, vres.get("results", [])):
                    ok = r.get("ok")
                    print(f"  [{'OK ' if ok else 'FAIL'}] decap-repair {node} "
                          f"{sid} vrftable == Vrf1 device table (round {attempt})"
                          + ("" if ok else f" actual={short(r.get('error') or r.get('actual'))}"))
                if not vres.get("results") or not all(
                        r.get("ok") for r in vres.get("results", [])):
                    time.sleep(4)  # churn still in flight — retry
                    continue
                # stability: the assert must survive a ~20s window (polls at
                # +4s/+12s/+20s) — the async churn after a GCU write lands
                # over tens of seconds (measured live 2026-10-17), so a
                # single re-poll accepts too early and the pings below die.
                stable = True
                for gap, extra in ((4, 0), (8, 1), (8, 2)):
                    time.sleep(gap)
                    vres2 = post("/v1/node/verify", {"node": node, "checks": checks})
                    holds = bool(vres2.get("results")) and all(
                        r.get("ok") for r in vres2.get("results", []))
                    print(f"  [{'OK ' if holds else 'FAIL'}] decap-repair {node} "
                          f"stability poll {extra + 1}/3 ({gap}s)")
                    if not holds:
                        stable = False
                        break
                if stable:
                    break
            if not stable:
                diffs.append(f"{node} decap-repair: vrftable==device-table "
                             f"did not converge (stable across a ~20s "
                             f"three-poll window) within 8 rounds")
        elif mode == "verify":
            checks = np["checks"]
            print(f"===== {node}: verify {len(checks)} check(s) via /v1/node/verify =====")
            vres = post("/v1/node/verify", {"node": node, "checks": checks})
            for r in vres.get("results", []):
                ok = r.get("ok")
                print(f"  [{'OK ' if ok else 'FAIL'}] {r.get('check', '?')}"
                      + ("" if ok else f" error={short(r.get('error') or r.get('actual'))}"))
                if not ok:
                    diffs.append(f"{node} {r.get('check', '?')}: "
                                 f"{short(r.get('error') or r.get('actual'), 200)}")
            if not vres.get("results"):
                line = f"  [FAIL] verify rejected: {short(vres.get('error'))}"
                print(line)
                diffs.append(f"{node} verify: {short(vres.get('error'), 200)}")
    if mode in ("forward", "verify", "decap-repair"):
        print("===== DIFFS: ops that failed or checks that did not hold =====")
        if diffs:
            for d in diffs:
                print("  - " + d)
            sys.exit(1)
        print("  none")
    sys.exit(0)


if __name__ == "__main__":
    main()
