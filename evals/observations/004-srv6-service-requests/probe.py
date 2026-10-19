#!/usr/bin/env python3
"""Read-only observer probe for a specstride / mixture-of-loops run and the lab under it.

Prints one JSON object: loop state, detached-chain state, and per-layer
infrastructure health. It never writes outside its own stdout, never signals a
process, and on the devices runs only reads (systemctl is-active/show, redis
--scan, ip link show, vtysh show, tail of syslog). It deliberately does NOT
reuse the chain's canary or ensure-fabric probe: both of those write to the lab.

`key` is the discrete state an observer should wake on; `alarms` lists the
conditions that mean "the loop is iterating on a sick or doomed substrate".
"""
import glob, json, os, re, shlex, subprocess, sys, time

REPO = "/root/agentic-netops"
FEATURE = "004-srv6-service-requests"
F = f"{REPO}/.wiggum/features/{FEATURE}"
RUN = f"{REPO}/.mixture-of-loops/{FEATURE}/.mixture-of-loops/runs/{FEATURE}"
G3 = "/tmp/g3"
NODES = {"leaf01": "172.31.0.21", "leaf02": "172.31.0.22",
         "spine01": "172.31.0.11", "spine02": "172.31.0.12"}
BGP_EXPECT = {"leaf01": 2, "leaf02": 2, "spine01": 3, "spine02": 3}  # peers per family
# The factory seed that scripts/spike/seed-restore.sh restores is deliberately
# partial and asymmetric (see that script's header): these Established counts,
# with no service VRF configured anywhere, are the HEALTHY seed, not a fault.
BGP_SEED = {"leaf01": 3, "leaf02": 2, "spine01": 1, "spine02": 4}
YIELD_MAX_PER_ATTEMPT = 4      # SPECSTRIDE_YIELD_MAX_PER_ATTEMPT default
STEP_STALL_SEC = 1800          # a chain step silent this long is suspicious
DEADLINE_WARN_SEC = 1500


def sh(cmd, timeout=25):
    try:
        return subprocess.run(cmd, shell=True, capture_output=True, text=True,
                              timeout=timeout).stdout.strip()
    except subprocess.TimeoutExpired:
        return "TIMEOUT"


def alive(pid):
    return bool(pid) and os.path.exists(f"/proc/{pid}")


def read(path, default=""):
    try:
        with open(path, errors="replace") as fh:
            return fh.read()
    except OSError:
        return default


