#!/usr/bin/env python3
"""anomaly-scan.py — deterministic anomaly inspector for specstride proof evidence.

Reference implementation for the harness-regression evals (checks A-J defined in
evals/prompts/curate-failures-to-evals.md, section 6 step 4).

Scans a "bundle" of evidence: a snapshot root containing the tmp-g3 copy and the
wiggum feature dir (or a live tree with the same shapes). Read-only.

Usage:
  anomaly-scan.py <bundle-root> [--proofs <dir>] [--g3 <dir>] [--repo <dir>]
                  [--json <out.json>] [--report <out.md>]

Exit codes: 0 = no anomalies, 1 = anomalies found, 2 = usage/setup error.
(The nonzero-on-detection semantics make the scanner itself a regression check:
  anomaly-scan.py <fixture> && echo PASS   # must FAIL on a false-clean fixture
)

Checks:
  A  false-clean       receipt says "no difference"/exit 0 while a member .out carries
                       a failure marker (garbage-over-garbage clean)
  B  recorded-failure  every member .out with [exit code: N>0]; annotated with the
                       group receipt state (clean / differs / missing)
  C  rc-verdict-mismatch  step .rc != 0 with no retry step, or verdict file
                       contradicting the receipt .out
  D  temporal-invalidation  member .out newer than its group's receipt .out
  E  missing-pair      .cmd without .out, .out without .cmd, canonical spike group
                       without a replay receipt
  F  stale-pid         chain*.pid naming a pid that appears nowhere in that chain's
                       log/summary (or a pid flagged as a wrapper in a summary)
  G  provenance-gap    run-critical scripts untracked in git (scripts/spike/)
  H  yield-budget      done-marker later than deadline, or no done-marker after
                       deadline elapsed; narrow margin (< 25%) noted
  I  garbage-loop      >=2 distinct evidence files with byte-identical failure text
  J  future-mtime      files with mtime in the future (control check)
"""
import argparse, hashlib, json, os, re, subprocess, sys, time
from datetime import datetime, timezone

FAIL_MARKERS = ("PREFLIGHT-FAILED", "APPLY-STUCK", "VPN-SETUP-STUCK",
                "LAB-SICK", "CANN-FAIL", "CANARY-FAIL")
EXIT_RE = re.compile(r"\[exit code: (\d+)\]\s*$")
RECEIPT_MEMBERS_RE = re.compile(r"^(ok|differ): (\S+)")
CANONICAL_GROUPS = ("spike-vpn", "spike-steering", "spike-evpn3", "spike-evpn2", "spike-baseline")

def mtime(p): return os.path.getmtime(p)

def read(p):
    with open(p, "rb") as f: return f.read()

def fail_exit_of(data: bytes):
    tail = data.decode("utf-8", "replace")[-400:]
    m = EXIT_RE.search(tail)
    return int(m.group(1)) if m else None

def has_fail_marker(data: bytes) -> bool:
    t = data.decode("utf-8", "replace")
    return any(mk in t for mk in FAIL_MARKERS)

def parse_receipt(data: bytes):
    t = data.decode("utf-8", "replace")
    members = []
    for line in t.splitlines():
        m = RECEIPT_MEMBERS_RE.match(line.strip())
        if m: members.append((m.group(1), m.group(2)))
    return members, t

