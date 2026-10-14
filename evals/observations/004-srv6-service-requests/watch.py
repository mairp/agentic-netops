#!/usr/bin/env python3
"""Quiet watcher: samples probe.py every INTERVAL seconds into timeline.jsonl and
exits ONLY when the owner has something to decide. On exit it prints a few
lines and leaves `wake-pending` (the reasons); the owner deletes that file when
it has handled the wake. Read-only towards the loop and the lab."""
import json, os, re, subprocess, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
PROGRESS = "/root/agentic-netops/.wiggum/features/004-srv6-service-requests/PROGRESS.md"
INTERVAL = int(os.environ.get("INTERVAL", 300))
INFRA_GRACE = 2400      # sick lab with no chain: give the proposer this long to heal it
CROSS_REPEAT = 1800     # sick lab under a live chain: re-wake this often while it lasts
SOFT_SAMPLES = 5        # ~25 min of session shortfall inside one chain step
IDLE_PASS = 1500        # proposer mid-pass with no event this long
QUIET_MAX = int(os.environ.get("QUIET_MAX", 10800))


def sample():
    out = subprocess.run([sys.executable, f"{HERE}/probe.py"], capture_output=True, text=True, timeout=300).stdout
    d = json.loads(out)
    try:
        d["owner_reports"] = len(re.findall(r"OWNER-REPORT", open(PROGRESS, errors="replace").read()))
    except OSError:
        d["owner_reports"] = 0
    with open(f"{HERE}/timeline.jsonl", "a") as fh:
        fh.write(json.dumps(d) + "\n")
    return d


def main():
    start = time.time()
    prev = sample()
    infra_since = start if any(a.startswith("infra:") for a in prev["alarms"]) else None
    cross_n, cross_last = 0, 0.0
    seen_once = set(a for a in prev["alarms"] if a.startswith(("chain:step", "chain:lab-sick", "loop:")))
    idle_woken, quiet_n = False, 0
    prev_hard = set()
    while True:
        time.sleep(INTERVAL)
        try:
            d = sample()
        except Exception as e:           # one failed probe is not an event
            print("probe error:", e, file=sys.stderr)
            continue
        now = time.time()
        l, pl, c, pc, al = d["loop"], prev["loop"], d["chain"], prev["chain"], d["alarms"]
        why = []
        if l["digest"] or not l["supervisor_alive"]:
            why.append(f"TERMINAL digest={l['digest']} halt={l['halt']}")
        for k in ("gates_approved", "evidence", "feedback", "verdict_files"):
            if l[k] != pl[k]:
                why.append(f"gate: {k} {pl[k]} -> {l[k]}")
        if l["pass_headers"] > pl["pass_headers"]:
            why.append(f"new pass ({l['pass_headers']}); OWNER-REPORT count {prev['owner_reports']} -> {d['owner_reports']}")
        elif d["owner_reports"] > prev["owner_reports"]:
            why.append("new OWNER-REPORT in PROGRESS.md")
        if l["yields_this_run"] > pl["yields_this_run"]:
            why.append(f"yield armed #{l['yields_this_run']}/4: {l.get('yield')}")
        if c.get("name") != pc.get("name"):
            why.append(f"new chain {c.get('name')}: check it has a health gate")
        infra = [a for a in al if a.startswith("infra:")]
        # Under a live chain a step may legitimately break things while it runs
        # (a replay rebuilds the underlay, seed-restore restarts services). So a
        # fault inside ONE step counts only when it outlasts SOFT_SAMPLES samples
        # of that step. A hard fault (unit down, wedge, unreachable, host layer)
        # that survives into the NEXT step counts at once: the chain's own gate
        # should have stopped there and did not.
        hard = [a for a in infra if "bgp-sessions" not in a]
        if c.get("alive") and infra:
            same_step = c.get("last_mark") == pc.get("last_mark")
            crossed = not same_step and bool(set(hard) & prev_hard)
            cross_n = cross_n + 1 if same_step or crossed else 1
            if (crossed or cross_n >= SOFT_SAMPLES) and now - cross_last > CROSS_REPEAT:
                why.append(f"SICK LAB UNDER LIVE CHAIN ({'fault crossed a step boundary' if crossed else str(cross_n) + ' samples in one step'}): {infra}")
                cross_last = now
        else:
            cross_n = 0
        prev_hard = set(hard) if c.get("alive") else set()
        if infra and not c.get("alive"):
            infra_since = infra_since or now
            if now - infra_since > INFRA_GRACE:
                why.append(f"lab still sick after {int(now - infra_since)}s with no chain: {infra}")
                infra_since = now
        elif not infra:
            infra_since = None
        for a in al:
            if a.startswith(("chain:step", "chain:lab-sick", "loop:")) and a not in seen_once:
                seen_once.add(a)
                why.append(a)
        # A silent proposer session is not a wake reason: the harness's own
        # watchdog ends idle or stalled passes, and a new pass header wakes us.
        if not why and now - start > QUIET_MAX:
            why.append("quiet check-in")
        if why:
            y = l.get("yield") or {}
            print("WAKE:", " | ".join(why))
            print(f"{d['time']} phase={l['phase']} gates={l['gates_approved']} passes={l['pass_headers']} "
                  f"yields={l['yields_this_run']} waiting={l['waiting_on_yield']} deadline_left={y.get('deadline_left_sec')}")
            print(f"chain={c.get('name')} alive={c.get('alive')} mark=[{c.get('last_mark')}] verdicts={c.get('verdicts')}")
            print("alarms:", al)
            with open(f"{HERE}/wake-pending", "w") as fh:
                fh.write(d["time"] + " " + " | ".join(why) + "\n")
            return
        prev = d


main()