def loop_state(now):
    log = read(f"{REPO}/.wiggum/run.log")
    events = [json.loads(l) for l in read(f"{REPO}/.wiggum/events.jsonl").splitlines() if l.startswith("{")]
    state = json.loads(read(f"{RUN}/state.json", "{}") or "{}")
    orch = sh("pgrep -of 'specstride/[o]rchestrator.sh .*--feature %s'" % FEATURE)
    sup = sh("pgrep -of '[r]untime.py --contract .*%s'" % FEATURE)
    # Owner relaunch outside the MoL supervisor (14 Oct): the wrapper script
    # stands in for the supervisor and its exit line for the digest.
    direct = read(f"{REPO}/.mixture-of-loops/{FEATURE}/owner-resume-20261014.log").rpartition("[OWNER-RESUME] ")
    if direct[1]:
        sup = sup or sh("pgrep -of 'observations/%s/[d]irect-resume.sh'" % FEATURE)
    phases = re.findall(r"^===== PHASE (\d+) ", log, re.M)
    out = {
        "supervisor_alive": alive(sup), "orchestrator_alive": alive(orch),
        "state_json": state.get("state"),
        "run_id": os.path.basename(os.path.dirname(os.path.realpath(f"{REPO}/.wiggum/run.log"))),
        "phase": int(phases[-1]) if phases else None,
        "gates_approved": sorted(int(re.search(r"GATE(\d+)", p).group(1))
                                 for p in glob.glob(f"{F}/gates/GATE*-APPROVED")),
        "evidence": sorted(os.path.basename(p) for p in glob.glob(f"{F}/gates/GATE*-EVIDENCE.md")),
        "feedback": sorted(os.path.basename(p) for p in glob.glob(f"{F}/gates/GATE*-FEEDBACK.md")),
        "verdict_files": len(glob.glob(f"{F}/verdicts/*")),
        "pass_headers": len(re.findall(r"^----- proposer pass ", log, re.M)),
        "progress_passes": len(re.findall(r"^## Pass ", read(f"{F}/PROGRESS.md"), re.M)),
        "halt": (re.findall(r"^(?:>>>|# HALT|# DONE).*$", log, re.M) or [None])[-1],
        "digest": ((re.findall(r"^\[OWNER-RESUME-EXIT\].*$", direct[2], re.M) or [None])[-1] if direct[1] else
                   (re.findall(r"^\[DIGEST\].*$", read(f"{RUN}/launcher.log").rpartition("\n[RUN] ")[2], re.M) or [None])[-1]),
        "last_event": events[-1]["event"] if events else None,
        "last_event_age": int(now - float(events[-1]["ts"])) if events else None,
        "ledger_failures": sum(1 for l in read(f"{F}/failure-ledger.jsonl").splitlines() if '"failure"' in l),
    }
    # events.jsonl carries no tool calls in this capture mode, so "is the proposer
    # doing anything" is read from its model process: does it have a child running?
    dsh = sh("pgrep -n -P $(pgrep -n -f 'specstride/[p]roposer.sh .*%s' || echo 1) -f 'dsh --profile headless'" % FEATURE)
    out["proposer_session"] = alive(dsh)
    out["proposer_tool_running"] = bool(dsh and sh(f"pgrep -P {dsh} bash"))
    yields = [e for e in events if e["event"] == "pass_yield"]
    # a wait ends with yield_resume, or with yield_ended_early (job died / unhealthy)
    resumes = [e for e in events if e["event"] in ("yield_resume", "yield_ended_early")]
    out["yields_this_run"] = len(yields)
    waiting = len(yields) > len(resumes)
    out["waiting_on_yield"] = waiting
    if waiting:
        cands = sorted(glob.glob(f"{F}/yield/phase{out['phase']}-attempt*-{out['run_id']}.json"), key=os.path.getmtime)
        yf = cands[-1] if cands else ""
        try:
            y = json.loads(read(yf))
        except ValueError:
            y = {}
        starts = [e for e in events if e["event"] == "yield_job_start"]
        pid = (y.get("job") or {}).get("pid") or (starts[-1].get("pid") if starts else None)
        # the proposer rewrites the yield file atomically, but a read can still land on
        # an old or half-written copy; no deadline_sec means "unknown", not "expired"
        left = (int(float(yields[-1]["ts"]) + int(y["deadline_sec"]) - now)
                if y.get("deadline_sec") else None)
        # the job exits a moment before its rc file lands; a dead job whose rc file
        # exists (written after this yield started) is "done", not "dead"
        rw = y.get("resume_when") or {}
        rcs = [rw["path"]] if rw.get("path") else glob.glob(
            f"{F}/yield-jobs/phase{out['phase']}-attempt*-{out['run_id']}-yield*.rc")
        rc_done = any(os.path.exists(r) and os.path.getmtime(r) >= float(yields[-1]["ts"]) - 5
                      for r in rcs)
        # yield_index is the harness's own per-attempt counter (proposer.sh YIELD_INDEX);
        # len(yields) counts the whole run and raised a false last-yield alarm (O-111)
        idx = int(yields[-1].get("yield_index") or len(yields))
        out["yield"] = {"index": idx, "max": YIELD_MAX_PER_ATTEMPT,
                        "kind": rw.get("kind"), "rc_done": rc_done,
                        "job_pid": pid, "job_alive": alive(pid), "deadline_left_sec": left}
    return out


def chain_state(now):
    logs = sorted(glob.glob(f"{G3}/chain*.log"), key=os.path.getmtime)
    # A chain the harness launched itself (yield job mode "launch") logs under
    # yield-jobs/, not /tmp/g3: find it by its process.
    live = sh(f"pgrep -nf '^/bin/bash {G3}/[c]hain[0-9]+\\.sh'")
    live_name = os.path.basename(sh(f"tr '\\0' ' ' < /proc/{live}/cmdline").split()[-1])[:-3] if live else None
    jobs = sorted(glob.glob(f"{F}/yield-jobs/*.log"), key=os.path.getmtime)
    if live_name and not os.path.exists(f"{G3}/{live_name}.log") and jobs:
        log, name = jobs[-1], live_name
    elif logs:
        log = logs[-1]
        name = os.path.basename(log)[:-4]
    else:
        return {}
    marks = re.findall(r"^##### (\d\d:\d\d:\d\d) (.*)$", read(log), re.M)
    rcs = [m[1] for m in marks if m[1].startswith("RC ")]
    out = {
        "name": name, "pid": sh(f"pgrep -of '{G3}/[c]{name[1:]}.sh'") or None,
        "last_mark": " ".join(marks[-1])[:140] if marks else None,
        "last_mark_age": int(now - os.path.getmtime(log)),
        "steps_rc0": sum(1 for r in rcs if r.endswith("=0")),
        "steps_rc_nonzero": sum(1 for r in rcs if not r.endswith("=0")),
        "done": read(f"{G3}/{name}.done").strip()[:120] or None,
        "verdicts": {os.path.basename(p)[len("spike-rerun-"):-len(".verdict")]:
                     f"{read(p).strip()}@{time.strftime('%H:%M', time.localtime(os.path.getmtime(p)))}"
                     for p in sorted(glob.glob(f"{G3}/spike-rerun-*.verdict"))},
    }
    out["alive"] = alive(out["pid"])
    if out["alive"]:
        out["leaf_cmd"] = sh(f"pstree -a {out['pid']} | tail -3 | tr -s ' ' | tr '\\n' ';'")[:200]
    return out


