#!/usr/bin/env bash
# run-p2-configmap-pin.sh — T024 (FR-009) live observation, phase 2 of feature 004:
# the ConfigMap fabric-compat-pins must name, in .data["sonic-image"], the image
# the switches run — i.e. the ACTIVE profile's versions.lock.yaml pin. On this
# host the live lab is the sonic-vm fabric (clab-agentic-netops-fabric-* run
# local/sonic-vm:202505), so the expected pin is sonic_images.sonic_vm.image.
# Three independent read paths, none of them the mutation that wrote the pin:
#   1. kubectl jsonpath  -> the LIVE ConfigMap keys
#   2. awk over versions.lock.yaml -> the pinned image (same parser shape as
#      scripts/provision.sh's pre-deploy assertion)
#   3. docker image inspect -> the ID of the tagged image the nodes actually run
# Exits non-zero if lab-profile is not sonic-vm, if the ConfigMap sonic-image
# differs from the lock pin, or if the tagged image ID differs from the digest.
set -euo pipefail
CLUSTER=${AGENTIC_NETOPS_CLUSTER_NAME:-agentic-netops}
CTX="kind-${CLUSTER}"
NS=agentic-netops-system
REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
cd "$REPO_ROOT"

cm_img=$(kubectl --context "$CTX" -n "$NS" get configmap fabric-compat-pins -o jsonpath='{.data.sonic-image}')
cm_prof=$(kubectl --context "$CTX" -n "$NS" get configmap fabric-compat-pins -o jsonpath='{.data.lab-profile}')
lock_img=$(awk '
  $1=="sonic_images:" {sec=1; next}
  sec && /^[^[:space:]]/ {exit}
  sec && $1=="sonic_vm:" {vm=1; next}
  sec && vm && /^[^[:space:]]/ {vm=0}
  sec && vm && $1=="image:" {print $2; exit}
' versions.lock.yaml)
tag_id=$(docker image inspect local/sonic-vm:202505 --format '{{.Id}}')

printf 'configmap.data["sonic-image"]: %s\n' "$cm_img"
printf 'configmap.data["lab-profile"]: %s\n' "$cm_prof"
printf 'versions.lock.yaml sonic_vm.image: %s\n' "$lock_img"
printf 'docker local/sonic-vm:202505 image ID: %s\n' "$tag_id"

status=0
[[ "$cm_prof" == "sonic-vm" ]] || { echo 'MISMATCH: ConfigMap lab-profile is not the active sonic-vm profile' >&2; status=1; }
if [[ -z "$lock_img" || "$cm_img" != "$lock_img" ]]; then
  echo 'MISMATCH: ConfigMap sonic-image != active profile lock pin' >&2; status=1
fi
if [[ -z "$tag_id" || "$tag_id" != "${lock_img##*@}" ]]; then
  echo 'MISMATCH: tagged local image ID != pinned digest' >&2; status=1
fi
if [[ "$status" -eq 0 ]]; then
  echo 'MATCH: ConfigMap sonic-image == sonic-vm lock pin == local/sonic-vm:202505 image ID'
fi
exit "$status"
