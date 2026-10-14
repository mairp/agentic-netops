#!/usr/bin/env python3
"""Supervising-agent merge: hand-verified A<->B cross-references (supersedes
the coarse auto-matching in evals/reconcile.py). Run from the feature dir."""
import json, os

A, B = "agent-qwen38", "agent-glm53"

# Conservative duplicate table: A incident -> B incident ONLY when both clearly
# describe the same event. Everything else stays source-tagged A-only / B-only.
# (Worker A decomposes the wedge timeline into per-occurrence incidents; Worker B
#  consolidates them into one "6 occurrences" incident + a docker-restart lesson.)
INC = {
    "INC-004-001": ("INC-004-020", "wedge occurrence (leaf02 swss); B consolidates all 6 into B-020; the docker-restart lesson is B-016"),
    "INC-004-002": ("INC-004-008", None),
    "INC-004-003": (None, None),
    "INC-004-004": ("INC-004-017", None),
    "INC-004-005": ("INC-004-021", None),
    "INC-004-006": (None, None),
    "INC-004-007": (None, "chain2 WARN-continue; B folds the chain4 variant into B-018"),
    "INC-004-008": ("INC-004-022", "the overwrite that produced the false-clean B-022"),
    "INC-004-009": ("INC-004-022", None),
    "INC-004-010": ("INC-004-015", "related: receipts taken on a non-stable lab"),
    "INC-004-011": ("INC-004-020", "wedge occurrence (G-seed kernel_cleanup) inside B's consolidated B-020"),
    "INC-004-012": ("INC-004-001", None),
    "INC-004-013": ("INC-004-026", "relaunch failures folded into B's stop.flag incident"),
    "INC-004-014": ("INC-004-026", None),
    "INC-004-015": ("INC-004-027", None),
    "INC-004-016": ("INC-004-019", None),
    "INC-004-017": ("INC-004-018", None),
    "INC-004-018": ("INC-004-020", "wedge occurrence #4 inside B's consolidated B-020"),
    "INC-004-019": ("INC-004-020", "wedge occurrence #5 inside B's consolidated B-020"),
    "INC-004-020": ("INC-004-024", None),
    "INC-004-021": ("INC-004-032", None),
    "INC-004-022": ("INC-004-023", None),
    "INC-004-023": ("INC-004-020", "wedge occurrence #6 inside B's consolidated B-020"),
    "INC-004-024": ("INC-004-025", None),
    "INC-004-025": ("INC-004-028", None),
    "INC-004-026": ("INC-004-030", None),
    "INC-004-027": ("INC-004-029", None),
    "INC-004-028": (None, "receipts.sh mode-600 / rc=127; B covers the rc-hygiene side in B-029"),
    "INC-004-029": (None, "honest negatives; B uses them in EVAL-004-009"),
}
CASES = {
    "EVAL-004-001": ("EVAL-004-001", None),
    "EVAL-004-002": ("EVAL-004-002", None),
    "EVAL-004-003": ("EVAL-004-003", None),
    "EVAL-004-004": (None, "A-only: canary measurement-bug review; related to B-011 (identical-signature diagnosis)"),
    "EVAL-004-005": ("EVAL-004-004", None),
    "EVAL-004-006": ("EVAL-004-008", "B-016 is the harness-side twin of this same arm-time property"),
    "EVAL-004-007": (None, "A-only: honest-negative classification; related to B-009 (differ-receipt trust)"),
    "EVAL-004-008": ("EVAL-004-010", None),
    "EVAL-004-009": ("EVAL-004-007", None),
    "EVAL-004-010": ("EVAL-004-006", None),
    "EVAL-004-011": ("EVAL-004-012", None),
    "EVAL-004-012": ("EVAL-004-013", None),
    "EVAL-004-013": (None, "A-only: recorded-failure inventory (stale vs live); adjacent to B-014 (order integrity)"),
    "EVAL-004-014": (None, "A-only: rc/verdict completeness; adjacent to B-014 (footer invariant)"),
    "EVAL-004-015": (None, "A-only: precondition-abort property; B-003 covers the seed variant"),
    "EVAL-004-016": ("EVAL-004-017", None),
    "EVAL-004-017": ("EVAL-004-015", None),
    "EVAL-004-018": ("EVAL-004-016", None),
    "EVAL-004-019": (None, "A-only (harness alarm variant); B-010 covers the agent side of the same finding"),
}

def load(p):
    return {json.loads(l)["id"]: json.loads(l) for l in open(p) if l.strip()}

ia, ib = load(f"{A}/incidents.jsonl"), load(f"{B}/incidents.jsonl")
ca, cb = load(f"{A}/cases.jsonl"), load(f"{B}/cases.jsonl")

def merge(records_a, records_b, mapping, label, start_b_only):
    out, b_matched = [], set()
    seq = start_b_only
    for aid, ra in records_a.items():
        b_id, note = mapping.get(aid, (None, "UNMAPPED — supervising agent must review"))
        r = dict(ra)
        r["source"] = ["A", "B"] if b_id else ["A"]
        r["cross_ref_b"] = b_id  # original B-side id (into agent-glm53/ files)
        if b_id: b_matched.add(b_id)
        if note: r["merge_note"] = note
        out.append(r)
    for bid, rb in records_b.items():
        if bid in b_matched: continue
        r = dict(rb)
        r["orig_id"] = bid
        r["id"] = f"{bid.rsplit('-',1)[0]}-{seq:03d}"  # canonical renumber; orig_id keeps B's
        r["source"] = ["B"]
        r["cross_ref_a"] = None
        seq += 1
        out.append(r)
    return out

inc = merge(ia, ib, INC, "incident", 30)  # A uses INC-004-001..029
cases = merge(ca, cb, CASES, "case", 20)  # A uses EVAL-004-001..019
# remap B-original incident ids -> canonical ids (for derived_from refs)
bid2canon = {}
for r in inc:
    if r.get("cross_ref_b"): bid2canon[r["cross_ref_b"]] = r["id"]
for r in inc:
    if r.get("orig_id"): bid2canon[r["orig_id"]] = r["id"]
for c in cases:
    if c.get("source") == ["B"] and c.get("derived_from"):
        c["derived_from"] = [bid2canon.get(x, x) for x in c["derived_from"]]
    c.pop("canonical_id", None)

os.makedirs("canonical", exist_ok=True)
with open("canonical/incidents.jsonl", "w") as f:
    for r in inc: f.write(json.dumps(r, ensure_ascii=False) + "\n")
with open("canonical/cases.jsonl", "w") as f:
    for r in cases: f.write(json.dumps(r, ensure_ascii=False) + "\n")

both_i = sum(1 for r in inc if r["source"] == ["A", "B"])
both_c = sum(1 for r in cases if r["source"] == ["A", "B"])
print(f"incidents: {len(inc)} total ({both_i} A+B, {sum(1 for r in inc if r['source']==['A'])} A-only, {sum(1 for r in inc if r['source']==['B'])} B-only)")
print(f"cases: {len(cases)} total ({both_c} A+B, {sum(1 for r in cases if r['source']==['A'])} A-only, {sum(1 for r in cases if r['source']==['B'])} B-only)")
unmapped = [r['id'] for r in inc if 'UNMAPPED' in r.get('merge_note','')] + [r['id'] for r in cases if 'UNMAPPED' in r.get('merge_note','')]
print("unmapped:", unmapped or "none")
