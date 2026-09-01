#!/usr/bin/env bash
# Build the SONiC gNMI telemetry service (sonic-gnmi @ dd99be18, sonic-mgmt-common @
# cdb612e, swss-common headers @ 240a31a — all submodules of image commit adcef327e,
# branch 202605) and produce an updated sonic-vs image with the telemetry service
# wired into supervisord.
#
# Build container: debian:bookworm (matches the pinned image's Debian base) with
# build-essential/swig/go/pyang; links against the pinned image's own
# libswsscommon.so.0 / libhiredis.so.0.14 so the resulting binary resolves against
# the runtime libraries already present in the pinned rootfs.
set -uo pipefail

BASE=/root/ainetops-demo/.wiggum/features/001-ainetops-sonic-evpn-fabric/build-gnmi
SRC=$BASE/src
LIBS=$BASE/libs
LOG=$BASE/build.log
IMAGENAME=localhost:5000/sonic-vs
TAG=202605
PINNED=localhost:5000/sonic-vs:202605@sha256:097d1551398223969624a8095b37e60351b1629845c1e62e1f437decc1fb873b

log() { echo "[build] $*" | tee -a "$LOG"; }
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

if [[ ! -d $SRC/sonic-mgmt-common/.git ]]; then
  log "cloning sonic-mgmt-common"
  git clone -q https://github.com/sonic-net/sonic-mgmt-common.git $SRC/sonic-mgmt-common || fail "clone sonic-mgmt-common"
fi
( cd $SRC/sonic-mgmt-common && git checkout -q cdb612efcf6835f8dc3f004e214440ed8b744644 ) \
  || fail "checkout sonic-mgmt-common@cdb612e"
( cd $SRC/sonic-mgmt-common && git clean -qfdx 2>/dev/null || true )

( cd $SRC/sonic-swss-common && git checkout -q 240a31aacc28291de869f9583e2ed22aa8b620cc ) \
  || fail "checkout sonic-swss-common@240a31a"

# --- 2. Runtime libs from the pinned image ------------------------------------
mkdir -p $LIBS
if [[ ! -f $LIBS/libswsscommon.so.0 ]]; then
  log "extracting runtime libs from pinned image"
  docker cp "$PINNED:/lib/x86_64-linux-gnu/libswsscommon.so.0" $LIBS/ 2>/dev/null \
    || docker cp sonic-explore:/lib/x86_64-linux-gnu/libswsscommon.so.0 $LIBS/ || fail "copy libswsscommon"
  docker cp "$PINNED:/lib/x86_64-linux-gnu/libhiredis.so.0.14" $LIBS/ 2>/dev/null \
    || docker cp sonic-explore:/lib/x86_64-linux-gnu/libhiredis.so.0.14 $LIBS/ || fail "copy libhiredis"
fi
ln -sf libswsscommon.so.0 $LIBS/libswsscommon.so
ln -sf libhiredis.so.0.14 $LIBS/libhiredis.so

# --- 3. Build container --------------------------------------------------------
CONT=ainetops-gnmi-build
docker rm -f $CONT >/dev/null 2>&1 || true
log "creating build container (debian:bookworm)"
docker run -d --name $CONT \
  -v $SRC:/src -v $LIBS:/libs -v $BASE/stage:/stage \
  debian:bookworm sleep 2h >/dev/null || fail "docker run build container"

rcnt() { docker exec $CONT bash -c "$1" 2>&1 | tee -a "$LOG"; }

log "installing build tools"
rcnt "export DEBIAN_FRONTEND=noninteractive; apt-get update -qq && apt-get install -y -qq --no-install-recommends build-essential swig python3-pip ca-certificates curl >/dev/null && echo TOOLS_OK" \
  || fail "apt install build tools"
rcnt "gcc --version | head -1; swig -version | sed -n 2p"

log "installing Go 1.25.9"
rcnt "set -e; if [ ! -x /usr/local/go/bin/go ]; then curl -fsSL https://go.dev/dl/go1.25.9.linux-amd64.tar.gz -o /tmp/go.tgz && tar -C /usr/local -xzf /tmp/go.tgz; fi; /usr/local/go/bin/go version" \
  || fail "install go"

log "installing pyang"
rcnt "pip3 install --no-cache-dir --break-system-packages pyang jinja2 2>&1 | tail -1; python3 -c 'import pyang; print(\"pyang\", pyang.__version__)'" \
  || fail "install pyang"

