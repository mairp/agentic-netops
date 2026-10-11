#!/usr/bin/env bash
# Build the operator-built sonic-vm conformance image via vrnetlab.
#
# Produces the image pinned in versions.lock.yaml (sonic_images.sonic_vm):
#   local/sonic-vm:<version>   (and local/sonic-vm:latest)
#
# Grounded build path (srl-labs/vrnetlab, containerlab sonic-vm kind):
#   - source artifact: target/sonic-vs.img.gz from a SONiC VS build
#     (https://sonic-build.azurewebsites.net/ui/sonic/pipelines,
#      https://sonic-net.github.io/SONiC/sonic_latest_images.html)
#   - vrnetlab expects it decompressed and renamed sonic-vs-<version>.qcow2
#     (its Makefile globs *.qcow2 and extracts the version from the filename)
#   - `make docker-image` produces vrnetlab/sonic_sonic-vs:<version>
#
# Requirements: docker, ~10 GB free disk (image ~3.2 GB after import), git,
# network access. KVM is only needed at RUN time (preflight enforces it).
#
# Usage:
#   scripts/build-sonic-vm.sh --image-url <url to sonic-vs.img.gz> \
#                             [--version 202505] [--update-pin] [--keep-workdir]
#                             [--resume <workdir>]
#
# --update-pin rewrites the sonic_vm digest (and the matching
# sonic_yang.compatibility entry) in versions.lock.yaml to the freshly built
# image, then runs scripts/lib/verify_pins.sh to validate the lock.
#
# --resume <workdir> reuses a previous --keep-workdir directory: the partial
# artifact download is continued with HTTP range requests instead of being
# re-downloaded from scratch.
set -euo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
VERSION="202505"
IMAGE_URL="${SONIC_VS_IMAGE_URL:-}"
UPDATE_PIN=0
KEEP=0
RESUME_DIR=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --image-url) IMAGE_URL="$2"; shift 2 ;;
    --version)   VERSION="$2"; shift 2 ;;
    --update-pin) UPDATE_PIN=1; shift ;;
    --keep-workdir) KEEP=1; shift ;;
    --resume) RESUME_DIR="$2"; shift 2 ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown arg: $1 (see --help)" >&2; exit 2 ;;
  esac
done

command -v docker >/dev/null 2>&1 || { echo "docker not found" >&2; exit 1; }
command -v git     >/dev/null 2>&1 || { echo "git not found" >&2; exit 1; }
[[ -n "$IMAGE_URL" ]] || {
  echo "ERROR: --image-url <sonic-vs.img.gz URL> is required (or export SONIC_VS_IMAGE_URL)." >&2
  echo "Browse VS-build artifacts at:" >&2
  echo "  https://sonic-build.azurewebsites.net/ui/sonic/pipelines" >&2
  echo "  https://sonic-net.github.io/SONiC/sonic_latest_images.html" >&2
  exit 2
}

echo "[sonic-vm] workdir + vrnetlab checkout"
if [[ -n "$RESUME_DIR" ]]; then
  [[ -d "$RESUME_DIR" ]] || { echo "ERROR: --resume dir not found: $RESUME_DIR" >&2; exit 1; }
  WORK="$RESUME_DIR"
  KEEP=1  # never delete a resumed workdir automatically
  if [[ ! -d "$WORK/vrnetlab" ]]; then
    git clone --depth 1 https://github.com/srl-labs/vrnetlab "$WORK/vrnetlab"
  fi
  echo "[sonic-vm] resuming in $WORK (artifact.bin at $(du -h "$WORK/artifact.bin" 2>/dev/null | cut -f1) so far)"
else
  # Work on real disk, not /tmp: /tmp is often tmpfs (RAM-backed) and the Azure
  # artifact is ~23 GB zipped / ~9 GB uncompressed — it would exhaust a RAM-backed
  # tmpfs. Override the parent dir with SONIC_VM_WORKDIR if needed.
  WORK_PARENT=${SONIC_VM_WORKDIR:-/var/tmp}
  mkdir -p "$WORK_PARENT"
  WORK=$(mktemp -d "${WORK_PARENT}/sonic-vm-build.XXXXXX")
  git clone --depth 1 https://github.com/srl-labs/vrnetlab "$WORK/vrnetlab"
fi
trap '[[ "$KEEP" == 1 ]] || rm -rf "$WORK"' EXIT

