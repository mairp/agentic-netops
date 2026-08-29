#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=${1:-/root/ainetops-demo/vendor}
BRANCH=${BRANCH:-202405}
JOBS=${SONIC_BUILD_JOBS:-4}
PREFIX="$ROOT/sonic-buildimage"

if [[ ! -d "$PREFIX" ]]; then
  echo "Cloning sonic-buildimage $BRANCH into $PREFIX" >&2
  git clone --depth 1 --branch "$BRANCH" https://github.com/sonic-net/sonic-buildimage.git "$PREFIX"
else
  echo "Refreshing $PREFIX to $BRANCH" >&2
  cd "$PREFIX"
  git fetch origin "$BRANCH" --depth 1
  git reset --hard "origin/$BRANCH"
  git checkout -f "$BRANCH"
  cd - >/dev/null
fi
cd "$PREFIX"

# Do not pre-init submodules here; let 'make init' drive it for this branch

# Install build deps if needed (Debian/Ubuntu)
if ! command -v make >/dev/null; then
  apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y build-essential git ca-certificates curl python3-pip jq rsync
fi

# Initialize and configure for VS (disable EOL envs; use bookworm only)
NOJESSIE=1 NOSTRETCH=1 NOBUSTER=1 NOBULLSEYE=1 NOBOOKWORM=0 NOTRIXIE=1 make init
NOJESSIE=1 NOSTRETCH=1 NOBUSTER=1 NOBULLSEYE=1 NOBOOKWORM=0 NOTRIXIE=1 make configure PLATFORM=vs

# Build the docker-sonic-vs target only (bookworm)
NOJESSIE=1 NOSTRETCH=1 NOBUSTER=1 NOBULLSEYE=1 NOBOOKWORM=0 NOTRIXIE=1 make SONIC_BUILD_JOBS="$JOBS" target/docker-sonic-vs.gz

# Print the path of the artifact
ART="target/docker-sonic-vs.gz"
if [[ -f "$ART" ]]; then
  echo "ARTIFACT=$PWD/$ART"
else
  echo "Build did not produce $ART" >&2
  exit 2
fi
