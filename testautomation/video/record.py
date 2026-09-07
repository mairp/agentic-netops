#!/usr/bin/env python3
"""Deterministic screen-recording driver for the agentic-netops intent-tier demo.

One command runs one take: it starts Xvfb :99 + ttyd + a headed Chromium with
two tabs (console U, terminal T), records the display with ffmpeg x11grab,
drives the console prompts and the terminal validation commands, and writes a
raw evidence file meta-<take>.json next to the video. It never edits cluster
or router state; everything it runs on the routers is read-only.

Usage:
  record.py --prompts A3,B3,C3 --take final [--gap 6] [--cmd-wait 2.5]
            [--overview 15] [--sdcio auto] [--no-record]
  record.py --smoke --take smoke        # layout + framing only, no prompts, no video

Framing rules (2026-09-07, after the first accepted take was reviewed):
  * the terminal is never CSS-zoomed; ttyd's own fontSize sizes xterm to the
    1920x1080 page (135x39 at 24 px), and the xterm screen box must lie inside
    the viewport, otherwise the take fails;
  * every terminal command waits for the shell prompt to come back (read from
    xterm's buffer through window.term) before the screenshot and the next
    command, so no output is missing from the frame;
  * the agent canvas is zoomed OUT until the whole topology (supervisor,
    three workers, controllers, fabric) fits inside the canvas viewport, and
    that is asserted before every prompt;
  * router-side VLAN lookups scan keys case-insensitively instead of guessing
    the key's letter case.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import signal
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

BASE = Path(__file__).resolve().parent
SHOTS = BASE / "shots"
SNAP = BASE / "snap" / "pre.json"

LEAF1 = "clab-agentic-netops-fabric-leaf01"
LEAF2 = "clab-agentic-netops-fabric-leaf02"
UI_URL = "http://127.0.0.1:30000/"
TTYD_URL = "http://127.0.0.1:7681/"

PROMPTS = {
    "A": "Provision a vlan 130 on leaf01 ethernet1 for tenant acme",
    "B": "Deploy an ip-vrf between leaf01 wan1 and leaf02 wan1 for tenant initech with prefix 10.50.0.0/24",
    "C1": "Extend vlan150 as a mac-vrf across leaf01 ethernet1 and leaf02 ethernet1 for tenant blue",
    "C2": "Create a mac-vrf across leaf01 ethernet1 and leaf02 ethernet1 for tenant blue using vlan150",
    "D": "Apply an acl on leaf01 wan1 for tenant acme: allow ingress tcp port 443 from 10.0.0.0/24, deny everything else",
    "A'": "Provision a vlan 131 on leaf01 ethernet1 for tenant acme",
    "B'": "Deploy an ip-vrf between leaf01 wan1 and leaf02 wan1 for tenant initech with prefix 10.51.0.0/24",
    "C1'": "Extend vlan151 as a mac-vrf across leaf01 ethernet1 and leaf02 ethernet1 for tenant blue",
    "C2'": "Create a mac-vrf across leaf01 ethernet1 and leaf02 ethernet1 for tenant blue using vlan151",
    "D'": "Apply an acl on leaf02 wan1 for tenant acme: allow ingress tcp port 443 from 10.0.0.0/24, deny everything else",
    # A'/B' wording is burned (each failed once in rehearsal-1/2 and the doc
    # forbids retrying the same wording); these are the same sanctioned
    # templates with fresh, unused identifiers (160 free per site ground
    # truth; 10.52.0.0/24 not referenced by any Network spec).
    "A2": "Provision a vlan 160 on leaf01 ethernet1 for tenant acme",
    "B2": "Deploy an ip-vrf between leaf01 wan1 and leaf02 wan1 for tenant initech with prefix 10.52.0.0/24",
    # 2026-09-07 re-take: 130/150/10.50 (final), 131/151/10.51 and 160/10.52
    # (rehearsals) are all consumed on the fabric; these are the next free ones
    # (VLAN usable range 1-4000; 170 and 152 absent from leaf01 CONFIG_DB and
    # from every Network spec; 10.53.0.0/24 referenced by no Network).
    "A3": "Provision a vlan 170 on leaf01 ethernet1 for tenant acme",
    "B3": "Deploy an ip-vrf between leaf01 wan1 and leaf02 wan1 for tenant initech with prefix 10.53.0.0/24",
    "C3": "Extend vlan152 as a mac-vrf across leaf01 ethernet1 and leaf02 ethernet1 for tenant blue",
}
CONSTRUCT = {"A": "vlan", "B": "ip-vrf", "C1": "mac-vrf", "C2": "mac-vrf", "D": "acl",
             "A'": "vlan", "B'": "ip-vrf", "C1'": "mac-vrf", "C2'": "mac-vrf", "D'": "acl",
             "A2": "vlan", "B2": "ip-vrf", "A3": "vlan", "B3": "ip-vrf", "C3": "mac-vrf"}
PROMPT_VLAN = {"A": "130", "A'": "131", "A2": "160", "A3": "170",
               "C1": "150", "C2": "150", "C1'": "151", "C2'": "151", "C3": "152"}
PROMPT_PREFIX = {"B": "10.50.0.0", "B'": "10.51.0.0", "B2": "10.52.0.0", "B3": "10.53.0.0"}
PROMPT_RE = r"operator@netops:.*\$ ?$"


def vlan_lookup(leaf: str, table: str, vlan: str) -> str:
    """Case-insensitive CONFIG_DB lookup typed on screen: scan the table's keys,
    keep those ending in vlan<id> whatever the letter case, print key + hash."""
    return (f"docker exec {leaf} sh -c 'for k in $(redis-cli -n 4 keys \"{table}|*\" | grep -i \"vlan{vlan}$\"); "
            f"do echo \"$k\"; redis-cli -n 4 hgetall \"$k\"; done'")

KCTYPE_COLS = ("NAME:.metadata.name,"
               "TYPE:'.metadata.annotations.agentic-netops\\.io/service-type',"
               "READY:'.status.conditions[?(@.type==\"Ready\")].status',"
               "REASON:'.status.conditions[?(@.type==\"Ready\")].reason'")


def now_iso() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="milliseconds")


def log(msg: str) -> None:
    print(f"[{datetime.now().strftime('%H:%M:%S')}] {msg}", flush=True)


def host(cmd: str) -> tuple[int, str]:
    """Run cmd on the host (source of truth). Returns (rc, combined output)."""
    p = subprocess.run(["bash", "-c", cmd], capture_output=True, text=True, timeout=120)
    return p.returncode, (p.stdout + (("\n[stderr] " + p.stderr) if p.stderr.strip() else "")).rstrip()


def term_commands(construct: str, net: str, cid: str, prompt_id: str) -> list[str]:
    kc = (f"kubectl -n agentic-netops-intent get networks.network.kubenet.dev "
          f"-l agentic-netops.io/correlation-id={cid} -o custom-columns={KCTYPE_COLS}")
    common = [
        kc,
        f"kubectl -n agentic-netops-intent get events --field-selector involvedObject.name={net}",
        f"kubectl -n agentic-netops-intent get networks.network.kubenet.dev {net} "
        f"-o jsonpath='{{.spec}}' | python3 -m json.tool | head -40",
    ]
    if construct == "vlan":
        v = PROMPT_VLAN[prompt_id]
        router = [
            vlan_lookup(LEAF1, "VLAN", v),
            f"docker exec {LEAF1} bridge vlan show dev eth3 | grep -E 'vlan-id|^eth3|^ +{v}( |$)'",
        ]
    elif construct == "ip-vrf":
        pfx = PROMPT_PREFIX.get(prompt_id, "")
        router = [
            f"docker exec {LEAF1} redis-cli -n 4 keys 'VRF|*'",
            f"docker exec {LEAF1} vtysh -c 'show vrf'",
            f"docker exec {LEAF1} vtysh -c 'show evpn vni' | grep -E 'VNI|L3'",
            f"docker exec {LEAF1} vtysh -c 'show bgp l2vpn evpn route type prefix' | grep -B3 -A4 -F '[{pfx}]'",
        ]
    elif construct == "mac-vrf":
        v = PROMPT_VLAN[prompt_id]
        router = [
            vlan_lookup(LEAF1, "VLAN", v),
            f"docker exec {LEAF1} sh -c 'redis-cli -n 4 keys \"VXLAN_TUNNEL_MAP|*\" | grep -i \"vlan{v}$\"'",
            f"docker exec {LEAF1} vtysh -c 'show evpn vni' | grep -E 'VNI|L2'",
            f"docker exec {LEAF2} vtysh -c 'show evpn vni' | grep -E 'VNI|L2'",
        ]
    else:  # acl
        router = [
            f"docker exec {LEAF1} redis-cli -n 4 keys 'ACL_TABLE|*'",
            f"docker exec {LEAF1} redis-cli -n 4 keys 'ACL_RULE|*'",
            f'docker exec {LEAF1} redis-cli -n 4 hgetall '
            f'"$(docker exec {LEAF1} redis-cli -n 4 keys \'ACL_TABLE|*\' | tail -1)"',
        ]
    return common + router


AUTHORITY_CMDS = [
    "kubectl get crd | grep -E 'kubenet|kuid|sdcio'",
    "kubectl -n kuid-system get claims.id.kuid.dev,vniindices.id.kuid.dev",
    "kubectl get targets.sdc.sdcio.dev,configs.sdc.sdcio.dev -A",
]
CLOSING_CMD = ("kubectl -n agentic-netops-intent get networks.network.kubenet.dev "
               f"-o custom-columns=NAME:.metadata.name,"
               "TYPE:'.metadata.annotations.agentic-netops\\.io/service-type',"
               "READY:'.status.conditions[?(@.type==\"Ready\")].status' | grep -v '^migr-'")


class TakeFailure(Exception):
    pass


class Driver:
    def __init__(self, args):
        self.args = args
        self.take = args.take
        self.meta: dict = {"take": self.take, "started_utc": now_iso(),
                           "prompts": [], "overview_secs": args.overview,
                           "gap_secs": args.gap, "cmd_wait": args.cmd_wait}
        self.proc: dict = {}
        self.shot_idx = 0

    # ---------- infrastructure ----------
    def start_xvfb(self):
        if Path("/tmp/.X11-unix/X99").exists():
            log("Xvfb :99 already running; reusing")
            return
        subprocess.Popen(["Xvfb", ":99", "-screen", "0", "1920x1080x24", "-nolisten", "tcp"],
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        for _ in range(50):
            if Path("/tmp/.X11-unix/X99").exists():
                break
            time.sleep(0.2)
        log("Xvfb :99 started")

    def start_ttyd(self):
        subprocess.run(["pkill", "-f", "ttyd -p 7681"], capture_output=True)
        time.sleep(0.5)
        ps1 = "\\[\\e[32m\\]operator@netops\\[\\e[0m\\]:\\w$ "
        self.proc["ttyd"] = subprocess.Popen(
            ["ttyd", "-p", "7681", "-W",
             "-t", "fontSize=24",   # 135x39 on a 1920x1080 page; never CSS-zoom the page
             "-t", 'theme={"background":"#0d1117"}',
             "env", f"PS1={ps1}", "KUBECONFIG=/root/.kube/config",
             "bash", "--norc", "--noprofile"],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        time.sleep(1.5)
        log("ttyd started on :7681")

    def start_ffmpeg(self, out: Path):
        if self.args.no_record:
            return
        self.proc["ffmpeg"] = subprocess.Popen(
            ["ffmpeg", "-y", "-f", "x11grab", "-video_size", "1920x1080",
             "-framerate", "30", "-i", ":99", "-c:v", "libx264", "-preset", "veryfast",
             "-crf", "20", "-pix_fmt", "yuv420p", str(out)],
            stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        log(f"ffmpeg recording -> {out.name}")

    def stop_ffmpeg(self):
        f = self.proc.get("ffmpeg")
        if not f:
            return
        try:
            f.stdin.write(b"q")
            f.stdin.flush()
        except Exception:
            pass
        try:
            f.wait(timeout=20)
        except subprocess.TimeoutExpired:
            f.send_signal(signal.SIGINT)
            try:
                f.wait(timeout=15)
            except subprocess.TimeoutExpired:
                f.kill()
        log("ffmpeg stopped")

    def cleanup(self):
        for name in ("ffmpeg",):
            if name in self.proc:
                self.stop_ffmpeg()
        if "ttyd" in self.proc:
            self.proc["ttyd"].terminate()
        if self.args.stop_xvfb:
            subprocess.run(["pkill", "-f", "Xvfb :99"], capture_output=True)

    # ---------- console helpers ----------
    def shot(self, page, tag: str):
        self.shot_idx += 1
        p = SHOTS / f"{self.take}-{tag}-{self.shot_idx:02d}.png"
        page.screenshot(path=str(p))
        log(f"shot {p.name}")
        return p

    def frame_check(self, page, tag: str, labels: list[str], fatal: bool = True):
        """Mechanical framing check (this model has no image input): every
        named element's bounding box must sit fully inside the 1920x1080
        viewport — nothing clipped, nothing covered by being off-screen."""
        problems = []
        for label in labels:
            loc = page.get_by_label(label)
            box = loc.bounding_box() if loc.count() else None
            if not box:
                problems.append(f"{label}: not found")
                continue
            x, y, w, h = box["x"], box["y"], box["width"], box["height"]
            inside = x >= -1 and y >= -1 and x + w <= 1921 and y + h <= 1081
            if not inside:
                problems.append(f"{label}: box ({x:.0f},{y:.0f},{w:.0f}x{h:.0f}) outside viewport")
        if problems:
            self.meta.setdefault("framing_problems", []).append({tag: problems})
            msg = f"framing[{tag}]: {'; '.join(problems)}"
            if fatal:
                raise TakeFailure(msg)
            log(f"WARN {msg}")
        else:
            log(f"framing[{tag}]: ok")

    def wait_healthy(self, page):
        deadline = time.time() + 90
        while time.time() < deadline:
            try:
                r = page.request.get(UI_URL.rstrip("/") + "/api/v1/health", timeout=5000)
                if r.ok and r.json().get("status") == "ok":
                    return True
            except Exception:
                pass
            time.sleep(1.5)
        raise TakeFailure("supervisor health never reported ok")

    # ---------- terminal helpers ----------
    @staticmethod
    def term_lines(t) -> list[str]:
        """Every line of xterm's active buffer (ttyd exposes window.term)."""
        return t.evaluate(
            "(() => { const b = window.term && window.term.buffer.active; if (!b) return null;"
            " const out = []; for (let i = 0; i < b.length; i++) {"
            " const l = b.getLine(i); out.push(l ? l.translateToString(true) : ''); } return out; })()") or []

    def term_frame_check(self, t, tag: str):
        """The xterm screen must be fully inside the 1920x1080 page and fill it:
        no CSS zoom, no clipped columns on either edge."""
        t.evaluate("window.dispatchEvent(new Event('resize'))")
        time.sleep(0.4)
        x, y, w, h = t.evaluate(
            "(() => { const e = document.querySelector('.xterm-screen'); const r = e.getBoundingClientRect();"
            " return [r.x, r.y, r.width, r.height]; })()")
        cols, rows = t.evaluate("window.term ? [window.term.cols, window.term.rows] : [0, 0]")
        ok = x >= 0 and y >= 0 and x + w <= 1920.5 and y + h <= 1080.5 and w >= 0.95 * 1920 and h >= 0.9 * 1080
        self.meta.setdefault("terminal_frames", []).append(
            {tag: {"box": [x, y, w, h], "cols": cols, "rows": rows, "ok": ok}})
        if not ok:
            raise TakeFailure(f"framing[{tag}-terminal]: xterm screen box {[x, y, w, h]} cols={cols} rows={rows}"
                              " is clipped or does not fill the page")
        log(f"framing[{tag}-terminal]: ok ({cols}x{rows}, box {x:.0f},{y:.0f},{w:.0f}x{h:.0f})")

    def term_type(self, t, cmd: str):
        t.bring_to_front()
        time.sleep(0.5)
        t.mouse.click(960, 540)
        time.sleep(0.3)
        t.keyboard.type(cmd, delay=35)
        t.keyboard.press("Enter")

    def term_wait_prompt(self, t, lines_before: int, timeout: float) -> bool:
        """Wait until the shell prompt is back as the last line of the buffer
        AND the buffer has grown past the typed command line, i.e. the command
        finished and its output is on screen. (Counting prompt lines does not
        work: typing the command turns the current prompt line into
        'prompt$ command', which no longer looks like a bare prompt.)"""
        deadline = time.time() + timeout
        while time.time() < deadline:
            lines = [l for l in self.term_lines(t) if l.strip()]
            last = lines[-1] if lines else ""
            if len(lines) >= lines_before + 2 and re.search(PROMPT_RE, last):
                return True
            time.sleep(0.25)
        return False

    def run_terminal_cmd(self, t, cmd: str, evidence: dict, key: str) -> str:
        lines_before = sum(1 for l in self.term_lines(t) if l.strip())
        self.term_type(t, cmd)
        returned = self.term_wait_prompt(t, lines_before, timeout=max(30.0, self.args.cmd_wait * 4))
        time.sleep(self.args.cmd_wait)          # hold the output for the viewer
        self.shot(t, key)
        rc, out = host(cmd)
        screen = "\n".join(l for l in self.term_lines(t) if l.strip())
        evidence["commands"][key] = {"cmd": cmd, "rc": rc, "output": out,
                                     "prompt_returned_on_screen": returned,
                                     "screen_tail": screen[-1200:]}
        if not returned:
            log(f"WARN {key}: shell prompt did not return within the wait; output may be incomplete on screen")
        if rc != 0:
            log(f"WARN host rc={rc} for {key}")
        return out

    # ---------- canvas helpers ----------
    @staticmethod
    def canvas_boxes(u) -> tuple[list, list]:
        return u.evaluate(
            "(() => { const v = document.querySelector('.graph-viewport'); const f = document.querySelector('.topology-flow');"
            " const rv = v.getBoundingClientRect(), rf = f.getBoundingClientRect();"
            " return [[rv.x, rv.y, rv.width, rv.height], [rf.x, rf.y, rf.width, rf.height]]; })()")

    def canvas_fits(self, u, margin: float = 6.0) -> bool:
        (vx, vy, vw, vh), (fx, fy, fw, fh) = self.canvas_boxes(u)
        return (fx >= vx - margin and fy >= vy - margin and fx + fw <= vx + vw + margin
                and fy + fh <= vy + vh + margin and vx >= 0 and vy >= 0 and vx + vw <= 1921 and vy + vh <= 1081)

    def fit_canvas(self, u, tag: str):
        """Zoom the agent canvas OUT until the whole topology (supervisor, the
        three workers, controllers and fabric) lies inside the canvas viewport.
        Fails the take if it cannot be made to fit at the minimum zoom."""
        u.bring_to_front()
        time.sleep(0.4)
        zout = u.get_by_label("Zoom out canvas")
        for _ in range(16):
            if self.canvas_fits(u):
                break
            if zout.is_disabled():
                break
            zout.click()
            time.sleep(0.55)
        (vx, vy, vw, vh), (fx, fy, fw, fh) = self.canvas_boxes(u)
        zoom = u.get_by_label("Reset canvas view").inner_text().strip()
        ok = self.canvas_fits(u)
        self.meta.setdefault("canvas_frames", []).append(
            {tag: {"viewport": [vx, vy, vw, vh], "flow": [fx, fy, fw, fh], "zoom": zoom, "ok": ok}})
        if not ok:
            raise TakeFailure(f"framing[{tag}-canvas]: topology {[fx, fy, fw, fh]} does not fit the canvas "
                              f"viewport {[vx, vy, vw, vh]} at zoom {zoom}")
        log(f"framing[{tag}-canvas]: ok (zoom {zoom}, flow {fw:.0f}x{fh:.0f} in viewport {vw:.0f}x{vh:.0f})")

    # ---------- per-prompt flow ----------
    def clear_conversation(self, u):
        # the control exists twice (agent navigation sidebar + conversation
        # header) with the same aria-label; either clears the thread
        btn = u.get_by_label("Clear conversation").first
        if btn.count():
            btn.click()
            time.sleep(1.0)

    def run_prompt(self, u, t, pid: str, prompt: str, construct: str) -> dict:
        ev: dict = {"id": pid, "prompt": prompt, "construct": construct,
                    "t_enter": None, "t_deployed": None, "seconds_enter_to_deployed": None,
                    "correlation_id": None, "network": None, "ready_condition": None,
                    "dom_outcome_text": None, "failure_reason_present": None,
                    "commands": {}, "pre_snapshot": {}}
        log(f"--- prompt {pid}: {prompt}")

        # pre-snapshot for diff-based pass checks (ip-vrf / acl / mac-vrf)
        if construct == "ip-vrf":
            _, ev["pre_snapshot"]["VRF"] = host(f"docker exec {LEAF1} redis-cli -n 4 keys 'VRF|*'")
        if construct == "acl":
            _, ev["pre_snapshot"]["ACL_TABLE"] = host(f"docker exec {LEAF1} redis-cli -n 4 keys 'ACL_TABLE|*'")
            _, ev["pre_snapshot"]["ACL_RULE"] = host(f"docker exec {LEAF1} redis-cli -n 4 keys 'ACL_RULE|*'")
        if construct == "mac-vrf":
            v = PROMPT_VLAN[pid]
            _, ev["pre_snapshot"]["VTMAP"] = host(
                f"docker exec {LEAF1} redis-cli -n 4 keys 'VXLAN_TUNNEL_MAP|vtep1|map_*_Vlan{v}'")

        u.bring_to_front()
        time.sleep(0.6)
        assert u.get_by_label("deployment-outcome").count() == 0, "stale outcome card present"
        self.fit_canvas(u, f"{pid}-before")
        composer = u.get_by_label("Service request")
        composer.click()
        time.sleep(0.4)
        u.keyboard.type(prompt, delay=45)
        time.sleep(0.5)
        self.shot(u, f"{pid}-typed")
        self.frame_check(u, f"{pid}-typed", ["Service request"])
        u.keyboard.press("Enter")
        ev["t_enter"] = time.time()
        ev["t_enter_utc"] = now_iso()
        # record the partial evidence now so a failed prompt is still captured
        self.meta["prompts"].append(ev)
        log(f"Enter pressed ({pid})")

        # canvas animates SLIM traffic during interpretation: keep console front
        mapper = u.get_by_label("confirm-mapper")
        mapper.wait_for(state="visible", timeout=120_000)
        u.get_by_label("Zoom in conversation").click()
        time.sleep(1.5)
        # the conversation has just expanded and the canvas shrank: keep the
        # whole topology visible above it
        self.fit_canvas(u, f"{pid}-mapper")
        self.shot(u, f"{pid}-mapper")
        mapper.click()
        log(f"mapper confirmed ({pid})")

        alloc = u.get_by_label("confirm-allocator")
        alloc.wait_for(state="visible", timeout=120_000)
        time.sleep(1.5)
        self.shot(u, f"{pid}-allocator")
        alloc.click()
        log(f"allocator confirmed ({pid})")

        # wait for outcome. The deployer convergence watch is configured to
        # 1200 s on this stack (see REPORT.md: the network controller work
        # queue is saturated by the 5-min resync of the pre-existing
        # Networks, so a fresh Network's first apply lands minutes behind
        # Enter). The wait here must cover mapper + allocator + the full
        # watch with margin, otherwise the take dies while the console is
        # legitimately still converging.
        outcome = u.get_by_label("deployment-outcome")
        deadline = time.time() + 1800
        while time.time() < deadline:
            if u.get_by_label("failure-reason").count() > 0:
                ev["failure_reason_present"] = True
                ev["dom_outcome_text"] = u.get_by_label("failure-reason").inner_text()
                self.shot(u, f"{pid}-FAILED")
                raise TakeFailure(f"{pid}: failure-reason appeared: {ev['dom_outcome_text'][:200]}")
            if outcome.count() > 0:
                txt = outcome.inner_text()
                if "Deployed" in txt:
                    ev["t_deployed"] = time.time()
                    ev["dom_outcome_text"] = txt
                    break
                if "still converging" in txt or "Deployment failed" in txt:
                    ev["dom_outcome_text"] = txt
                    self.shot(u, f"{pid}-FAILED")
                    raise TakeFailure(f"{pid}: outcome not Deployed: {txt[:200]}")
            time.sleep(1)
        else:
            self.shot(u, f"{pid}-FAILED")
            raise TakeFailure(f"{pid}: timeout waiting for Deployed outcome")
        ev["seconds_enter_to_deployed"] = round(ev["t_deployed"] - ev["t_enter"], 1)
        ev["failure_reason_present"] = False
        log(f"{pid} Deployed in {ev['seconds_enter_to_deployed']}s: {ev['dom_outcome_text']}")
        # bring the Deployed card into the visible part of the conversation
        # (the panel scrolls; a card below the fold passes the box check but
        # is not on screen) and hold it for the viewer
        try:
            outcome.first.scroll_into_view_if_needed(timeout=5000)
        except Exception:
            pass
        time.sleep(2.5)  # hold the outcome card
        self.frame_check(u, f"{pid}-outcome", ["deployment-outcome", "Agent conversation"])
        self.shot(u, f"{pid}-outcome")

        # correlation id: supervisor audit log since Enter
        since = int(time.time() - ev["t_enter"]) + 5
        logs = subprocess.run(
            ["kubectl", "-n", "agentic-netops-agents", "logs", "deploy/supervisor", f"--since={since}s"],
            capture_output=True, text=True).stdout
        cids = re.findall(r"correlation=([0-9a-f]{16,})", logs)
        ev["correlation_id"] = cids[-1] if cids else None
        cid = ev["correlation_id"]

        # network name by label, fallback newest after Enter
        net = None
        if cid:
            rc, out = host("kubectl -n agentic-netops-intent get networks.network.kubenet.dev "
                           f"-l agentic-netops.io/correlation-id={cid} -o json")
            try:
                items = json.loads(out).get("items", [])
                if items:
                    net = items[0]["metadata"]["name"]
            except Exception:
                pass
        if not net:
            rc, out = host("kubectl -n agentic-netops-intent get networks.network.kubenet.dev -o json")
            items = json.loads(out).get("items", [])
            after = [i for i in items if i["metadata"]["creationTimestamp"] > ev["t_enter_utc"]]
            if after:
                after.sort(key=lambda i: i["metadata"]["creationTimestamp"])
                net = after[-1]["metadata"]["name"]
        ev["network"] = net
        if not net:
            raise TakeFailure(f"{pid}: could not resolve Network for correlation={cid}")
        log(f"{pid} correlation={cid} network={net}")

        # terminal validation block. A `clear` first puts this prompt's proof
        # at the top of the screen. The page is never CSS-zoomed: xterm is
        # sized by ttyd's fontSize to the full 1920x1080 page, and the frame
        # check below fails the take if the screen box is clipped.
        self.term_type(t, "clear")
        time.sleep(1.2)
        self.term_frame_check(t, pid)
        cmds = term_commands(construct, net, cid or "NONE", pid)
        for i, cmd in enumerate(cmds, 1):
            self.run_terminal_cmd(t, cmd, ev, f"{pid}-cmd{i}")

        # ready condition + events from the cluster (truth)
        _, netjson = host(f"kubectl -n agentic-netops-intent get networks.network.kubenet.dev {net} -o json")
        try:
            nj = json.loads(netjson)
            conds = nj.get("status", {}).get("conditions", [])
            ev["ready_condition"] = next((c for c in conds if c.get("type") == "Ready"), None)
            ev["network_spec"] = nj.get("spec")
        except Exception as e:
            raise TakeFailure(f"{pid}: cannot parse Network json: {e}")
        _, events = host(f"kubectl -n agentic-netops-intent get events "
                         f"--field-selector involvedObject.name={net} -o json")
        try:
            ev["events"] = [e.get("reason") for e in json.loads(events).get("items", [])]
        except Exception:
            ev["events"] = []
        if not ev["ready_condition"] or ev["ready_condition"].get("status") != "True":
            self.shot(u, f"{pid}-NOTREADY")
            raise TakeFailure(f"{pid}: Ready condition is not True: {ev['ready_condition']}")
        return ev

    def overview(self, u):
        log("overview segment")
        u.bring_to_front()
        time.sleep(1.0)
        # the conversation gets ~45% of the height and the canvas the rest.
        # Measured, not computed from the handle's persisted value: snap to
        # the minimum (Home), then grow 32 px per ArrowUp until the
        # conversation box is tall enough.
        h = u.get_by_label("Resize conversation panel")

        def chat_height() -> float:
            v = h.get_attribute("aria-valuenow")
            if v and v.strip().lstrip("-").isdigit():
                return float(v)
            box = u.get_by_label("Agent conversation").bounding_box() or {"height": 0}
            return box["height"]

        h.focus()
        u.keyboard.press("Home")
        time.sleep(0.5)
        target = 0.45 * 1080
        for _ in range(40):
            if chat_height() >= target:
                break
            h.focus()                      # a re-render after each commit can drop focus
            u.keyboard.press("ArrowUp")
            time.sleep(0.15)
        time.sleep(0.8)
        ch = chat_height()
        self.meta["conversation_height_px"] = ch
        if ch < 0.35 * 1080:
            raise TakeFailure(f"framing[overview]: conversation panel only {ch:.0f} px tall")
        log(f"conversation panel {ch:.0f} px tall")
        # start from the reset view, then zoom OUT until the whole agent
        # topology is inside the canvas; the first take zoomed in and cut it
        rst = u.get_by_label("Reset canvas view")
        if not rst.is_disabled():
            rst.click()
            time.sleep(0.8)
        self.fit_canvas(u, "overview")
        self.shot(u, "overview-layout")
        self.frame_check(u, "overview", ["Agent topology", "Agent conversation", "Service request"])

    def run(self):
        SHOTS.mkdir(parents=True, exist_ok=True)
        pids = [p.strip() for p in self.args.prompts.split(",") if p.strip()]
        if not pids and not self.args.smoke:
            raise SystemExit("--prompts is required unless --smoke")
        for p in pids:
            if p not in PROMPTS:
                raise SystemExit(f"unknown prompt id {p}")
        self.start_xvfb()
        self.start_ttyd()
        os.environ["DISPLAY"] = ":99"

        from playwright.sync_api import sync_playwright
        with sync_playwright() as pw:
            browser = pw.chromium.launch(
                headless=False,
                args=["--no-sandbox", "--kiosk", "--window-size=1920,1080",
                      "--window-position=0,0", "--disable-dev-shm-usage",
                      "--hide-scrollbars"])
            ctx = browser.new_context(no_viewport=True)
            u = ctx.new_page()
            t = ctx.new_page()
            u.goto(UI_URL, wait_until="domcontentloaded")
            t.goto(TTYD_URL, wait_until="domcontentloaded")
            u.get_by_label("Service request").wait_for(state="visible", timeout=60_000)
            self.wait_healthy(u)
            time.sleep(4.0)  # health badge paint + suggested prompts
            # true fullscreen: page fills the 1920x1080 display, no browser chrome
            cdp = ctx.new_cdp_session(u)
            win = cdp.send("Browser.getWindowForTarget")
            cdp.send("Browser.setWindowBounds",
                     {"windowId": win["windowId"], "bounds": {"windowState": "fullscreen"}})
            time.sleep(1.5)
            log("pages loaded, supervisor healthy, fullscreen")
            t.bring_to_front()
            time.sleep(0.8)
            self.term_frame_check(t, "startup")
            u.bring_to_front()

            if self.args.smoke:
                # layout and framing only: no prompts, no recording. Proves the
                # three fixes (terminal not clipped, prompt-wait, canvas fits)
                # in about a minute instead of a 40-minute take.
                self.overview(u)
                self.fit_canvas(u, "smoke-canvas")
                self.shot(u, "smoke-console")
                self.term_type(t, "clear")
                time.sleep(1.0)
                self.term_frame_check(t, "smoke")
                smoke_ev = {"commands": {}}
                for i, cmd in enumerate([
                        "kubectl -n agentic-netops-intent get networks.network.kubenet.dev -o custom-columns=" + KCTYPE_COLS + " | head -8",
                        vlan_lookup(LEAF1, "VLAN", "130"),
                        f"docker exec {LEAF1} vtysh -c 'show evpn vni' | grep -E 'VNI|L3' | head -6"], 1):
                    self.run_terminal_cmd(t, cmd, smoke_ev, f"smoke-cmd{i}")
                self.meta["smoke"] = smoke_ev
                self.meta["finished_utc"] = now_iso()
                (BASE / f"meta-{self.take}.json").write_text(json.dumps(self.meta, indent=1))
                browser.close()
                self.cleanup()
                bad = [k for k, v in smoke_ev["commands"].items() if not v["prompt_returned_on_screen"]]
                log(f"SMOKE DONE: terminal frames {len(self.meta.get('terminal_frames', []))} ok, "
                    f"canvas frames {len(self.meta.get('canvas_frames', []))} ok, "
                    f"commands without a returned prompt: {bad or 'none'}")
                return 1 if bad else 0

            out = BASE / f"{self.take}.mp4"
            self.start_ffmpeg(out)
            rec_t0 = time.time()

            try:
                if self.args.overview > 0:
                    self.overview(u)
                    settle = self.args.overview - (time.time() - rec_t0)
                    if settle > 0:
                        time.sleep(settle)

                for pid in pids:
                    ev = self.run_prompt(u, t, pid, PROMPTS[pid], CONSTRUCT[pid])
                    # ev already recorded in meta by run_prompt (partial-safe)

                    # allocation authority after B or C (once)
                    if CONSTRUCT[pid] in ("ip-vrf", "mac-vrf") and not self.meta.get("authority_done"):
                        if self.args.sdcio == "on" or (
                                self.args.sdcio == "auto" and self.sdcio_has_configs()):
                            auth = AUTHORITY_CMDS
                        else:
                            auth = AUTHORITY_CMDS[:2]
                        self.term_type(t, "clear")
                        time.sleep(1.2)
                        self.term_frame_check(t, "authority")
                        for i, cmd in enumerate(auth, 1):
                            self.run_terminal_cmd(t, cmd, ev, f"authority-cmd{i}")
                        ev["authority"] = True
                        self.meta["authority_done"] = True
                        self.meta["sdcio_included"] = len(auth) == 3
                    else:
                        ev["authority"] = False

                    u.bring_to_front()
                    time.sleep(0.6)
                    self.clear_conversation(u)
                    if pid != pids[-1]:
                        log(f"settling gap {self.args.gap}s")
                        time.sleep(self.args.gap)

                # closing listing
                self.term_type(t, "clear")
                time.sleep(1.2)
                self.term_frame_check(t, "closing")
                self.run_terminal_cmd(t, CLOSING_CMD, {"commands": self.meta.setdefault("closing", {})},
                                      "closing")
                time.sleep(self.args.closing_hold)
            except TakeFailure as e:
                self.meta["failed"] = str(e)
                raise
            finally:
                self.stop_ffmpeg()
                self.meta["finished_utc"] = now_iso()
                self.meta["record_wall_secs"] = round(time.time() - rec_t0, 1)
                (BASE / f"meta-{self.take}.json").write_text(json.dumps(self.meta, indent=1))
                browser.close()
        self.cleanup()
        dur = [p["seconds_enter_to_deployed"] for p in self.meta["prompts"]]
        log(f"DONE take={self.take} prompts={len(dur)} enter->deployed={dur} "
            f"wall={self.meta.get('record_wall_secs')}s")
        if self.meta.get("failed"):
            print(f"TAKE FAILED: {self.meta['failed']}", file=sys.stderr)
            return 1
        return 0

    @staticmethod
    def sdcio_has_configs() -> bool:
        rc, out = host("kubectl get configs.sdc.sdcio.dev -A --no-headers 2>/dev/null | wc -l")
        return out.strip().isdigit() and int(out.strip()) > 0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--prompts", default="", help="comma separated prompt ids, e.g. A3,B3,C3 (not needed with --smoke)")
    ap.add_argument("--take", required=True)
    ap.add_argument("--gap", type=float, default=6.0)
    ap.add_argument("--cmd-wait", type=float, default=2.5)
    ap.add_argument("--overview", type=float, default=15.0)
    ap.add_argument("--closing-hold", type=float, default=5.0)
    ap.add_argument("--sdcio", choices=["auto", "on", "off"], default="auto")
    ap.add_argument("--no-record", action="store_true", help="drive without ffmpeg (dry run)")
    ap.add_argument("--smoke", action="store_true", help="layout + framing checks only; no prompts, no video")
    ap.add_argument("--stop-xvfb", action="store_true")
    args = ap.parse_args()
    if args.smoke:
        args.no_record = True
    d = Driver(args)
    rc = 0
    try:
        rc = d.run()
    except TakeFailure as e:
        log(f"TAKE FAILED: {e}")
        rc = 1
    except Exception as e:
        log(f"ERROR: {type(e).__name__}: {e}")
        d.meta["failed"] = f"{type(e).__name__}: {e}"
        (BASE / f"meta-{args.take}.json").write_text(json.dumps(d.meta, indent=1))
        rc = 2
    finally:
        d.cleanup()
    sys.exit(rc)


if __name__ == "__main__":
    main()
