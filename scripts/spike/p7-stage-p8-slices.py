#!/usr/bin/env python3
"""Stage whole-file grounding slices for the nine p8-regress receipts the
attempt-3 verdict (62cf11227358473e) marked NEEDS-GROUNDING (T421-T426,
T428-T430). The receipts are on disk and green; the critic simply could not
see them inside its grounding-snapshot budget. Each slice quotes the WHOLE
.out with original line numbers plus the exact stored command, under the
format the phase-4/5 slices use, so the evidence can cite one slice per
criterion. The receipts are NOT re-recorded (already accepted as recorded;
T427/p8-regress-mtu_ecmp is already accepted and needs nothing)."""
import hashlib
from pathlib import Path

ROOT = Path("/root/agentic-netops")
PROOFS = ROOT / ".wiggum/features/004-srv6-service-requests/gates/proofs"
REL = ".wiggum/features/004-srv6-service-requests/gates/proofs"
VERDICT = "62cf11227358473e"
STAGED = "2026-10-17"

CRITERIA = [
    ("p8-regress-fabric_verify", "T421"),
    ("p8-regress-evpn_traffic", "T422"),
    ("p8-regress-idempotence", "T423"),
    ("p8-regress-drift_preservation", "T424"),
    ("p8-regress-update_delete_survivability", "T425"),
    ("p8-regress-teardown_suite", "T426"),
    ("p8-regress-failure_recovery_invalid_yang", "T428"),
    ("p8-regress-topology_parity", "T429"),
    ("p8-regress-observability_suite", "T430"),
]

for name, tid in CRITERIA:
    outf = PROOFS / f"{name}.out"
    cmdf = PROOFS / f"{name}.cmd"
    raw = outf.read_bytes()
    lines = raw.decode().splitlines()
    out = [
        f"# grounding slice of {REL}/{name}.out — staged {STAGED} (verdict {VERDICT}, {tid})",
        f"# bytes={len(raw)} sha256={hashlib.sha256(raw).hexdigest()[:16]} (full file on disk; quoted in full below)",
        f"# stored command ({REL}/{name}.cmd): {cmdf.read_text().strip() if cmdf.exists() else '<missing>'}",
        "# --- whole file, original line numbers ---",
    ]
    out.extend(f"{i+1:6d}\t{l}" for i, l in enumerate(lines))
    dest = PROOFS / f"g5-a4-p8regress-{name}.slice.txt"
    dest.write_text("\n".join(out) + "\n")
    print(f"wrote {dest.name}: {len(lines)} lines")