log "staging swss-common headers + swig interface (pinned 240a31a)"
rcnt "set -e; rm -rf /opt/swss-include /opt/swss-i; mkdir -p /opt/swss-include /opt/swss-i; cp -r /src/sonic-swss-common/common/. /opt/swss-include/; cp /src/sonic-swss-common/goext/swsscommon.i /opt/swss-i/swsscommon.i; ls /opt/swss-include | wc -l" \
  || fail "stage swss headers"

# --- 4. sonic-mgmt-common: yang tree + CVL schema ------------------------------
log "building sonic-mgmt-common yang tree + CVL schema"
rcnt "set -e; cd /src/sonic-mgmt-common; make -C models/yang 2>&1 | tail -6; echo YANG_TREE:; ls build/yang; echo SONIC_COUNT: $(ls build/yang/sonic | wc -l); NO_TEST_BINS=1 make -C cvl schema 2>&1 | tail -12; echo SCHEMA_COUNT: $(ls build/cvl/schema | wc -l); ls build/cvl/schema | head -4" \
  || { log "mgmt-common build failed; dumping state"; rcnt "cd /src/sonic-mgmt-common; ls -la build 2>/dev/null; ls build/yang 2>/dev/null | head; find build -name '*.yin' 2>/dev/null | head"; fail "mgmt-common"; }

# --- 5. sonic-gnmi: go deps + telemetry binary ---------------------------------
log "building sonic-gnmi telemetry binary (go mod vendor + swig + cgo)"
rcnt "set -e; export PATH=/usr/local/go/bin:\$PATH; export CGO_ENABLED=1; export CGO_CFLAGS=\"-I/opt/swss-include -w -Wall -fpermissive\"; export CGO_LDFLAGS=\"-L/libs -lswsscommon -lhiredis -Wl,-rpath,/lib/x86_64-linux-gnu\"; export LD_LIBRARY_PATH=/libs; mkdir -p /usr/share/swss && mkdir -p /usr/share/swss && cp /opt/swss-i/swsscommon.i /usr/share/swss/swsscommon.i; cd /src/sonic-gnmi; sed -i 's|-I/usr/include/swss/|-I/opt/swss-include/|' swsscommon/Makefile; make > /tmp/make.log 2>&1; rc=$?; tail -50 /tmp/make.log; exit $rc" \
  || { log "sonic-gnmi build failed; dumping logs"; rcnt "cd /src/sonic-gnmi; tail -40 build/go_format.log 2>/dev/null; ls build 2>/dev/null"; fail "sonic-gnmi"; }

log "verifying telemetry binary linkage"
rcnt "set -e; cd /src/sonic-gnmi; LD_LIBRARY_PATH=/libs ./build/bin/telemetry -h 2>&1 | head -8 || true; LD_LIBRARY_PATH=/libs ./build/bin/telemetry --help 2>&1 | head -8 || true"

# --- 6. Assemble the updated image ---------------------------------------------
log "assembling updated image"
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

NEWDIGEST=$(docker images --digests --no-trunc $IMAGENAME:$TAG --format '{{.Digest}}' 2>/dev/null || docker image inspect --no-trunc $IMAGENAME:$TAG --format '{{.RepoDigests}}' | head -1)
log "new image digest: $NEWDIGEST"
echo "$NEWDIGEST" > $BASE/image-digest.txt.new

# --- 7. Smoke test --------------------------------------------------------------
log "smoke testing telemetry service in new image"
docker rm -f ainetops-gnmi-smoke >/dev/null 2>&1 || true
docker run -d --name ainetops-gnmi-smoke --network host $IMAGENAME:$TAG >/dev/null || fail "smoke run"
sleep 60
log "smoke: supervisord + telemetry status"
docker exec ainetops-gnmi-smoke bash -c 'supervisorctl status 2>&1 | grep -E "telemetry|redis-server|start.sh" || true; echo ---; tail -20 /var/log/telemetry-err.log 2>/dev/null || true; echo ---; (command -v ss >/dev/null && ss -ltn | grep 8080) || (netstat -ltn 2>/dev/null | grep 8080) || echo "port 8080 not listening yet"' | tee -a "$LOG"

log "BUILD COMPLETE"
