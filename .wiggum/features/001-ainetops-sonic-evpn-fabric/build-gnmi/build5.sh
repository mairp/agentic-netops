#!/usr/bin/env bash
# build5.sh — resume build4 after the libyang header fix.
#
# build4 FAILED at `go install .../telemetry` with exactly:
#   yparser.go:1014:64: error: 'LYD_VALIDATE_NOEXTDEPS' undeclared
# Root cause: the staged libyang headers were unpatched upstream libyang 3.9.1.
# The pinned image ships the SONiC-built libyang3 3.12.2-1, which is upstream
# libyang 3.12.2 PLUS sonic-buildimage patch src/libyang3/patch/
#   0001-pr2362-lyd_validate_noextdeps.patch
# (adds `#define LYD_VALIDATE_NOEXTDEPS 0x0040` — bypass leafref/when/must
# external-dependency validation, re-adding libyang1's LYD_OPT_NOEXTDEPS).
# The vendored sonic-mgmt-common@cdb612e CVL code is written against exactly
# that patched libyang3 (it calls lyd_validate_all() with LYD_VALIDATE_NOEXTDEPS).
#
# build5 therefore:
#   (1) stages libyang v3.12.2 headers + SONiC pr2362 patch (header side only —
#       the runtime libyang.so.3 is the image's own SONiC-built 3.12.2 library,
#       already staged at /libs/libyang.so.3.9.1 and linked via -L/libs -lyang);
#   (2) re-runs `make` in the existing build container (vendor/.done is always
#       re-run because swsscommon_wrap has no file target, so the vendor tree is
#       re-vendored and the 0002/0004 vendor patches re-apply cleanly; Go's
#       build cache makes only the 3 changed cgo packages recompile);
#   (3) verifies the telemetry binary linkage;
#   (4) assembles localhost:5000/sonic-vs-gnmi:202605 from the pinned base and
#       pushes it to the local registry (so it gets a stable RepoDigest);
#   (5) smoke tests the telemetry service (supervisord + port 8080).
set -uo pipefail
BASE=/root/ainetops-demo/.wiggum/features/001-ainetops-sonic-evpn-fabric/build-gnmi
LOG=${1:-$BASE/build5.log}
CONT=ainetops-gnmi-build
PINNED=localhost:5000/sonic-vs:202605@sha256:097d1551398223969624a8095b37e60351b1629845c1e62e1f437decc1fb873b
IMAGENAME=localhost:5000/sonic-vs-gnmi
TAG=202605

log() { echo "[build5] $(date -u +%Y-%m-%dT%H:%M:%SZ) $*" | tee -a "$LOG"; }
fail() { log "FAILED: $*"; exit 1; }
rcnt() { docker exec $CONT bash -c "$1" 2>&1 | tee -a "$LOG"; }

export DOCKER_BUILDKIT=0

# --- 1. libyang v3.12.2 + SONiC pr2362 headers -------------------------------
# Header set = upstream 3.12.2 (git src headers, patched with SONiC pr2362) plus
# the two build-generated headers (ly_config.h, version.h) taken from the
# libyang-dev 3.12.2-1 .deb (same version as the image's SONiC-built libyang3).
if ! rcnt "test -d /tmp/ly3122/src"; then
  rcnt "cd /tmp && rm -rf ly3122 && git clone -q --depth 1 --branch v3.12.2 https://github.com/CESNET/libyang.git ly3122 && ls ly3122/src/libyang.h" \
    || fail "clone libyang v3.12.2"
fi
P=/tmp/sbi/src/libyang3/patch/0001-pr2362-lyd_validate_noextdeps.patch
rcnt "cd /tmp/ly3122 && P=$P; if git apply \$P 2>/dev/null; then echo PR2362-APPLIED; elif git apply --check \$P 2>/dev/null; then echo PR2362-PATCH-ERROR; exit 1; else echo PR2362-ALREADY-APPLIED; fi" \
  || fail "apply pr2362 patch"
rcnt "grep -c 'define LYD_VALIDATE_NOEXTDEPS 0x0040' /tmp/ly3122/src/parser_data.h" \
  || fail "pr2362 not visible in header"
# Extract the 3.12.2-1 dev .deb on the host (generated headers live there).
# NOTE: in upstream libyang, version.h LY_VERSION is the SOVERSION
# (@LIBYANG_SOVERSION_FULL@ = "3.9.1" across the 3.x ABI series), NOT the
# project version — verified against the official deb.debian.org package and
# the v3.12.2 source (src/version.h.in). The package control metadata
# ("Version: 3.12.2-1") is the authoritative project version.
DEVX=$BASE/debs/dev3122
rm -rf "$DEVX"; mkdir -p "$DEVX"
( cd "$DEVX" && dpkg-deb -x "$BASE/debs/libyang-dev_3.12.2-1_amd64.deb" . ) || fail "extract libyang-dev 3.12.2-1 deb"
# NOTE: no `grep -q` in a pipe here — pipefail + early-exit grep SIGPIPEs the
# producer (exit 141) and fails the check spuriously.
[[ "$(dpkg-deb -I "$BASE/debs/libyang-dev_3.12.2-1_amd64.deb" | grep ' Version: ')" == " Version: 3.12.2-1" ]] || fail "dev deb control is not 3.12.2-1"
grep -q 'LY_VERSION "3.9.1"' "$DEVX/usr/include/libyang/version.h" || fail "dev deb soversion mismatch (expected 3.9.1)"
docker cp "$DEVX/usr/include/libyang/." "$CONT:/tmp/hdr3122/" || fail "copy dev headers"
# Stage: deb header set as the base (it contains the full published set, incl.
# metadata.h and the generated ly_config.h/version.h), then overlay the git
# v3.12.2 headers WITH the SONiC pr2362 patch (adds LYD_VALIDATE_NOEXTDEPS to
# parser_data.h) plus the subdirectory headers the top-level headers include.
rcnt "set -e; rm -rf /opt/libyang-include; mkdir -p /opt/libyang-include/libyang; cp /tmp/hdr3122/* /opt/libyang-include/libyang/; cp /tmp/ly3122/src/*.h /opt/libyang-include/libyang/; cp -r /tmp/ly3122/src/plugins_exts /opt/libyang-include/libyang/; cp -r /tmp/ly3122/src/plugins_types /opt/libyang-include/libyang/; echo staged_headers=\$(ls /opt/libyang-include/libyang | wc -l); grep -l 'LYD_VALIDATE_NOEXTDEPS' /opt/libyang-include/libyang/parser_data.h; ls /opt/libyang-include/libyang/metadata.h; grep -c 'LIBYANG_API_DECL LY_ERR lyd_validate_all' /opt/libyang-include/libyang/parser_data.h; grep -m1 'LY_VERSION \"' /opt/libyang-include/libyang/version.h; ls /opt/libyang-include/libyang/ly_config.h" \
  || fail "stage patched headers"