GUEST = r'''
for u in database swss syncd bgp; do echo "unit $u $(systemctl is-active $u) $(systemctl show -p NRestarts --value $u)"; done
echo "sup $(sudo docker exec swss supervisorctl status 2>/dev/null | grep -cE 'FATAL|BACKOFF|STOPPED|UNKNOWN')"
echo "cfgvrf $(sudo redis-cli -n 4 --scan --pattern 'VRF|*' | wc -l)"
echo "applvrf $(sudo redis-cli -n 0 --scan --pattern 'VRF_TABLE*' | wc -l)"
echo "kvrf $(ip -br link show type vrf | wc -l)"
echo "refspam $(sudo tail -2000 /var/log/syslog | grep -c 'still referenced')"
echo "bgpest $(vtysh -c 'show bgp summary json' 2>/dev/null | tr -d ' \n' | grep -o '"state":"Established"' | wc -l)"
'''


# sonic-vs: SONiC runs directly in the clab container (no qemu guest, no systemd units);
# map the supervisord programs onto the same four "units" the sonic-vm guests report.
VS_GUEST = r'''
st=$(supervisorctl status 2>/dev/null)
u() { echo "$st" | awk -v p="$2" '$1==p{print $2}' | grep -q RUNNING && echo "unit $1 active 0" || echo "unit $1 inactive 0"; }
u database redis-server; u swss orchagent; u syncd syncd; u bgp bgpd
echo "sup $(echo "$st" | grep -wE 'orchagent|vrfmgrd|intfmgrd|portsyncd|zebra|bgpd' | grep -vc RUNNING)"
echo "cfgvrf $(redis-cli -n 4 --scan --pattern 'VRF|*' | wc -l)"
echo "applvrf $(redis-cli -n 0 --scan --pattern 'VRF_TABLE*' | wc -l)"
echo "kvrf $(ip -br link show type vrf | wc -l)"
echo "refspam 0"
echo "bgpest $(vtysh -c 'show bgp summary json' 2>/dev/null | tr -d ' \n' | grep -o '"state":"Established"' | wc -l)"
'''
BGP_EXPECT_VS = {"leaf01": 2, "leaf02": 2, "spine01": 2, "spine02": 2}  # peers per family (no spine-spine)


def lab_profile():
    img = sh("timeout 15 docker inspect -f '{{.Config.Image}}' clab-agentic-netops-fabric-leaf01 2>/dev/null")
    return "sonic-vs" if "sonic-vs" in img else "sonic-vm"


def node_state(ip, name=None, profile="sonic-vm"):
    if profile == "sonic-vs":
        raw = sh(f"timeout 30 docker exec clab-agentic-netops-fabric-{name} sh -c {shlex.quote(VS_GUEST)} </dev/null",
                 timeout=40)
    else:
        raw = sh("sshpass -p admin ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null "
                 f"-o ConnectTimeout=8 -o LogLevel=ERROR admin@{ip} {shlex.quote(GUEST)} </dev/null", timeout=40)
    if not raw or raw == "TIMEOUT":
        return {"reachable": False}
    n = {"reachable": True, "units": {}, "restarts": {}}
    for line in raw.splitlines():
        p = line.split()
        if p[0] == "unit" and len(p) == 4:
            n["units"][p[1]] = p[2]
            n["restarts"][p[1]] = int(p[3]) if p[3].isdigit() else -1
        elif len(p) == 2 and p[1].isdigit():
            n[p[0]] = int(p[1])
    # the "orchagent wedge": intent in CONFIG_DB that never reaches APPL_DB / kernel
    n["wedged"] = n.get("cfgvrf", 0) > 0 and (n.get("applvrf", 0) == 0 or n.get("kvrf", 0) == 0)
    return n


def infra_state():
    dpid = sh("pgrep -o dockerd")
    profile = lab_profile()
    out = {
        "profile": profile,
        "load1": float(read("/proc/loadavg").split()[0]),
        "mem_avail_gb": int(re.search(r"MemAvailable:\s+(\d+)", read("/proc/meminfo")).group(1)) // 1048576,
        "dockerd_fds": len(os.listdir(f"/proc/{dpid}/fd")) if dpid else None,
        "docker_ps": sh("timeout 15 docker ps --format '{{.Names}} {{.Status}}' | grep -c '^clab-agentic-netops-fabric-'"),
        "qemu": int(sh("pgrep -xc qemu-system-x86") or 0),
        "kind_nodes_ready": sh("timeout 15 kubectl get nodes --no-headers 2>/dev/null | grep -cw Ready"),
        "kind_bad_pods": sh("timeout 15 kubectl get pods -n agentic-netops-system -n agentic-netops-agents "
                            "--no-headers 2>/dev/null | grep -vcE 'Running|Completed'"),
        "nodes": {name: node_state(ip, name, profile) for name, ip in NODES.items()},
    }
    return out


