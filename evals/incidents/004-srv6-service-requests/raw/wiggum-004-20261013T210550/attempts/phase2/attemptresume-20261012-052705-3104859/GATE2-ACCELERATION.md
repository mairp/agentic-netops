# Phase 2 — accelerator pass (attempt 4)

An accelerator pass (proposer tools, narrowed prompt) already acted on the
diagnostician hint for: T022,T023,T024,T599
Its changes are in the tree. Do NOT redo them — verify they hold, then fix
whatever the critic still rejects.

## Files this pass changed (vs HEAD; 'new' = untracked)
- scripts/proofs/run-p2-configmap-pin.sh	new

## The accelerator's own notes
# GATE2-ACCELERATOR-NOTE — attempt 4

CASE was GROUNDING for T023/T599 (code already correct; fresh line-numbered
slices restaged: `gates/proofs/p2-t023-tag-and-exit.txt`,
`p2-t023-assert-live.txt`, `p2-t599-known-exceptions.txt`,
`p2-t022-digest-proof-slice.txt`). T024 needed more than grounding:

- The LIVE `fabric-compat-pins` ConfigMap still named the sonic-vs image
  (`localhost:5000/sonic-vs-gnmi@sha256:d1043…`) with no `lab-profile` key,
  while the running fabric is the sonic-vm lab. Converged it with
  provision.sh's OWN generation block (lines 261-329 verbatim,
  AGENTIC_NETOPS_PROFILE=sonic-vm) + the capability patch (lines 410-415
  semantics); before/after + addendum: `gates/proofs/p2-t024-configmap-regenerate.txt`.
  Live observation recorded: `gates/proofs/p2-configmap-sonic-image.{cmd,out}`
  via `scripts/proofs/run-p2-configmap-pin.sh` (replay "no difference").
- Quirk found, left untouched per the footprint rule: provision.sh's
  capability-patch block (lines 406-417) is dead on this host because its
  `[[ -x scripts/lib/capability.sh ]]` guard fails — that file is mode 600
  (its siblings are executable). The block silently skips, so a future real
  provision would not patch the derived capability keys. scripts/lib/capability.sh
  is a pinned T031/T032 backing file, so fixing the mode is out of scope here;
  the convergence addendum documents the same patch run directly.
- T023's "bring-up actually fails" was exercised live, not just cited:
  `gates/proofs/p2-pin-assert-live.{cmd,out}` runs the exact assertion block
  (provision.sh lines 88-112) against a tampered THROWAWAY copy of
  versions.lock.yaml (real pinned file untouched) → mismatch-exit 1; real lock
  → match-exit 0.

Evidence published atomically (tmp → mv) as a splice of the attempt-3 archive;
diff is exactly the date line + the T022/T023+T598/T599/T024 bullets.
