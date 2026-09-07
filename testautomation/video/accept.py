#!/usr/bin/env python3
"""Phase 3 acceptance for the agentic-netops demo video (machine-checked).

Reads meta-<take>.json written by record.py, re-verifies every success
criterion from live machine output (ffprobe, kubectl, docker exec redis/
vtysh) — never from pixels — and writes evidence.json next to final.mp4.

Usage: accept.py --take final
Exit 0 iff every mandatory criterion passes.
"""
from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

BASE = Path(__file__).resolve().parent
LEAF1 = "clab-agentic-netops-fabric-leaf01"
LEAF2 = "clab-agentic-netops-fabric-leaf02"
PROMPT_VLAN = {"A": "130", "A'": "131", "A2": "160", "C1": "150", "C2": "150",
               "C1'": "151", "C2'": "151",
               "A3": "170", "C3": "152"}


def now_iso() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="milliseconds")


def host(cmd: str, timeout: int = 120) -> tuple[int, str]:
    p = subprocess.run(["bash", "-c", cmd], capture_output=True, text=True, timeout=timeout)
    return p.returncode, (p.stdout + p.stderr).strip()


def check(failures: list[str], name: str, ok: bool, detail: str = "") -> bool:
    print(f"  [{'PASS' if ok else 'FAIL'}] {name}" + (f" — {detail}" if detail else ""))
    if not ok:
        failures.append(f"{name}: {detail}")
    return ok


def ffprobe(path: Path) -> dict:
    rc, out = host(f"ffprobe -v error -select_streams v:0 "
                   f"-show_entries stream=width,height -show_entries format=duration "
                   f"-of json {path}")
    if rc != 0:
        return {"error": out}
    js = json.loads(out)
    return {"width": js["streams"][0]["width"], "height": js["streams"][0]["height"],
            "duration": float(js["format"]["duration"])}


def network_by_cid(cid: str) -> dict | None:
    rc, out = host("kubectl -n agentic-netops-intent get networks.network.kubenet.dev "
                   f"-l agentic-netops.io/correlation-id={cid} -o json")
    if rc == 0:
        items = json.loads(out).get("items", [])
        if items:
            return items[0]
    return None


def ready_condition(net: dict) -> dict | None:
    for c in net.get("status", {}).get("conditions", []) or []:
        if isinstance(c, dict) and c.get("type") == "Ready":
            return c
    return None


def event_reasons(net_name: str) -> list[str]:
    rc, out = host(f"kubectl -n agentic-netops-intent get events "
                   f"--field-selector involvedObject.name={net_name} -o json")
    try:
        return [e.get("reason") for e in json.loads(out).get("items", [])]
    except Exception:
        return []


