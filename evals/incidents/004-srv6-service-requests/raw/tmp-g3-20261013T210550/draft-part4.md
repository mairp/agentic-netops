
### Replay receipts recorded this pass (pass 13)

All five receipts were recorded on this pass's converged lab (T104-fresh → convergence →
re-records): the stored `.out` of every group proof was refreshed FIRST (the pass-12 script
fixes postdate the old captures), then each receipt records a full clean replay of its group:

- **T106** `spike-rerun-vpn` — `scripts/proof.sh replay spike-vpn`: 8 proofs in canonical order
  (state-leaf01, state-leaf02, ping, capture, readback-leaf01, readback-leaf02, clients,
  rollback — the group ends with its rollback), `… no difference`, exit 0.
- **T107** `spike-rerun-evpn3` — replay of the 6 routed-EVPN proofs in recorded order.
- **T108** `spike-rerun-evpn2` — replay of the 5 bridged-EVPN proofs in recorded order.
- **T109** `spike-rerun-steering` — replay of the 5 steering proofs in recorded order.
- **T105** `spike-rerun-baseline` — `scripts/spike/seed-restore.sh` first restores the EXACT
  provision seed (partial/asymmetric BGP_NEIGHBOR topology, locators/VRF/pins/vtysh-only state
  removed, bgp restarted — 322-line script with the seed rows embedded from the stored baseline
  captures), then a dry `replay spike-baseline` verifies rc=0, then the receipt records the same
  replay: 4 proofs (spine01, spine02, leaf01, leaf02), `… no difference`, exit 0.

Determinism fix found by this pass's re-record cycle (recorded in PROGRESS.md pass 13):
container-side `ip -4 -br addr show eth1` leaks the host-side veth ifindex (`eth1@if473`), which
changes at every bring-up (measured if413 → if473 across the T104 redeploy) —
`addr_norm()` in `scripts/spike/spike-env.sh` now masks it (`@ifI`); `vpn-setup.sh` and
`vpn-clients.sh` pass their client reads through it. The three affected proofs were re-recorded
before the receipts.

**Proof-slice index** (staged excerpts under `proofs/`, `p3-*` prefix — outside the `.cmd/.out`
namespace so `replay` never mistakes them for recorded proofs):

| slice | source |
| --- | --- |
| `p3-baseline-fresh.txt` | spike-baseline-leaf01.out head (fresh-lab seed state) |
| `p3-t104-fresh-redeploy.txt` | T104 provision receipt |
| `p3-proof-readback-leaf01.txt` | spike-vpn-readback-leaf01.out (decap + steering + clients) |
| `p3-proof-rollback.txt` | spike-vpn-rollback.out (teardown + INTERFACE-RESTORED guards) |
| `p3-proof-sid-write.txt` | spike-sid-write.out (SRV6_MY_SIDS write class) |
| `p3-proof-persistence.txt` | spike-persistence.out (reload loses kernel state) |
| `p3-proof-evpn3-negatives.txt` | spike-evpn3-state-leaf01.out (0 L3 VNIs) |
| `p3-proof-evpn2-negatives.txt` | spike-evpn2-ping.out (IMET yes, Type-2 no) |
| `p3-proof-steering-path.txt` | spike-steering-path.out (preferred leg NONZERO) |
| `p3-proof-steering-failover.txt` | spike-steering-failover-launcher.out (loss classifiers) |
| `p3-proof-steering-return.txt` | spike-steering-return.out |
| `p3-rerun-vpn/-evpn3/-evpn2/-steering/-baseline.txt` | the five receipt `.out` files |
| `p3-recipe-s1-underlay/-s2-asbuilt/-s2-verdicts/-s3-s4-negatives/-s5-steering/-s6-exitgate.txt` | recipe §1–§6 |
| `p3-yaml-verdicts.txt` | srv6-supported.yaml verdicts |
| `p3-datamodel-s8.txt` | data-model §8.1–§8.8 |
| `p3-contract-s3.txt` | fabricplan §3.1–§3.3 |
| `p3-spec-kl.txt` | spec KL-001..003 measured verdicts |
| `p3-script-ensure-fabric.txt`, `p3-script-sid-write.txt` | the self-contained replay machinery |
