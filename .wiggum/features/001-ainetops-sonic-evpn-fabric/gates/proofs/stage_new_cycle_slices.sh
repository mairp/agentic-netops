#!/usr/bin/env bash
# Stage line-numbered proof slices for the NEW cycles run (started 2026-09-01T07:07:40Z).
# Run only after cycles.run.log shows "[cycles] end" and cycles_runner.stdout.log shows CYCLES_DONE.
set -u
CYC=/root/ainetops-demo/.wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/cycles
OUT=/root/ainetops-demo/.wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs

# 1) Full cycles.run.log, line-numbered
nl -ba "$CYC/cycles.run.log" > "$OUT/cycles.cycles.run.log.full.slice.txt"

# 2) Provision key lines: rollouts, assert-crds, qualify section, completion
for n in 1 2 3; do
  f="$CYC/provision-$n.log"
  {
    grep -n "successfully rolled out" "$f"
    grep -n "assert-crds" "$f"
    grep -n "qualify\] Running\|qualify\] OK\|qualify\] FAILED\|capability gate" "$f"
    grep -n "\[provision\] complete" "$f"
    grep -n "SRv6Service\|srv6service\|wait --for=condition=Ready" "$f"
    grep -n "sdc-install" "$f"
  } | sort -t: -k1 -n -u > "$OUT/cycles.provision-$n.key.proof.txt"
done
# full qualify section of provision-1 (from first [qualify] line to end)
q=$(grep -n "\[qualify\] Running Capabilities" "$CYC/provision-1.log" | head -1 | cut -d: -f1)
if [[ -n "${q:-}" ]]; then
  sed -n "${q},\$p" "$CYC/provision-1.log" | nl -ba -v"$q" > "$OUT/cycles.provision-1.qualify-section.slice.txt"
fi

# 3) off logs: full (they are short)
for f in off-1 off-2 off-3 off-1-noop off-2-noop off-3-noop off-conformance off-from-partial idempotence-off; do
  [[ -f "$CYC/$f.log" ]] && nl -ba "$CYC/$f.log" > "$OUT/cycles.$f.proof.txt"
done

# 4) test-fabric full slices
for n in 1 2 3; do
  [[ -f "$CYC/test-fabric-$n.log" ]] && nl -ba "$CYC/test-fabric-$n.log" > "$OUT/cycles.test-fabric-$n.full.slice.txt"
done
for n in 1 2 3; do
  [[ -f "$CYC/test-parity-$n.log" ]] && nl -ba "$CYC/test-parity-$n.log" > "$OUT/cycles.test-parity-$n.proof.txt"
  [[ -f "$CYC/test-observability-$n.log" ]] && nl -ba "$CYC/test-observability-$n.log" > "$OUT/cycles.test-observability-$n.proof.txt"
  [[ -f "$CYC/runtime-scan-runtime-$n.log" ]] && nl -ba "$CYC/runtime-scan-runtime-$n.log" > "$OUT/cycles.runtime-scan-runtime-$n.proof.txt"
done
[[ -f "$CYC/runtime-scan-runtime.log" ]] && nl -ba "$CYC/runtime-scan-runtime.log" > "$OUT/cycles.runtime-scan-runtime.proof.txt"

# 5) idempotence + partial + conformance key lines
for f in idempotence-provision-1 idempotence-provision-2 partial-provision; do
  [[ -f "$CYC/$f.log" ]] && {
    grep -n "assert-crds\|already exists (idempotent)\|already attached to ainetops-mgmt (idempotent)\|unchanged (server dry run)\|qualify\] OK\|\[provision\] complete" "$CYC/$f.log" | head -40 \
      > "$OUT/cycles.$f.key.proof.txt"
  }
done
if [[ -f "$CYC/provision-conformance.log" ]]; then
  tail -30 "$CYC/provision-conformance.log" | nl -ba -v$(( $(wc -l < "$CYC/provision-conformance.log") - 29 )) > "$OUT/cycles.provision-conformance.tail.proof.txt"
fi
# runtime inventory kubectl (latest)
[[ -f "$CYC/runtime-inventory-kubectl-3.log" ]] && nl -ba "$CYC/runtime-inventory-kubectl-3.log" > "$OUT/cycles.runtime-inventory-kubectl-3.slice.txt"

echo "STAGED $(ls "$OUT" | grep -c 'cycles\..*\.txt') slice files"