def router_pass(pid: str, construct: str, cid: str, ev: dict, failures: list[str],
                prefix: str = "", net: dict | None = None) -> bool:
    """Re-run the construct's router checks from the host, fresh."""
    ok = True
    v = PROMPT_VLAN.get(pid)
    # On this cluster the fabric VRF name is derived from the Network name
    # (migr-<id> -> Vrf-<id[:10]>), not from the correlation id; the RD and
    # l3vni come straight from the Network spec.
    vrf10 = rd = ""
    if net is not None:
        nname = net.get("metadata", {}).get("name", "")
        vrf10 = nname.replace("migr-", "")[:10]
        try:
            rd = net["spec"]["routers"][0]["rd"]
        except (KeyError, IndexError, TypeError):
            rd = ""
    if construct == "vlan":
        rc, out = host(f"docker exec {LEAF1} redis-cli -n 4 hgetall 'VLAN|Vlan{v}'")
        flat = out.replace("\n", " ")
        ok &= check(failures, f"{pid} VLAN|Vlan{v} hash non-empty with vlanid {v}",
                    rc == 0 and bool(out) and f"vlanid" in flat and v in flat.split(), out[:120])
        rc, out = host(f"docker exec {LEAF1} bridge vlan show dev eth3")
        ok &= check(failures, f"{pid} bridge vlan show dev eth3 lists {v}",
                    rc == 0 and re.search(rf"\b{v}\b", out) is not None, out[:120])
    elif construct == "ip-vrf":
        rc, out = host(f"docker exec {LEAF1} redis-cli -n 4 keys 'VRF|*'")
        keys = set(out.split())
        want = f"VRF|Vrf-{vrf10}"
        pre = set((ev.get("pre_snapshot", {}) or {}).get("VRF", "").split())
        ok &= check(failures, f"{pid} new VRF key {want} (diff vs pre-prompt)",
                    want in keys and want not in pre, f"keys={len(keys)}")
        rc, out = host(f"docker exec {LEAF1} vtysh -c 'show vrf'")
        ok &= check(failures, f"{pid} show vrf lists {want[4:]}",
                    rc == 0 and want[4:] in out, out[:120])
        rc, out = host(f"docker exec {LEAF1} vtysh -c 'show evpn vni'")
        l3rows = [ln for ln in out.splitlines() if re.search(r"\bL3\b", ln)]
        ok &= check(failures, f"{pid} show evpn vni L3 row with Tenant VRF {want[4:]}",
                    any(want[4:] in ln for ln in l3rows), "; ".join(l3rows)[:160])
        # FRR renders the Type-5 NLRI as [5]:[0]:[<mask>]:[<prefix>] grouped
        # under "Route Distinguisher: <rd>"; require the entry inside B's own
        # RD block carrying that RD as route target.
        rc, out = host(f"docker exec {LEAF1} vtysh -c 'show bgp l2vpn evpn route type prefix'")
        ip, mask = prefix.split("/") if "/" in prefix else (prefix, "")
        sect = re.split(r"Route Distinguisher: ", out)
        block = next((s for s in sect if s.startswith(f"{rd}\n")), "")
        hit = (rc == 0 and block and
               f"[5]:[0]:[{mask}]:[{ip}]" in block and f"RT:{rd}" in block)
        ok &= check(failures, f"{pid} Type-5 [{ip}] under own RD {rd}",
                    hit, f"rd={rd} block={'yes' if block else 'missing'}")
    elif construct == "mac-vrf":
        rc, out = host(f"docker exec {LEAF1} redis-cli -n 4 hgetall 'VLAN|Vlan{v}'")
        ok &= check(failures, f"{pid} VLAN|Vlan{v} row exists",
                    rc == 0 and bool(out.strip()), out[:100])
        rc, out = host(f"docker exec {LEAF1} redis-cli -n 4 keys 'VXLAN_TUNNEL_MAP|vtep1|map_*_Vlan{v}'")
        keys = [k for k in out.split() if k]
        pre = [k for k in ((ev.get("pre_snapshot", {}) or {}).get("VTMAP", "").split()) if k]
        ok &= check(failures, f"{pid} exactly one tunnel-map key for Vlan{v}",
                    len(keys) == 1 and keys[0] not in pre, str(keys))
        for leaf in (LEAF1, LEAF2):
            rc, out = host(f"docker exec {leaf} vtysh -c 'show evpn vni'")
            # columns: VNI Type VxLAN_IF #MACs #ARPs #Remote_VTEPs Tenant_VRF
            good = False
            rows = []
            for ln in out.splitlines():
                toks = ln.split()
                if f"vtep1-{v}" in toks:
                    rows.append(ln)
                    i = toks.index(f"vtep1-{v}")
                    if i >= 1 and len(toks) >= i + 4 and toks[i - 1] == "L2" and toks[i + 3] == "1":
                        good = True
            ok &= check(failures, f"{pid} {leaf[-6:]} L2 vtep1-{v} row, # Remote VTEPs = 1",
                        rc == 0 and good, "; ".join(rows)[:160] or out[:120])
    elif construct == "acl":
        rc, out = host(f"docker exec {LEAF1} redis-cli -n 4 keys 'ACL_TABLE|*'")
        keys = set(out.split())
        pre_t = set(((ev.get("pre_snapshot", {}) or {}).get("ACL_TABLE", "") or "").split())
        new_t = keys - pre_t
        ok &= check(failures, f"{pid} exactly one new ACL_TABLE key", len(new_t) == 1, str(sorted(new_t)))
        table = sorted(new_t)[0] if len(new_t) == 1 else ""
        if table:
            rc, out = host(f"docker exec {LEAF1} redis-cli -n 4 hgetall '{table}'")
            flat = out.replace("\n", " ")
            ok &= check(failures, f"{pid} ACL_TABLE bound to eth4 stage ingress",
                        "eth4" in flat and "ingress" in flat, flat[:160])
        rc, out = host(f"docker exec {LEAF1} redis-cli -n 4 keys 'ACL_RULE|*'")
        keys_r = set(out.split())
        pre_r = set(((ev.get("pre_snapshot", {}) or {}).get("ACL_RULE", "") or "").split())
        new_r = keys_r - pre_r
        ok &= check(failures, f"{pid} two new ACL_RULE keys", len(new_r) == 2, str(sorted(new_r)))
    return ok


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--take", default="final")
    args = ap.parse_args()
    meta_path = BASE / f"meta-{args.take}.json"
    video = BASE / f"{args.take}.mp4"
    failures: list[str] = []
    evidence: dict = {
        "generated_utc": now_iso(), "take": args.take,
        "video": {}, "prompts": [], "only_mp4": None,
    }

    print("== video file ==")
    check(failures, "final.mp4 exists", video.exists(), str(video))
    if video.exists():
        info = ffprobe(video)
        evidence["video"] = info
        check(failures, "ffprobe parses", "error" not in info, str(info))
        if "width" in info:
            check(failures, "width 1920", info["width"] == 1920, str(info["width"]))
            check(failures, "height 1080", info["height"] == 1080, str(info["height"]))
            check(failures, "duration > 0 (recorded, unbounded)", info.get("duration", 0) > 0,
                  str(info.get("duration")))
        # plays: decode a sample
        rc, out = host(f"ffmpeg -v error -i {video} -frames:v 30 -f null - 2>&1 | head -5")
        check(failures, "decodes (first 30 frames)", rc == 0, out[:200])

    mp4s = sorted(BASE.glob("*.mp4"))
    evidence["only_mp4"] = [p.name for p in mp4s]
    check(failures, "final.mp4 is the only .mp4 in the output dir",
          [p.name for p in mp4s] == [video.name], str([p.name for p in mp4s]))

    print("== prompts ==")
    meta = json.loads(meta_path.read_text())
    prompts = meta.get("prompts", [])
    check(failures, "at least 3 prompts in the take", len(prompts) >= 3, str(len(prompts)))
    for ev in prompts:
        pid, cid = ev.get("id"), ev.get("correlation_id")
        construct = ev.get("construct", "")
        pfx_m = re.search(r"(\d+\.\d+\.\d+\.\d+/\d+)", ev.get("prompt", ""))
        prefix = pfx_m.group(1) if pfx_m else ""
        print(f"-- {pid}")
        pe: dict = {"id": pid, "prompt": ev.get("prompt"), "construct": construct,
                    "correlation_id": cid, "checked_utc": now_iso()}

        # console truth captured from the DOM during the take
        dom = ev.get("dom_outcome_text") or ""
        check(failures, f"{pid} DOM deployment-outcome contains 'Deployed'",
              "Deployed" in dom, dom[:160])
        check(failures, f"{pid} no failure-reason in DOM", ev.get("failure_reason_present") is False,
              str(ev.get("failure_reason_present")))
        shots = sorted((BASE / "shots").glob(f"{args.take}-{pid}-outcome-*.png"))
        check(failures, f"{pid} outcome screenshot exists", bool(shots),
              str([s.name for s in shots]))
        secs = ev.get("seconds_enter_to_deployed")
        check(failures, f"{pid} Enter->Deployed seconds recorded", isinstance(secs, (int, float)),
              str(secs))
        pe["seconds_enter_to_deployed"] = secs
        pe["dom_outcome_text"] = dom
        pe["t_enter_utc"] = ev.get("t_enter_utc")
        pe["outcome_screenshots"] = [s.name for s in shots]

        # cluster truth, re-verified now
        net = network_by_cid(cid) if cid else None
        check(failures, f"{pid} Network found by correlation-id label", net is not None,
              cid or "no cid")
        if not net:
            continue
        name = net["metadata"]["name"]
        pe["network"] = name
        cond = ready_condition(net)
        pe["ready_condition"] = cond
        check(failures, f"{pid} Ready condition True", bool(cond) and cond.get("status") == "True",
              json.dumps(cond))
        check(failures, f"{pid} Ready reason ApplySucceeded",
              bool(cond) and cond.get("reason") == "ApplySucceeded", str(cond and cond.get("reason")))
        reasons = event_reasons(name)
        pe["event_reasons"] = reasons
        check(failures, f"{pid} ApplySucceeded event present", "ApplySucceeded" in reasons, str(reasons))

        stype = (net.get("metadata", {}).get("annotations", {}) or {}).get(
            "agentic-netops.io/service-type", "")
        pe["service_type"] = stype

        # router truth, re-verified now
        pe["router_pass"] = router_pass(pid, construct, cid or "", ev, failures, prefix, net)

        # captured command outputs from the take must exist
        cmds = ev.get("commands", {})
        check(failures, f"{pid} terminal commands captured", len(cmds) >= 3, str(sorted(cmds)))
        pe["commands"] = {k: {"cmd": c["cmd"], "rc": c["rc"]} for k, c in cmds.items()}

        evidence["prompts"].append(pe)

    print("== closing listing ==")
    closing = (meta.get("closing", {}) or {}).get("closing", {})
    if closing:
        print(closing.get("output", "")[:800])
        evidence["closing_listing"] = closing.get("output", "")

    evidence["accept_pass"] = not failures
    evidence["failures"] = failures
    out = BASE / "evidence.json"
    out.write_text(json.dumps(evidence, indent=1))
    print(f"\nevidence.json -> {out}")
    print("ACCEPT: PASS" if not failures else f"ACCEPT: FAIL ({len(failures)} problems)")
    return 0 if not failures else 1


if __name__ == "__main__":
    sys.exit(main())