def fabric_state(infra):
    n = infra["nodes"]
    if all(v.get("reachable") for v in n.values()) and all(
            v.get("cfgvrf", 0) == 0 and v.get("bgpest") == BGP_SEED[k] for k, v in n.items()):
        return "seed"
    return "as-built"


def alarms(loop, chain, infra):
    a = []
    seed = infra["fabric_state"] == "seed"
    vs = infra.get("profile") == "sonic-vs"
    expect = BGP_EXPECT_VS if vs else BGP_EXPECT
    for name, n in infra["nodes"].items():
        if not n.get("reachable"):
            a.append(f"infra:{name}:unreachable"); continue
        for u, s in n["units"].items():
            if s != "active":
                a.append(f"infra:{name}:{u}={s}")
        if n.get("sup"):
            a.append(f"infra:{name}:swss-daemon-down")
        if n["wedged"]:
            a.append(f"infra:{name}:vrf-wedge")
        if not seed and n["units"].get("bgp") == "active" and n.get("bgpest", 0) < 2 * expect[name]:
            a.append(f"infra:{name}:bgp-sessions={n.get('bgpest', 0)}/{2 * expect[name]}")
    if infra["docker_ps"] in ("TIMEOUT", ""):
        a.append("infra:host:docker-cli-hang")
    elif infra["docker_ps"] != "8":
        a.append(f"infra:host:clab-containers={infra['docker_ps']}")
    if infra["qemu"] != (0 if vs else 4):
        a.append(f"infra:host:qemu={infra['qemu']}")
    if (infra["dockerd_fds"] or 0) > 400000:
        a.append("infra:host:dockerd-fd-ceiling")
    y = loop.get("yield")
    if y:
        if y["index"] >= y["max"]:
            a.append("loop:last-yield-of-attempt")
        if y["deadline_left_sec"] is not None and y["deadline_left_sec"] < DEADLINE_WARN_SEC:
            a.append("loop:yield-deadline-near")
        if y["kind"] != "pid" and y["job_pid"] and not y["job_alive"] and not y.get("rc_done"):
            a.append("loop:yield-job-dead-predicate-unsatisfied")
    if chain.get("alive") and chain.get("last_mark_age", 0) > STEP_STALL_SEC:
        a.append("chain:step-stall")
    if any(v.startswith("differ") for v in chain.get("verdicts", {}).values()):
        a.append("chain:receipt-differ")
    if chain.get("done") and "sick" in chain["done"].lower():
        a.append("chain:lab-sick")
    if not loop["supervisor_alive"] and loop["state_json"] == "running":
        a.append("loop:dead-without-digest")
    # the core condition this observer exists for
    if chain.get("alive") and any(x.startswith("infra:") for x in a):
        a.append("CROSS:chain-running-on-sick-lab")
    return sorted(a)


def main():
    now = time.time()
    loop, chain, infra = loop_state(now), chain_state(now), infra_state()
    infra["fabric_state"] = fabric_state(infra)
    al = alarms(loop, chain, infra)
    restarts = {n: v.get("restarts") for n, v in infra["nodes"].items()}
    key = json.dumps([loop["supervisor_alive"], loop["orchestrator_alive"], loop["phase"],
                      loop["gates_approved"], loop["evidence"], loop["feedback"], loop["verdict_files"],
                      loop["pass_headers"], loop["yields_this_run"], loop["waiting_on_yield"],
                      loop["halt"], loop["digest"], chain.get("name"), chain.get("alive"),
                      chain.get("done"), chain.get("verdicts"), al], sort_keys=True)
    if "--health" in sys.argv[1:]:
        # specstride --health-cmd: exit 0 healthy, else one line per infra fault.
        bad = [a for a in al if a.startswith("infra:")]
        for a in bad:
            print(a)
        if bad:
            print("fabric_state=%s (seed = factory-partial sessions expected)" % infra["fabric_state"])
        return 1 if bad else 0
    print(json.dumps({"ts": int(now), "time": time.strftime("%Y-%m-%dT%H:%M:%S%z", time.localtime(now)),
                      "alarms": al, "loop": loop, "chain": chain, "infra": infra,
                      "restarts": restarts, "key": key}))


if __name__ == "__main__":
    sys.exit(main())