# Resumable download with size verification. Azure artifact connections are
# routinely dropped mid-transfer (observed: server closed at 12.1G of 23.4G and
# curl exited 0), so: loop with HTTP range resume (-C -), then verify the
# fetched size against the advertised Content-Length before trusting it.
artifact_download() {
  local out="$1" url="$2" expected have rc attempts=0 resumed=0

  # Local file support: --image-url may point at an already-downloaded
  # artifact (curl cannot read filesystem paths as URLs, so short-circuit).
  if [[ -f "$url" ]]; then
    echo "[sonic-vm] using local artifact: $url ($(du -h "$url" | cut -f1))"
    if [[ "$(head -c 2 "$url")" != "PK" ]]; then
      # raw gzip (not a ZIP): validate now; ZIPs are validated at extract time
      if ! gzip -t "$url" 2>/dev/null; then
        echo "ERROR: local artifact is not a valid gzip file and not a ZIP: $url" >&2
        return 1
      fi
      echo "[sonic-vm] local gzip integrity OK"
    fi
    cp -f "$url" "$out"
    return 0
  fi

  # Content-Length must come from a 200/206 response — error pages (405/400)
  # carry their own tiny Content-Length (observed: "93") which poisoned the
  # size check. Key each length by the status code of its header block.
  expected=$(curl -sIL --retry 3 "$url" | tr -d '\r' | awk '
    tolower($1) ~ /^http\//          { code = $2 }
    tolower($1) == "content-length:" { len[code] = $2 }
    END { for (c in len) if (c == 200 || c == 206) { print len[c]; break } }')
  have=0; [[ -f "$out" ]] && have=$(stat -c%s "$out")
  if [[ -n "$expected" && "$have" -eq "$expected" ]]; then
    echo "[sonic-vm] artifact already complete (${have} bytes); skipping download"
    return 0
  fi
  while :; do
    attempts=$((attempts + 1))
    if [[ $attempts -ge 20 ]]; then
      echo "ERROR: download failed after $attempts attempts" >&2
      return 1
    fi
    have=0; [[ -f "$out" ]] && have=$(stat -c%s "$out")

    if [[ "$have" -gt 0 && "$resumed" -eq 0 ]]; then
      # One resume attempt. If the server refuses ranges (curl 33) or rejects
      # the ranged GET outright (curl 22 — this artifact host 400s them),
      # drop the partial and restart clean; further resume attempts are
      # pointless.
      echo "[sonic-vm] download attempt $attempts: resuming from byte ${have} of ${expected:-unknown}"
      set +e; curl -fL -C - --retry 5 --retry-delay 5 -o "$out" "$url"; rc=$?; set -e
      if [[ $rc -eq 0 ]]; then
        have=$(stat -c%s "$out" 2>/dev/null || echo 0)
        if [[ -z "$expected" || "$have" -eq "$expected" ]]; then return 0; fi
        echo "[sonic-vm] WARN: got ${have} bytes, expected ${expected}" >&2
      fi
      echo "[sonic-vm] WARN: server does not support range resume (rc=$rc); restarting download from scratch" >&2
      rm -f "$out"; resumed=1
      continue
    fi

    echo "[sonic-vm] download attempt $attempts (full transfer)"
    set +e; curl -fL --retry 5 --retry-delay 5 -o "$out" "$url"; rc=$?; set -e
    if [[ $rc -eq 0 ]]; then
      have=$(stat -c%s "$out" 2>/dev/null || echo 0)
      if [[ -z "$expected" || "$have" -eq "$expected" ]]; then
        return 0
      fi
      echo "[sonic-vm] WARN: connection closed early (${have}/${expected} bytes); retrying" >&2
    else
      echo "[sonic-vm] WARN: curl failed (rc=$rc); retrying in 5s" >&2
      sleep 5
    fi
  done
}

echo "[sonic-vm] downloading SONiC VS image"
artifact_download "$WORK/artifact.bin" "$IMAGE_URL"

echo "[sonic-vm] preparing sonic-vs-${VERSION}.qcow2 (vrnetlab naming requirement)"
SRC="$WORK/artifact.bin"
# Azure artifact URLs serve the ENTIRE target/ bundle as a ZIP, not the raw
# image. Detect the ZIP magic and extract only the sonic-vs.img.gz member.
if [[ "$(head -c 2 "$SRC")" == "PK" ]]; then
  command -v unzip >/dev/null 2>&1 || { echo "unzip not found; required to open the artifact ZIP" >&2; exit 1; }
  # Validate the ZIP central directory BEFORE trusting it — a truncated
  # download produces exactly the "End-of-central-directory signature not
  # found" failure. --resume re-completes the file instead of failing here.
  if ! unzip -tqq "$SRC" >/dev/null 2>&1; then
    echo "ERROR: artifact ZIP is corrupt/incomplete (download truncated?)." >&2
    echo "Re-run with: $0 --resume '$WORK' --image-url <url> --version $VERSION --update-pin" >&2
    exit 1
  fi
  echo "[sonic-vm] artifact is an Azure ZIP bundle; locating sonic-vs.img.gz member"
  MEMBER=$(unzip -l "$SRC" | awk '{print $4}' | grep -E '(^|/)sonic-vs\.img\.gz$' | head -1)
  [[ -n "$MEMBER" ]] || { echo "ERROR: no sonic-vs.img.gz inside the artifact ZIP — wrong platform artifact? (need the 'vs' pipeline)" >&2; exit 1; }
  echo "[sonic-vm] extracting ${MEMBER}"
  unzip -j -o "$SRC" "$MEMBER" -d "$WORK" >/dev/null
  SRC="$WORK/sonic-vs.img.gz"
fi
gzip -dc "$SRC" > "$WORK/sonic-vs.img"
mv "$WORK/sonic-vs.img" "$WORK/vrnetlab/sonic/sonic-vs-${VERSION}.qcow2"

echo "[sonic-vm] building vrnetlab image (this bakes the qcow2 into docker; may take several minutes)"
make -C "$WORK/vrnetlab/sonic" docker-image

SRC_TAG="vrnetlab/sonic_sonic-vs:${VERSION}"
docker image inspect "$SRC_TAG" >/dev/null 2>&1 || {
  # older vrnetlab layouts may name it differently; locate it
  SRC_TAG=$(docker images --format '{{.Repository}}:{{.Tag}}' | grep -E '^vrnetlab/.*sonic' | head -1)
  [[ -n "$SRC_TAG" ]] || { echo "ERROR: vrnetlab sonic image not found after build" >&2; exit 1; }
}
echo "[sonic-vm] retagging ${SRC_TAG} -> local/sonic-vm:${VERSION}"
docker tag "$SRC_TAG" "local/sonic-vm:${VERSION}"
docker tag "$SRC_TAG" "local/sonic-vm:latest"

DIGEST=$(docker image inspect "local/sonic-vm:${VERSION}" --format '{{index .RepoDigests 0}}' 2>/dev/null | sed 's/.*@//' || true)
if [[ -z "$DIGEST" ]]; then
  # locally built images have no repo digest until pushed; use the image ID
  DIGEST="sha256:$(docker image inspect "local/sonic-vm:${VERSION}" --format '{{.Id}}' | sed 's/sha256://')"
  echo "[sonic-vm] NOTE: image is local-only; using image ID as digest stand-in: $DIGEST" >&2
  echo "[sonic-vm]       push to a registry (or 'docker save | docker load' on the target host) for a real digest." >&2
fi
echo "[sonic-vm] digest: $DIGEST"
docker images --digests | grep -E 'sonic' || true

if [[ "$UPDATE_PIN" == 1 ]]; then
  echo "[sonic-vm] updating versions.lock.yaml sonic_vm pins"
  LOCK="${ROOT_DIR}/versions.lock.yaml"
  cp "$LOCK" "${LOCK}.bak"
  sed -i "s|^\(    image: local/sonic-vm\)$|\1|" "$LOCK"
  # sonic_images.sonic_vm.digest
  python3 - "$LOCK" "$DIGEST" <<'PY'
import re, sys
lock, digest = sys.argv[1], sys.argv[2]
text = open(lock).read()
old = re.search(r'sonic_vm:\n    image: local/sonic-vm\n    digest: (sha256:[0-9a-f]{64})', text)
if not old:
    sys.exit("sonic_vm pin block not found in versions.lock.yaml")
old_digest = old.group(1)
text = text.replace(old_digest, digest)
open(lock, "w").write(text)
print(f"replaced {old_digest} -> {digest}")
PY
  if [[ -x "${ROOT_DIR}/scripts/lib/verify_pins.sh" ]]; then
    "${ROOT_DIR}/scripts/lib/verify_pins.sh" || {
      echo "[sonic-vm] ERROR: verify_pins failed after pin update; restoring backup" >&2
      mv "${LOCK}.bak" "$LOCK"
      exit 1
    }
  fi
  echo "[sonic-vm] pin updated and verified (backup at ${LOCK}.bak)"
fi

echo "[sonic-vm] done. Next: scripts/provision.sh --profile sonic-vm"