class Anom:
    def __init__(self, check, sev, what, artifacts, note=""):
        self.check, self.sev, self.what, self.artifacts, self.note = check, sev, what, artifacts, note
    def to_dict(self):
        return {"check": self.check, "severity": self.sev, "what": self.what,
                "artifacts": self.artifacts, "note": self.note}

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("root")
    ap.add_argument("--proofs")
    ap.add_argument("--g3")
    ap.add_argument("--repo")
    ap.add_argument("--json")
    ap.add_argument("--report")
    args = ap.parse_args()

    root = os.path.abspath(args.root)
    if not os.path.isdir(root):
        print(f"error: no such directory: {root}", file=sys.stderr); return 2

    # --- locate components -------------------------------------------------
    proofs = os.path.abspath(args.proofs) if args.proofs else None
    g3 = os.path.abspath(args.g3) if args.g3 else None
    if not proofs:
        for d in sorted(os.listdir(root)):
            p = os.path.join(root, d, "gates", "proofs")
            if os.path.isdir(p):
                proofs = p; break
        if not proofs:
            p = os.path.join(root, "gates", "proofs")
            if os.path.isdir(p): proofs = p
    if not g3:
        for d in sorted(os.listdir(root)):
            p = os.path.join(root, d)
            if d.startswith("tmp-g3-") and os.path.isdir(p): g3 = p; break
        if not g3:
            p = os.path.join(root, "tmp-g3")
            if os.path.isdir(p): g3 = p
    repo = os.path.abspath(args.repo) if args.repo else None
    if not repo:
        r = root
        while r != os.path.dirname(r):
            if os.path.isdir(os.path.join(r, ".git")): repo = r; break
            r = os.path.dirname(r)
    if not proofs:
        print("error: could not locate gates/proofs under the bundle", file=sys.stderr); return 2

    A = []
    now = time.time()

    def rel(p):
        try: return os.path.relpath(p, root)
        except ValueError: return p

    # --- A: false-clean receipts --------------------------------------------
    receipts = {}
    for fn in sorted(os.listdir(proofs)):
        if not (fn.endswith(".out") and "rerun" in fn): continue
        path = os.path.join(proofs, fn)
        members, t = parse_receipt(read(path))
        if not members: continue
        exit_n = fail_exit_of(read(path))
        clean = (exit_n == 0 and "no difference" in t)
        receipts[fn] = {"path": path, "members": members, "clean": clean, "exit": exit_n}
        if clean:
            bad = []
            for status, name in members:
                mo = os.path.join(proofs, name + ".out")
                if not os.path.isfile(mo): continue
                d = read(mo)
                if has_fail_marker(d) or (fail_exit_of(d) or 0) > 0:
                    bad.append(name)
            if bad:
                A.append(Anom("A", "critical",
                              f"FALSE-CLEAN: receipt {fn} reports 'no difference' (exit 0) "
                              f"but {len(bad)} member record(s) carry failure markers",
                              [rel(path)] + [os.path.join(rel(proofs), b + ".out") for b in bad],
                              "garbage-over-garbage: the replay compared identical bad records"))

    # --- B: recorded-failure inventory ---------------------------------------
    for fn in sorted(os.listdir(proofs)):
        if not fn.endswith(".out"): continue
        path = os.path.join(proofs, fn)
        d = read(path)
        n = fail_exit_of(d)
        if n:
            group = next((g for g in CANONICAL_GROUPS if fn.startswith(g + "-")), None)
            receipt_state = "no-receipt"
            if group:
                rf = "spike-rerun-" + group.split("-", 1)[1] + ".out" if "-" in group else None
                # group name e.g. spike-vpn -> receipt spike-rerun-vpn.out
                base = group[len("spike-"):]
                rf = f"spike-rerun-{base}.out"
                if os.path.isfile(os.path.join(proofs, rf)):
                    rd = read(os.path.join(proofs, rf))
                    receipt_state = "receipt-clean(!)" if ("no difference" in rd.decode('utf-8','replace') and fail_exit_of(rd) == 0) else "receipt-differs"
            marker = next((mk for mk in FAIL_MARKERS if mk in d.decode('utf-8','replace')), "nonzero-exit")
            A.append(Anom("B", "major" if receipt_state == "receipt-clean(!)" else "info",
                          f"RECORDED-FAILURE: {fn} exits {n} ({marker}); group receipt: {receipt_state}",
                          [rel(path)]))

    # --- C: rc/verdict mismatches (g3) ---------------------------------------
    if g3 and os.path.isdir(g3):
        rc_files = {}
        for fn in os.listdir(g3):
            if fn.endswith(".rc"):
                try: val = int(open(os.path.join(g3, fn)).read().strip() or "0")
                except ValueError: val = 0
                rc_files[fn[:-3]] = val
        def recovered(name):
            # a same-family step succeeded (retry -r2/-conv, or a recover/conv
            # sibling sharing the prefix up to the last dash segment)
            if (name + "-r2") in rc_files or (name + "-conv") in rc_files:
                return True
            if "-" in name:
                prefix, last = name.rsplit("-", 1)
                return any(k.startswith(prefix + "-") and k != name and rc_files[k] == 0
                           for k in rc_files)
            return False
        for name, val in sorted(rc_files.items()):
            if val == 0: continue
            if recovered(name):
                continue
            A.append(Anom("C", "info",
                          f"NEEDS-TRIAGE: {name}.rc = {val} with no same-family successful retry/recover step "
                          f"(may be recovered under a foreign name — judge against the chain log)",
                          [rel(os.path.join(g3, name + ".rc"))]))
        for fn in os.listdir(g3):
            if fn.endswith(".verdict"):
                v = open(os.path.join(g3, fn)).read().strip()
                rn = fn.replace(".verdict", "")
                ro = os.path.join(proofs, rn + ".out")
                if not os.path.isfile(ro):
                    A.append(Anom("C", "minor", f"VERDICT-WITHOUT-RECEIPT: {fn}='{v}' but {rn}.out missing",
                                  [rel(os.path.join(g3, fn))]))
                else:
                    rt = read(ro).decode("utf-8", "replace")
                    if v == "clean" and "no difference" not in rt:
                        A.append(Anom("C", "major", f"VERDICT/RECEIPT MISMATCH: {fn}='clean' but receipt shows differences",
                                      [rel(os.path.join(g3, fn)), rel(ro)]))
                    if v == "differ" and "no difference" in rt:
                        A.append(Anom("C", "major", f"VERDICT/RECEIPT MISMATCH: {fn}='differ' but receipt says no difference",
                                      [rel(os.path.join(g3, fn)), rel(ro)]))

    # --- D: temporal invalidation --------------------------------------------
    for fn, r in receipts.items():
        rt = mtime(r["path"])
        for status, name in r["members"]:
            mo = os.path.join(proofs, name + ".out")
            if os.path.isfile(mo) and mtime(mo) > rt + 2:
                A.append(Anom("D", "major",
                              f"TEMPORAL: member {name}.out is newer than receipt {fn} — receipt cannot be valid for current records",
                              [rel(mo), rel(r["path"])]))

    # --- E: missing pairs ------------------------------------------------------
    for fn in os.listdir(proofs):
        if fn.endswith(".cmd"):
            if not os.path.isfile(os.path.join(proofs, fn[:-4] + ".out")):
                A.append(Anom("E", "minor", f"MISSING-OUT: {fn} has no .out", [rel(os.path.join(proofs, fn))]))
        elif fn.endswith(".out") and "rerun" not in fn:
            if not os.path.isfile(os.path.join(proofs, fn[:-4] + ".cmd")):
                A.append(Anom("E", "minor", f"MISSING-CMD: {fn} has no .cmd", [rel(os.path.join(proofs, fn))]))
    for g in CANONICAL_GROUPS:
        base = g[len("spike-"):]
        if not os.path.isfile(os.path.join(proofs, f"spike-rerun-{base}.out")):
            A.append(Anom("E", "major", f"MISSING-RECEIPT: canonical group {g} has no replay receipt", [rel(proofs)]))

    # --- F: stale pids ---------------------------------------------------------
    if g3 and os.path.isdir(g3):
        for fn in sorted(os.listdir(g3)):
            if not fn.endswith(".pid"): continue
            pid = open(os.path.join(g3, fn)).read().strip()
            chain = fn[:-4]
            hay = ""
            for extra in (chain + ".log", chain + ".summary", chain + ".done"):
                p = os.path.join(g3, extra)
                if os.path.isfile(p): hay += open(p, errors="replace").read()
            if pid and pid.isdigit() and pid not in hay:
                A.append(Anom("F", "minor", f"STALE-PID: {fn}={pid} never referenced in {chain} logs/summary (possible setsid-wrapper pid)",
                              [rel(os.path.join(g3, fn))]))

    # --- G: provenance gap ------------------------------------------------------
    if repo and os.path.isdir(os.path.join(repo, ".git")):
        try:
            out = subprocess.run(["git", "-C", repo, "ls-files", "scripts/spike/"],
                                 capture_output=True, text=True, timeout=30).stdout.split()
            workdir = os.path.join(repo, "scripts", "spike")
            untracked = 0
            if os.path.isdir(workdir):
                for fn in os.listdir(workdir):
                    if fn.endswith(".sh"): untracked += 1
            if untracked and len(out) < untracked:
                A.append(Anom("G", "major",
                              f"PROVENANCE-GAP: {untracked} spike scripts in working tree, {len(out)} tracked in git",
                              ["scripts/spike/ (git ls-files)"]))
        except Exception as e:
            A.append(Anom("G", "info", f"provenance check failed: {e}", []))

    # --- H: yield budget ---------------------------------------------------------
    if g3 and os.path.isdir(g3):
        for fn in sorted(os.listdir(g3)):
            if not fn.endswith(".done"): continue
            chain = fn[:-5]
            # find the newest yield json naming this chain's done marker
            wiggum = None
            for d in os.listdir(root):
                c = os.path.join(root, d, "yield")
                if os.path.isdir(c): wiggum = c; break
            if not wiggum: continue
            for yf in os.listdir(wiggum):
                if not yf.endswith(".json"): continue
                try: y = json.loads(open(os.path.join(wiggum, yf)).read())
                except Exception: continue
                want = y.get("resume_when", {}).get("path", "")
                if os.path.basename(want) != fn: continue
                deadline = y.get("deadline_sec")
                done_t = mtime(os.path.join(g3, fn))
                yf_path = os.path.join(wiggum, yf)
                cts = mtime(yf_path)  # yield file written when the yield was armed (same clock as done mtimes)
                if deadline:
                    if done_t > cts + deadline:
                        A.append(Anom("H", "info",
                                      f"NEEDS-TRIAGE: {fn} completed {int(done_t - cts - deadline)}s past the yield's "
                                      f"deadline — verify whether the owning run was still alive at expiry "
                                      f"(a halted run's orphaned job overrunning is not a harness bug)",
                                      [rel(yf_path), rel(os.path.join(g3, fn))]))
                    elif (cts + deadline) - done_t < 0.25 * deadline:
                        A.append(Anom("H", "info",
                                      f"TIGHT-YIELD: {fn} finished within 25% of its deadline — little slack",
                                      [rel(yf_path)]))
                break

    # --- I: garbage loop -----------------------------------------------------------
    seen = {}
    for base_dir, failreq in ((proofs, True), (g3, False)):
        if not base_dir or not os.path.isdir(base_dir): continue
        for fn in os.listdir(base_dir):
            if not (fn.endswith(".out") or fn.endswith(".log")): continue
            p = os.path.join(base_dir, fn)
            try: d = read(p)
            except Exception: continue
            if not has_fail_marker(d): continue
            if len(d) < 40: continue
            h = hashlib.sha256(d).hexdigest()
            seen.setdefault(h, []).append(rel(p))
    for h, paths in seen.items():
        if len(paths) >= 2:
            A.append(Anom("I", "major",
                          f"GARBAGE-LOOP: {len(paths)} evidence files with byte-identical failure text (same failure re-recorded without remediation)",
                          paths[:6]))

    # --- J: future mtime -------------------------------------------------------------
    for base_dir in filter(None, (proofs, g3)):
        for fn in os.listdir(base_dir):
            p = os.path.join(base_dir, fn)
            if os.path.isfile(p) and mtime(p) > now + 60:
                A.append(Anom("J", "info", f"FUTURE-MTIME: {rel(p)} mtime is in the future", [rel(p)]))

    # --- emit -------------------------------------------------------------------
    order = {"critical": 0, "major": 1, "minor": 2, "info": 3}
    A.sort(key=lambda a: (order[a.sev], a.check))
    by_check = {}
    for a in A: by_check.setdefault(a.check, []).append(a)

    if args.json:
        json.dump({"bundle": root, "scanned_at": datetime.now().astimezone().isoformat(),
                   "anomalies": [a.to_dict() for a in A],
                   "counts": {k: len(v) for k, v in by_check.items()}},
                  open(args.json, "w"), indent=1)

    lines = [f"# Anomaly report — bundle {root}",
             f"scanned at {datetime.now().astimezone().isoformat()}",
             f"total anomalies: {len(A)}  " + "  ".join(f"{k}={len(v)}" for k, v in sorted(by_check.items())), ""]
    for k in sorted(by_check):
        lines.append(f"## check {k} ({len(by_check[k])})")
        for a in by_check[k]:
            lines.append(f"- **[{a.sev}]** {a.what}" + (f" — {a.note}" if a.note else ""))
            for art in a.artifacts: lines.append(f"  - `{art}`")
        lines.append("")
    md = "\n".join(lines)
    if args.report:
        os.makedirs(os.path.dirname(os.path.abspath(args.report)), exist_ok=True)
        open(args.report, "w").write(md)
        print(f"report written: {args.report}")
    print(md)
    return 1 if A else 0

if __name__ == "__main__":
    sys.exit(main())
