#!/usr/bin/env python3
"""reconcile.py — merge two worker incident/case sets, flagging disagreement.

Usage:
  reconcile.py --a <agent-qwen38 dir> --b <agent-glm53 dir> --out <canonical dir>

Produces:
  <out>/incidents.jsonl   — union; each record gets "source": ["A","B"] or one
  <out>/cases.jsonl       — union; canonical ids renumbered EVAL-004-NNN
  <out>/disagreement.md   — incidents/cases present on only one side (these are
                            anomaly signals: two independent curators should
                            converge; a one-sided incident is either a real miss
                            by the other side or an over-report)

Matching is coarse on purpose (class + normalized title word overlap); the
supervising agent reviews the disagreement report and adjusts sources by hand
before the canonical files are considered final.
"""
import argparse, json, os, re, sys

def norm(s):
    return re.sub(r"[^a-z0-9 ]+", "", s.lower()).split()

def overlap(x, y):
    wx, wy = set(norm(x)), set(norm(y))
    if not wx or not wy: return 0.0
    return len(wx & wy) / min(len(wx), len(wy))

def load(path):
    out = []
    if path and os.path.isfile(path):
        for line in open(path):
            line = line.strip()
            if line:
                try: out.append(json.loads(line))
                except json.JSONDecodeError as e:
                    print(f"warning: skipping bad JSONL line in {path}: {e}", file=sys.stderr)
    return out

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--a", required=True)
    ap.add_argument("--b", required=True)
    ap.add_argument("--out", required=True)
    args = ap.parse_args()
    os.makedirs(args.out, exist_ok=True)

    ia, ib = load(os.path.join(args.a, "incidents.jsonl")), load(os.path.join(args.b, "incidents.jsonl"))
    ca, cb = load(os.path.join(args.a, "cases.jsonl")), load(os.path.join(args.b, "cases.jsonl"))

    def merge(records_a, records_b, key_fn, label):
        merged, one_sided = [], []
        used_b = set()
        for ra in records_a:
            best, best_score = None, 0.0
            for j, rb in enumerate(records_b):
                if j in used_b: continue
                s = max(overlap(key_fn(ra), key_fn(rb)), 0.6 * (1.0 if ra.get("class") == rb.get("class") else 0.0))
                if s > best_score: best, best_score = j, s
            if best is not None and best_score >= 0.45:
                used_b.add(best)
                ra2 = dict(ra); ra2["source"] = ["A", "B"]; ra2["also_reported_by_b"] = records_b[best].get("id")
                merged.append(ra2)
            else:
                ra2 = dict(ra); ra2["source"] = ["A"]
                merged.append(ra2)
                one_sided.append(("A only", ra2))
        for j, rb in enumerate(records_b):
            if j in used_b: continue
            rb2 = dict(rb); rb2["source"] = ["B"]
            merged.append(rb2)
            one_sided.append(("B only", rb2))
        return merged, one_sided

    inc, inc_one = merge(ia, ib, lambda r: r.get("title", "") + " " + r.get("summary", ""), "incident")
    case_key = lambda r: r.get("scenario", "") + " " + r.get("type", "")
    cases, case_one = merge(ca, cb, case_key, "case")
    for i, c in enumerate(cases, 1):
        c["canonical_id"] = f"EVAL-004-{i:03d}"

    with open(os.path.join(args.out, "incidents.jsonl"), "w") as f:
        for r in inc: f.write(json.dumps(r, ensure_ascii=False) + "\n")
    with open(os.path.join(args.out, "cases.jsonl"), "w") as f:
        for r in cases: f.write(json.dumps(r, ensure_ascii=False) + "\n")

    lines = [f"# Disagreement report — A vs B curation sets",
             f"A ({args.a}): {len(ia)} incidents, {len(ca)} cases",
             f"B ({args.b}): {len(ib)} incidents, {len(cb)} cases",
             f"merged: {len(inc)} incidents, {len(cases)} cases",
             f"one-sided: {len(inc_one)} incidents, {len(case_one)} cases", "",
             "One-sided items are anomaly signals: review each — real miss by the",
             "other curator, or an over-report. Adjust `source` by hand when merging.", ""]
    for side, r in inc_one:
        lines.append(f"- incident {side}: [{r.get('id')}] {r.get('class')} — {r.get('title')}")
    for side, r in case_one:
        lines.append(f"- case {side}: [{r.get('id')}] {r.get('type')} — {r.get('scenario')}")
    open(os.path.join(args.out, "disagreement.md"), "w").write("\n".join(lines) + "\n")
    print(f"merged {len(inc)} incidents, {len(cases)} cases; {len(inc_one)} + {len(case_one)} one-sided")
    print(f"outputs in {args.out}")

if __name__ == "__main__":
    main()
