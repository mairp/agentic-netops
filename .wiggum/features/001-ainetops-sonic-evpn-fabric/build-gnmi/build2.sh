#!/usr/bin/env bash
# build2.sh — fixed re-run of build.sh for the SONiC gNMI telemetry lab image.
#
# Fixes over build.sh (see build.log tail for the original failure):
#   1. apt install list adds: rsync (models/yang sync), patch + git (vendor
#      patching in sonic-gnmi Makefile), protobuf-compiler (gnoi-yang + proto
#      bindings).
#   2. Stage 5: the previous line passed an unescaped `$?`/`$rc` inside the
#      double-quoted rcnt string, which the OUTER shell (set -u) expanded and
#      aborted before the container step ran. All container-side variables are
#      escaped now; make failure is captured with `|| rc=$?` (set -e safe).
#   3. Stage 5: the top-level sonic-gnmi Makefile exports
#        export CGO_CXXFLAGS := -I/usr/include/swss -w -Wall -fpermissive
#        export CGO_LDFLAGS := -lswsscommon -lhiredis
#      which OVERRIDE the environment. Headers live in /opt/swss-include and
#      the runtime libs in /libs, so both are sed-patched in place.
#   4. Build container is REUSED when alive (avoids re-running apt/Go install).
#   5. Output image is tagged localhost:5000/sonic-vs-gnmi:202605 — a NEW
#      repository name, so the in-flight provision cycles that pin
#      localhost:5000/sonic-vs:202605@sha256:097d1551… are not disturbed.
#      Re-pinning versions.lock.yaml + lab/topology.clab.yml to the new
#      name@digest happens only after this image passes the unchanged
#      capability gate (spec Assumptions: conformance fallback is "another
#      pinned SONiC profile that passes the unchanged gate").
#
# Same pinned sources as build.sh:
#   sonic-gnmi @ dd99be18, sonic-mgmt-common @ cdb612e,
#   sonic-swss-common @ 240a31a (submodules of pinned image commit adcef327e).
set -uo pipefail

BASE=/root/ainetops-demo/.wiggum/features/001-ainetops-sonic-evpn-fabric/build-gnmi
SRC=$BASE/src
LIBS=$BASE/libs
LOG=${1:-$BASE/build2.log}
IMAGENAME=localhost:5000/sonic-vs-gnmi
TAG=202605
PINNED=localhost:5000/sonic-vs:202605@sha256:097d1551398223969624a8095b37e60351b1629845c1e62e1f437decc1fb873b

log() { echo "[build2] $*" | tee -a "$LOG"; }
fail() { log "FAILED: $*"; exit 1; }

export DOCKER_BUILDKIT=0

# --- 1. Source checkouts at the exact pinned commits -------------------------
if [[ ! -d $SRC/sonic-gnmi/.git ]]; then
  log "cloning sonic-gnmi"
  git clone -q https://github.com/sonic-net/sonic-gnmi.git $SRC/sonic-gnmi || fail "clone sonic-gnmi"
fi
( cd $SRC/sonic-gnmi && git checkout -q dd99be1841ca172dfac2fa7842afeeb5e532766c ) \
  || fail "checkout sonic-gnmi@dd99be18"
( cd $SRC/sonic-gnmi && git clean -qfdx 2>/dev/null || true )
# Restore pristine tree for repeatable patch application
( cd $SRC/sonic-gnmi && git checkout -q -- . 2>/dev/null || true )

if [[ ! -d $SRC/sonic-mgmt-common/.git ]]; then
  log "cloning sonic-mgmt-common"
  git clone -q https://github.com/sonic-net/sonic-mgmt-common.git $SRC/sonic-mgmt-common || fail "clone sonic-mgmt-common"
fi
( cd $SRC/sonic-mgmt-common && git checkout -q cdb612efcf6835f8dc3f004e214440ed8b744644 ) \
  || fail "checkout sonic-mgmt-common@cdb612e"
( cd $SRC/sonic-mgmt-common && git clean -qfdx 2>/dev/null || true )
( cd $SRC/sonic-mgmt-common && git checkout -q -- . 2>/dev/null || true )

( cd $SRC/sonic-swss-common && git checkout -q 240a31aacc28291de869f9583e2ed22aa8b620cc ) \
  || fail "checkout sonic-swss-common@240a31a"