# --- 2. Re-run make (canonical build path) ------------------------------------
rcnt "set -e; export PATH=/usr/local/go/bin:\$PATH; export CGO_ENABLED=1; export CGO_CFLAGS='-I/opt/libyang-include'; export LD_LIBRARY_PATH=/libs; cd /src/sonic-gnmi; rm -f build/bin/.formatcheck; make > /tmp/make5.log 2>&1 || { rc=\$?; tail -60 /tmp/make5.log; exit \$rc; }; echo MAKE_OK; tail -12 /tmp/make5.log" \
  || fail "make (see /tmp/make5.log)"

# --- 3. Verify binary + linkage ------------------------------------------------
rcnt "cd /src/sonic-gnmi && test -x build/bin/telemetry && test -s build/bin/telemetry && ls -la build/bin/telemetry && ldd build/bin/telemetry | grep -E 'swsscommon|hiredis|yang|not found'" \
  || fail "telemetry binary missing or unlinked"

# --- 4. Assemble + push image ---------------------------------------------------
# The telemetry binary's NEEDED entries include libboost_thread.so.1.74.0 and
# libboost_system.so.1.74.0 (linked from the bookworm build env); the pinned
# bookworm image does not ship them, so bundle them. libboost_serialization
# (1.83.0) and libpython3.11 already exist in the image.
STAGE=$BASE/stage
rm -rf $STAGE/*; mkdir -p $STAGE/schema $STAGE/boost-libs
docker cp $CONT:/src/sonic-gnmi/build/bin/telemetry $STAGE/telemetry || fail "copy telemetry binary"
rcnt "cp /tmp/cvl-schema/*.yin /stage/schema/ && echo schema_files=\$(ls /stage/schema | wc -l)" || fail "stage CVL schema"
cp $BASE/telemetry.service.sh $STAGE/telemetry.sh
cp $BASE/telemetry.conf $STAGE/telemetry.conf
cp $BASE/libs/libboost_thread.so.1.74.0 $STAGE/boost-libs/ || fail "stage boost-thread"
cp $BASE/libs/libboost_system.so.1.74.0 $STAGE/boost-libs/ || fail "stage boost-system"
cat > $STAGE/Dockerfile <<EOF
FROM $PINNED
COPY telemetry /usr/sbin/telemetry
COPY schema /usr/sbin/schema
COPY boost-libs/libboost_thread.so.1.74.0 /usr/lib/x86_64-linux-gnu/libboost_thread.so.1.74.0
COPY boost-libs/libboost_system.so.1.74.0 /usr/lib/x86_64-linux-gnu/libboost_system.so.1.74.0
COPY telemetry.sh /usr/bin/telemetry.sh
COPY telemetry.conf /etc/supervisor/conf.d/telemetry.conf
RUN chmod +x /usr/sbin/telemetry /usr/bin/telemetry.sh && \\
    ldd /usr/sbin/telemetry | grep -E 'swsscommon|hiredis|yang|boost|python|not found' || true
EOF
( cd $STAGE && docker build -t $IMAGENAME:$TAG . ) 2>&1 | tee -a "$LOG" || fail "docker build"
( cd $STAGE && docker push $IMAGENAME:$TAG ) 2>&1 | tee -a "$LOG" || fail "docker push"
NEWDIGEST=$(docker image inspect --no-trunc $IMAGENAME:$TAG --format '{{.RepoDigests}}' 2>/dev/null | head -1)
[[ -z $NEWDIGEST ]] && fail "no RepoDigest after push"
echo "$NEWDIGEST" > $BASE/image-digest.txt.new
log "new image digest: $NEWDIGEST"

# --- 5. Smoke test ---------------------------------------------------------------
docker rm -f ainetops-gnmi-smoke >/dev/null 2>&1 || true
docker run -d --name ainetops-gnmi-smoke $IMAGENAME:$TAG >/dev/null || fail "smoke run"
log "smoke: waiting 120s for supervisord + telemetry"
sleep 120
docker exec ainetops-gnmi-smoke bash -c 'supervisorctl status 2>&1 | grep -E "telemetry|redis-server|start.sh" || true; echo ---; tail -30 /var/log/telemetry-err.log 2>/dev/null || true; echo ---; (command -v ss >/dev/null && ss -ltn) 2>/dev/null | grep 8080 || (netstat -ltn 2>/dev/null | grep 8080) || echo "port 8080 not listening yet"' | tee -a "$LOG"
log "BUILD5 COMPLETE"
