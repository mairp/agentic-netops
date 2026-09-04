#!/usr/bin/env bash
# Rebuild the ASan-free SONiC VS + gNMI compatibility image.
#
# The telemetry binary was built against the 202605 runtime. Recompiling it is
# unnecessary for the clean 202505 base: copy the binary, schema, and its exact
# shared-library closure from the immutable qualified source image, then keep
# those libraries private through telemetry.conf's LD_LIBRARY_PATH. SONiC's
# manager daemons continue to use the clean base's system libraries.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SOURCE_IMAGE=${SOURCE_IMAGE:-localhost:5000/sonic-vs-gnmi:202605-v2@sha256:30c294564ca75a020859c26b8c80494126f16c857907cc31498bbc0fd29c253e}
BASE_IMAGE=${BASE_IMAGE:-localhost:5000/sonic-vs:202505-clean-1207609@sha256:0fc843225270bbd0b6fd7c207e1642a9aee669c44d7a95b634c0f3b10b0447d9}
OUTPUT_IMAGE=${OUTPUT_IMAGE:-localhost:5000/sonic-vs-gnmi:202505-v1}

BUILD_CONTEXT=$(mktemp -d)
SOURCE_CONTAINER=agentic-netops-gnmi-compat-source-$$
cleanup() {
  docker rm -f "$SOURCE_CONTAINER" >/dev/null 2>&1 || true
  rm -rf "$BUILD_CONTEXT"
}
trap cleanup EXIT

mkdir -p "$BUILD_CONTEXT/schema" "$BUILD_CONTEXT/compat-libs"
docker create --name "$SOURCE_CONTAINER" "$SOURCE_IMAGE" >/dev/null
docker cp "$SOURCE_CONTAINER:/usr/sbin/telemetry" "$BUILD_CONTEXT/telemetry"
docker cp "$SOURCE_CONTAINER:/usr/sbin/schema/." "$BUILD_CONTEXT/schema/"

libraries=(
  libswsscommon.so.0.0.0
  libhiredis.so.0.14
  libyang.so.3.9.1
  libboost_serialization.so.1.83.0
  libboost_system.so.1.74.0
  libboost_thread.so.1.74.0
  libnftnl.so.11.6.0
  libnl-3.so.200.26.0
  libnl-cli-3.so.200.26.0
  libnl-nf-3.so.200.26.0
  libnl-route-3.so.200.26.0
  libpython3.11.so.1.0
)
for library in "${libraries[@]}"; do
  docker cp "$SOURCE_CONTAINER:/usr/lib/x86_64-linux-gnu/$library" "$BUILD_CONTEXT/compat-libs/$library"
done

pushd "$BUILD_CONTEXT/compat-libs" >/dev/null
ln -s libswsscommon.so.0.0.0 libswsscommon.so.0
ln -s libswsscommon.so.0 libswsscommon.so
ln -s libhiredis.so.0.14 libhiredis.so
ln -s libyang.so.3.9.1 libyang.so.3
ln -s libyang.so.3.9.1 libyang.so
ln -s libboost_serialization.so.1.83.0 libboost_serialization.so
ln -s libboost_system.so.1.74.0 libboost_system.so
ln -s libboost_thread.so.1.74.0 libboost_thread.so
ln -s libnftnl.so.11.6.0 libnftnl.so.11
ln -s libnftnl.so.11 libnftnl.so
for family in libnl-3 libnl-cli-3 libnl-nf-3 libnl-route-3; do
  versioned=$(find . -maxdepth 1 -name "$family.so.200.*" -printf '%f\n')
  ln -s "$versioned" "$family.so.200"
  ln -s "$family.so.200" "$family.so"
done
popd >/dev/null

cp "$SCRIPT_DIR/Dockerfile.compat" "$BUILD_CONTEXT/Dockerfile.compat"
cp "$SCRIPT_DIR/telemetry.sh" "$BUILD_CONTEXT/telemetry.sh"
cp "$SCRIPT_DIR/telemetry.conf" "$BUILD_CONTEXT/telemetry.conf"
cp "$SCRIPT_DIR/hostserver.conf" "$BUILD_CONTEXT/hostserver.conf"

docker build --build-arg "BASE_IMAGE=$BASE_IMAGE" -f "$BUILD_CONTEXT/Dockerfile.compat" -t "$OUTPUT_IMAGE" "$BUILD_CONTEXT"
if [[ "${PUSH:-0}" == "1" ]]; then
  docker push "$OUTPUT_IMAGE"
fi
docker image inspect --format '{{.Id}} {{json .RepoDigests}}' "$OUTPUT_IMAGE"