# --- 2. Runtime libs from the pinned image ------------------------------------
# (docker cp cannot take a name@digest reference; use a throwaway container)
mkdir -p $LIBS
if [[ ! -f $LIBS/libswsscommon.so.0.0.0 || ! -f $LIBS/libhiredis.so.0.14 ]]; then
  log "extracting runtime libs from pinned image (via temp container)"
  docker rm -f ainetops-gnmi-libs >/dev/null 2>&1 || true
  docker create --name ainetops-gnmi-libs $PINNED >/dev/null || fail "create libs container"
  docker cp ainetops-gnmi-libs:/lib/x86_64-linux-gnu/libswsscommon.so.0.0.0 $LIBS/ \
    || fail "copy libswsscommon"
  if [[ ! -f $LIBS/libhiredis.so.0.14 ]]; then
    docker cp ainetops-gnmi-libs:/lib/x86_64-linux-gnu/libhiredis.so.0.14 $LIBS/ \
      || fail "copy libhiredis"
  fi
  docker rm ainetops-gnmi-libs >/dev/null 2>&1 || true
fi
ln -sf libswsscommon.so.0.0.0 $LIBS/libswsscommon.so.0
ln -sf libswsscommon.so.0 $LIBS/libswsscommon.so
ln -sf libhiredis.so.0.14 $LIBS/libhiredis.so

# --- 3. Build container (reused when alive) -----------------------------------
CONT=ainetops-gnmi-build
if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$CONT"; then
  log "reusing live build container $CONT"
else
  docker rm -f $CONT >/dev/null 2>&1 || true
  log "creating build container (debian:bookworm)"
  docker run -d --name $CONT \
    -v $SRC:/src -v $LIBS:/libs -v $BASE/stage:/stage \
    debian:bookworm sleep 96h >/dev/null || fail "docker run build container"
fi

rcnt() { docker exec $CONT bash -c "$1" 2>&1 | tee -a "$LOG"; }

log "installing build tools"
rcnt "export DEBIAN_FRONTEND=noninteractive; if command -v rsync >/dev/null && command -v swig >/dev/null && command -v git >/dev/null && command -v patch >/dev/null && command -v protoc >/dev/null && command -v gcc >/dev/null; then echo TOOLS_OK-CACHED; else apt-get update -qq && apt-get install -y -qq --no-install-recommends build-essential swig python3-pip ca-certificates curl rsync patch git protobuf-compiler >/dev/null && echo TOOLS_OK; fi" \
  || fail "apt install build tools"
rcnt "gcc --version | head -1; swig -version | sed -n 2p; protoc --version; git --version; patch --version | head -1"

log "installing Go 1.25.9"
rcnt "set -e; if [ ! -x /usr/local/go/bin/go ]; then curl -fsSL https://go.dev/dl/go1.25.9.linux-amd64.tar.gz -o /tmp/go.tgz && tar -C /usr/local -xzf /tmp/go.tgz; fi; /usr/local/go/bin/go version" \
  || fail "install go"

log "installing pyang"
rcnt "python3 -c 'import pyang' 2>/dev/null || pip3 install --no-cache-dir --break-system-packages pyang jinja2 >/dev/null 2>&1; python3 -c 'import pyang; print(\"pyang\", pyang.__version__)'" \
  || fail "install pyang"

log "staging swss-common headers + swig interface (pinned 240a31a)"
rcnt "set -e; rm -rf /opt/swss-include /opt/swss-i; mkdir -p /opt/swss-include /opt/swss-i; cp -r /src/sonic-swss-common/common/. /opt/swss-include/; cp /src/sonic-swss-common/goext/swsscommon.i /opt/swss-i/swsscommon.i; ls /opt/swss-include | wc -l" \
  || fail "stage swss headers"

# --- 4. sonic-mgmt-common: yang tree + CVL schema ------------------------------
log "building sonic-mgmt-common yang tree + CVL schema"
rcnt "set -e; cd /src/sonic-mgmt-common; rm -rf build; make -C models/yang > /tmp/mgmt-yang.log 2>&1 || { tail -30 /tmp/mgmt-yang.log; exit 1; }; echo YANG_TREE:; ls build/yang; echo SONIC_COUNT: $(ls build/yang/sonic | wc -l); NO_TEST_BINS=1 make -C cvl schema > /tmp/mgmt-cvl.log 2>&1 || { tail -30 /tmp/mgmt-cvl.log; exit 1; }; echo SCHEMA_COUNT: $(ls build/cvl/schema | wc -l); ls build/cvl/schema | head -4" \
  || { log "mgmt-common build failed; dumping state"; rcnt "cd /src/sonic-mgmt-common; ls -la build 2>/dev/null; ls build/yang 2>/dev/null | head; tail -20 build/yang.log 2>/dev/null"; fail "mgmt-common"; }
