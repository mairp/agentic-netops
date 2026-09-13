#!/usr/bin/env python3
"""Phase 3 acceptance for the agentic-netops demo video (machine-checked).

Reads meta-<take>.json written by record.py, re-verifies every success
criterion from live machine output (ffprobe, kubectl, and read-only
`docker exec <leaf> sr_cli "show ..."` on the Nokia SR Linux leaves) — never
from pixels — and writes evidence.json next to final.mp4.

VERIFY LIVE: the sr_cli show syntax and the exact shape of its output have not
been read off a running 26.7.2 node from this tree. The assertions below look
for the object names and addresses the renderer created, which survive a
cosmetic change in column layout; a genuine syntax change fails the check
loudly (empty output) rather than passing quietly.

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
# system0 addresses from lab/profiles/srlinux/config/*.cfg — the VTEP source
# address each leaf advertises, and therefore what its peer must list as a
# remote multicast destination for a stretched mac-vrf.
LEAF_SYSTEM_IP = {LEAF1: "10.0.0.21", LEAF2: "10.0.0.22"}
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


def _dev(ev: dict, net: dict | None) -> dict:
    """The on-device object names for this prompt. record.py records them in
    meta-<take>.json; if an older meta lacks them, derive from the Network spec
    with the same rule pkg/fabricplan uses."""
    dev = dict(ev.get("device_names") or {})
    if dev:
        return dev
    if not net:
        return {}
    spec = net.get("spec", {}) or {}
    routers = spec.get("routers") or []
    if routers:
        nm = routers[0].get("name", "")
        rest = nm[4:] if nm[:4].lower() == "vrf-" else nm
        rest = "".join(c for c in rest if c.isalnum() or c in "-_")
        dev["vrf"] = ("Vrf-" + rest[:10]) if rest else None
        dev["l3vni"] = routers[0].get("l3vni")
    bds = spec.get("bridgeDomains") or []
    if bds:
        nm = "".join(c for c in bds[0].get("name", "") if c.isalnum() or c in "-_.")
        dev["ni"] = nm[:255] if (nm and nm[0].isalpha()) else f"macvrf-{bds[0].get('vlan')}"
        dev["l2vni"] = bds[0].get("l2vni")
    return dev


def router_pass(pid: str, construct: str, cid: str, ev: dict, failures: list[str],
                prefix: str = "", net: dict | None = None) -> bool:
    """Re-run the construct's device checks from the host, fresh, read-only.

    Every command is `sr_cli "show ..."`; nothing here configures a node."""
    ok = True
    v = PROMPT_VLAN.get(pid)
    dev = _dev(ev, net)
    pre_ni = (ev.get("pre_snapshot", {}) or {}).get("NETWORK_INSTANCES", "") or ""
    pre_ni2 = (ev.get("pre_snapshot", {}) or {}).get("NETWORK_INSTANCES_LEAF2", "") or ""

    if construct == "vlan":
        ni = f"vlan-{v}"
        rc, out = host(f'docker exec {LEAF1} sr_cli "show network-instance summary"')
        ok &= check(failures, f"{pid} network-instance {ni} present and new (diff vs pre-prompt)",
                    rc == 0 and ni in out and ni not in pre_ni, out[:160])
        rc, out = host(f'docker exec {LEAF1} sr_cli "show network-instance {ni} interfaces"')
        ok &= check(failures, f"{pid} {ni} carries subinterface ethernet-1/3.{v}",
                    rc == 0 and f"ethernet-1/3.{v}" in out, out[:160])

    elif construct == "ip-vrf":
        vrf = dev.get("vrf") or ""
        ok &= check(failures, f"{pid} device ip-vrf name derived from the Network spec",
                    bool(vrf), f"vrf={vrf!r}")
        if vrf:
            rc, out = host(f'docker exec {LEAF1} sr_cli "show network-instance summary"')
            ok &= check(failures, f"{pid} network-instance {vrf} present and new (diff vs pre-prompt)",
                        rc == 0 and vrf in out and vrf not in pre_ni, out[:160])
            rc, out = host(f'docker exec {LEAF1} sr_cli "show network-instance {vrf} '
                           f'route-table ipv4-unicast summary"')
            ok &= check(failures, f"{pid} {vrf} route table carries {prefix}",
                        rc == 0 and prefix.split("/")[0] in out, out[:200])
        # Peer arrival: the Type-5 for this prefix as leaf02 sees it. Origination
        # on leaf01 cannot fake a route in the peer's EVPN RIB.
        rc, out = host(f'docker exec {LEAF2} sr_cli "show network-instance default '
                       f'protocols bgp routes evpn route-type 5 summary"')
        ip = prefix.split("/")[0] if prefix else ""
        ok &= check(failures, f"{pid} Type-5 for {prefix} present in leaf02's EVPN RIB",
                    rc == 0 and bool(ip) and ip in out, out[:200])

    elif construct == "mac-vrf":
        ni = dev.get("ni") or ""
        l2vni = dev.get("l2vni")
        ok &= check(failures, f"{pid} device mac-vrf name and l2vni derived from the Network spec",
                    bool(ni) and bool(l2vni), f"ni={ni!r} l2vni={l2vni!r}")
        for leaf, pre in ((LEAF1, pre_ni), (LEAF2, pre_ni2)):
            if not ni:
                break
            rc, out = host(f'docker exec {leaf} sr_cli "show network-instance summary"')
            ok &= check(failures, f"{pid} {leaf[-6:]} network-instance {ni} present and new",
                        rc == 0 and ni in out and (not pre or ni not in pre), out[:160])
        for leaf in (LEAF1, LEAF2):
            if not l2vni:
                break
            peer_ip = LEAF_SYSTEM_IP[LEAF2 if leaf == LEAF1 else LEAF1]
            rc, out = host(f'docker exec {leaf} sr_cli "show tunnel-interface vxlan1 '
                           f'vxlan-interface {l2vni} bridge-table multicast-destinations"')
            # The peer's system IP appears only once its IMET route arrived and
            # was installed: the one signal self-origination cannot produce.
            ok &= check(failures,
                        f"{pid} {leaf[-6:]} vni {l2vni} lists remote VTEP {peer_ip}",
                        rc == 0 and peer_ip in out, out[:200])

    elif construct == "acl":
        pre_acl = (ev.get("pre_snapshot", {}) or {}).get("ACL", "") or ""
        rc, out = host(f'docker exec {LEAF1} sr_cli "show acl summary"')
        pre_names = set(re.findall(r"acl-[A-Za-z0-9_-]+", pre_acl))
        now_names = set(re.findall(r"acl-[A-Za-z0-9_-]+", out))
        new_names = now_names - pre_names
        ok &= check(failures, f"{pid} exactly one new acl-filter (diff vs pre-prompt)",
                    rc == 0 and len(new_names) == 1, str(sorted(new_names)))
        table = dev.get("acl") or (sorted(new_names)[0] if len(new_names) == 1 else "")
        family = dev.get("acl_family", "ipv4")
        if table:
            rc, out = host(f'docker exec {LEAF1} sr_cli "show acl acl-filter {table} type {family}"')
            ok &= check(failures, f"{pid} acl-filter {table} exists with entries",
                        rc == 0 and bool(out.strip()) and "443" in out, out[:200])
            # Bound on the wan attachment this prompt named.
            ok &= check(failures, f"{pid} acl-filter {table} bound on an ethernet-1/4 subinterface",
                        "ethernet-1/4" in out, out[:200])
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
