
## Verdict + documentation deliverables (T110–T124)

- **T110** `lab/profiles/sonic-vm/srv6-supported.yaml` — machine verdict file, 4 entries
  (`ip-vrf/vpn` proven, `ip-vrf/evpn` not-achievable, `mac-vrf/evpn` not-achievable,
  `steering` proven) + `honest_negatives` list; header states the refusal contract
  (`UnsupportedVariant`, never half-delivered) and the consumers
  (`scripts/lib/capability.sh`, `scripts/provision.sh`, `pkg/compat/pins.go`).
- **T111** data-model §8.1 (line 168) per-service claim profile: what a service request may claim
  per variant, keyed to the measured verdicts.
- **T112** §8.2 (line 185) locator block/format: uSID-shaped block, CLASSIC dataplane (SRH one
  segment — the `RT6 … segleft=0 [0]fcbb:bbbb:4:11::` capture line), /48 origination facts,
  reachability 12/12.
- **T113** §8.3 (line 201) device state per variant incl. the write-class column and the three
  "NOT achievable (measured)" rows.
- **T114** §8.4 (line 221) read-backs per variant (the exact commands the proofs run).
- **T115** §8.5 (line 240) rollback per variant (vpn teardown recipe + evpn3/evpn2 restore
  recipes, with the /INTERFACE guard).
- **T116** §8.6 (line 257) steering: pin commands, ECMP self-loop hazard, SLO note (SC-007 not
  met; loss classes ≤10), raw probe tables, counter conclusion.
- **T117** §8.7 (line 278) client-side requirements (addresses/routes/gateways per
  `spike-vpn-clients`).
- **T118** §8.8 (line 291) baseline prerequisites (seg6_enabled per-interface, strict_mode, vrf
  module, the `dev lo` false-negative rule).
- **T119** fabricplan contract §3 intro + **T120** §3.1 (line 44) `ip-vrf`/`vpn` per-leaf items;
  **T121** §3.2 (line 57) steering items (ingress leaf only); **T122** §3.3 (line 68) no-recipe
  variants (`ip-vrf`/`evpn`, `mac-vrf`/`evpn` — refuse-by-name mapping).
- **T123** spec KL-001..KL-003 replaced with the measured verdicts (~lines 694–721 of
  `specs/004-srv6-service-requests/spec.md`).
- **T124** `docs/SRV6_SERVICE_RECIPE.md` §6 exit-gate review: the 4-variant verdict table + the
  six-entry honest-negative register + the replay-stability statement (slice
  `proofs/p3-recipe-s6-exitgate.txt`).

## Replay receipts (T105–T109) — recorded on this pass, see PROGRESS.md pass 13

Placeholder — filled after the five rerun proofs are recorded:

- T105 `spike-rerun-baseline`
- T106 `spike-rerun-vpn`
- T107 `spike-rerun-evpn3`
- T108 `spike-rerun-evpn2`
- T109 `spike-rerun-steering`