rcnt "test \$(ls /src/sonic-mgmt-common/build/yang/sonic/ 2>/dev/null | wc -l) -gt 0 && test \$(ls /src/sonic-mgmt-common/build/cvl/schema/ 2>/dev/null | wc -l) -gt 0 && echo YANG_CVL_OK" \
  || fail "yang tree / CVL schema empty"

# --- 5. sonic-gnmi: go deps + telemetry binary ---------------------------------
log "patching sonic-gnmi Makefile CGO paths for build container layout"
rcnt "set -e; cd /src/sonic-gnmi; sed -i 's|export CGO_CXXFLAGS := -I/usr/include/swss -w -Wall -fpermissive|export CGO_CXXFLAGS := -I/opt/swss-include -w -Wall -fpermissive|' Makefile; sed -i 's|export CGO_LDFLAGS := -lswsscommon -lhiredis|export CGO_LDFLAGS := -L/libs -lswsscommon -lhiredis -Wl,-rpath,/lib/x86_64-linux-gnu|' Makefile; grep -n 'CGO_CXXFLAGS\|CGO_LDFLAGS' Makefile | head -4" \
  || fail "patch Makefile"

log "building sonic-gnmi telemetry binary (go mod vendor + swig + cgo)"
rcnt "set -e; export PATH=/usr/local/go/bin:\$PATH; export CGO_ENABLED=1; export LD_LIBRARY_PATH=/libs; mkdir -p /usr/share/swss; cp /opt/swss-i/swsscommon.i /usr/share/swss/swsscommon.i; cd /src/sonic-gnmi; rc=0; make > /tmp/make.log 2>&1 || rc=\$?; tail -80 /tmp/make.log; exit \$rc" \
  || { log "sonic-gnmi build failed; dumping logs"; rcnt "cd /src/sonic-gnmi; tail -60 /tmp/make.log 2>/dev/null; tail -40 build/go_format.log 2>/dev/null; ls build 2>/dev/null"; fail "sonic-gnmi"; }

log "verifying telemetry binary linkage"
rcnt "set -e; cd /src/sonic-gnmi; ldd build/bin/telemetry | grep -E 'swsscommon|hiredis|not found' || true; LD_LIBRARY_PATH=/libs ./build/bin/telemetry -h 2>&1 | head -8 || true"

# --- 6. Assemble the updated image ---------------------------------------------
log "assembling updated image ($IMAGENAME:$TAG)"
STAGE=$BASE/stage
rm -rf $STAGE/*; mkdir -p $STAGE
cp $SRC/sonic-gnmi/build/bin/telemetry $STAGE/telemetry
cp -r $SRC/sonic-mgmt-common/build/cvl/schema $STAGE/schema
cp $BASE/telemetry.service.sh $STAGE/telemetry.sh
cp $BASE/telemetry.conf $STAGE/telemetry.conf
cat > $STAGE/Dockerfile <<EOF
FROM $PINNED
COPY telemetry /usr/sbin/telemetry
COPY schema /usr/sbin/schema
COPY telemetry.sh /usr/bin/telemetry.sh
COPY telemetry.conf /etc/supervisor/conf.d/telemetry.conf
RUN chmod +x /usr/sbin/telemetry /usr/bin/telemetry.sh && \\
    ldd /usr/sbin/telemetry | grep -E 'swsscommon|hiredis' || true
EOF
( cd $STAGE && docker build -q -t $IMAGENAME:$TAG . ) 2>&1 | tee -a "$LOG" || fail "docker build"

NEWDIGEST=$(docker image inspect --no-trunc $IMAGENAME:$TAG --format '{{.RepoDigests}}' 2>/dev/null | head -1)
[[ -z $NEWDIGEST ]] && NEWDIGEST=$(docker image inspect --no-trunc $IMAGENAME:$TAG --format '{{.Id}}')
log "new image digest: $NEWDIGEST"
echo "$NEWDIGEST" > $BASE/image-digest.txt.new

# --- 7. Smoke test --------------------------------------------------------------
log "smoke testing telemetry service in new image"
docker rm -f ainetops-gnmi-smoke >/dev/null 2>&1 || true
docker run -d --name ainetops-gnmi-smoke --network host $IMAGENAME:$TAG >/dev/null || fail "smoke run"
sleep 75
log "smoke: supervisord + telemetry status"
docker exec ainetops-gnmi-smoke bash -c 'supervisorctl status 2>&1 | grep -E "telemetry|redis-server|start.sh" || true; echo ---; tail -20 /var/log/telemetry-err.log 2>/dev/null || true; echo ---; (command -v ss >/dev/null && ss -ltn | grep 8080) || (netstat -ltn 2>/dev/null | grep 8080) || echo "port 8080 not listening yet"' | tee -a "$LOG"

log "BUILD COMPLETE"
