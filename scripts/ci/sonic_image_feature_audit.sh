#!/usr/bin/env bash
# T073/T080: audit the pinned SONiC image for the features the capability gate
# requires (gNMI server, telemetry service, SRv6 YANG models). The audit reads
# the image declared in versions.lock.yaml and reports, per feature, whether
# the runtime artifacts exist. It explains — with on-disk facts — why the gate
# passes or fails closed for the selected profile (FR-022).
set -u

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
PROOFS="$ROOT_DIR/.wiggum/features/001-agentic-netops-sonic-evpn-fabric/gates/proofs"
mkdir -p "$PROOFS"

IMAGE=${SONIC_IMAGE:-$(awk '/^  sonic_vs:/{f=1} f && /image:/{print $2; exit}' "$ROOT_DIR/versions.lock.yaml")}
OUT="$PROOFS/sonic-image-feature-audit.log"

{
  echo "# SONiC image feature audit — $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "image: $IMAGE"
  echo
  if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
    echo "result: IMAGE_ABSENT (cannot audit)"
    exit 1
  fi
  probe() { docker run --rm --entrypoint bash "$IMAGE" -c "$1" 2>/dev/null; }

  echo "[feature] gNMI server binary (telemetry/gnmi)"
  gnmi_bin=$(probe 'ls /usr/bin/telemetry /usr/sbin/telemetry /usr/local/bin/telemetry 2>/dev/null; command -v gnmi 2>/dev/null' | head -1)
  echo "  binary: ${gnmi_bin:-ABSENT}"

  echo "[feature] telemetry/gNMI supervisord program"
  sup=$(probe 'grep -c "program:telemetry" /etc/supervisor/conf.d/supervisord.conf 2>/dev/null || true')
  echo "  supervisord program:telemetry count: ${sup:-0}"

  echo "[feature] gNMI systemd unit"
  unit=$(probe 'ls /etc/systemd/system/gnmi.service /lib/systemd/system/gnmi.service 2>/dev/null | head -1')
  echo "  unit: ${unit:-ABSENT (only .wants stub dir may exist)}"

  echo "[feature] SRv6 YANG model"
  srv6=$(probe 'ls /usr/local/yang-models/sonic-srv6.yang 2>/dev/null')
  echo "  model: ${srv6:-ABSENT}"

  echo "[feature] sonic-telemetry YANG model"
  telem=$(probe 'ls /usr/local/yang-models/sonic-telemetry.yang 2>/dev/null')
  echo "  model: ${telem:-ABSENT}"

  echo "[feature] redis (config store backing gNMI)"
  redis=$(probe 'command -v redis-server; command -v redis-cli')
  echo "  binaries: ${redis:-ABSENT}"

  echo
  if [[ -z "$gnmi_bin" && "${sup:-0}" -eq 0 ]]; then
    echo "result: GATE_FAILS_CLOSED — image provides no gNMI/telemetry server; gNMI Capabilities/Get/Set/Subscribe cannot succeed against this profile. SRv6/EVPN qualification must not be claimed (FR-022)."
  elif [[ -z "$srv6" ]]; then
    echo "result: GATE_FAILS_CLOSED — sonic-srv6 YANG model absent; SRv6 paths unavailable."
  else
    echo "result: FEATURE_ARTIFACTS_PRESENT — proceed to live capability gate (scripts/lib/qualify.sh)."
  fi
} | tee "$OUT"

grep -q 'result:' "$OUT" || exit 1
