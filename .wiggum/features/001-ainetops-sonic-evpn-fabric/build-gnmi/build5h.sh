#!/usr/bin/env bash
# build5g.sh — resume build5 after the LINK-stage fix.
#
# build5e FAILED at the link step with:
#   /usr/bin/ld: /libs/libswsscommon.so: undefined reference to `nl_msg_parse@libnl_3'
#   ... (all undefined refs carry version node "libnl_3")
# Root cause: the pinned community image builds libnl-3 / libnl-route-3 /
# libnl-nf-3 / libnftnl with the version script node "libnl_3" (verified with
# objdump -T on /libs/libswsscommon.so.0.0.0: every nl_*, rtnl_*, nfnl_*
# undefined symbol is versioned (libnl_3)). The Makefile's CGO_LDFLAGS only
# links -lswsscommon -lhiredis -lzmq, so the transitive libnl symbols were
# never provided at link time.
#
# build5g therefore:
#   (1) stages the IMAGE's own libnl-3/libnl-route-3/libnl-nf-3/libnl-cli-3/
#       libnftnl into /libs (same SONAMEs the runtime uses);
#   (2) re-runs make with CGO_LDFLAGS (command-line override of the Makefile's
#       `:=` assignment) adding -lnl-3 -lnl-route-3 -lnl-nf-3 -lnftnl;
#   (3) verifies the telemetry binary linkage (no "not found" in ldd);
#   (4) assembles localhost:5000/sonic-vs-gnmi:202605 from the pinned base and
#       pushes it to the local registry (stable RepoDigest);
#   (5) smoke tests the telemetry service (supervisord + port 8080).
set -uo pipefail
BASE=/root/ainetops-demo/.wiggum/features/001-ainetops-sonic-evpn-fabric/build-gnmi
LOG=${1:-$BASE/build5i.log}
CONT=ainetops-gnmi-build
PINNED=localhost:5000/sonic-vs:202605@sha256:097d1551398223969624a8095b37e60351b1629845c1e62e1f437decc1fb873b
IMAGENAME=localhost:5000/sonic-vs-gnmi
TAG=202605

log() { echo "[build5i] $(date -u +%Y-%m-%dT%H:%M:%SZ) $*" | tee -a "$LOG"; }
fail() { log "FAILED: $*"; exit 1; }
rcnt() { docker exec $CONT bash -c "$1" 2>&1 | tee -a "$LOG"; }

export DOCKER_BUILDKIT=0

# --- 1. libyang headers (idempotent re-check; build5 already staged) ----------
rcnt "test -d /opt/libyang-include/libyang && grep -c 'define LYD_VALIDATE_NOEXTDEPS 0x0040' /opt/libyang-include/libyang/parser_data.h" \
  || {
    # fall back to full build5 header staging if missing
    "$BASE/build5.sh" "$LOG.hdr" >/dev/null 2>&1 || fail "libyang header staging"
    rcnt "grep -c 'define LYD_VALIDATE_NOEXTDEPS 0x0040' /opt/libyang-include/libyang/parser_data.h" || fail "pr2362 not visible in header"
  }

# --- 1b. Stage image libnl family into /libs (link-time symbol providers) ----
log "staging image libnl/libnftnl into /libs"
docker run --rm --entrypoint tar "$PINNED" -cf - -C /lib/x86_64-linux-gnu \
  libnl-3.so.200.26.0 libnl-route-3.so.200.26.0 libnl-nf-3.so.200.26.0 libnl-cli-3.so.200.26.0 libnftnl.so.11.6.0 \
  | docker exec -i $CONT tar xf - -C /libs/ || fail "copy image libnl family"
rcnt "cd /libs && ln -sf libnl-3.so.200.26.0 libnl-3.so.200 && ln -sf libnl-3.so.200 libnl-3.so && ln -sf libnl-route-3.so.200.26.0 libnl-route-3.so.200 && ln -sf libnl-route-3.so.200 libnl-route-3.so && ln -sf libnl-nf-3.so.200.26.0 libnl-nf-3.so.200 && ln -sf libnl-nf-3.so.200 libnl-nf-3.so && ln -sf libnl-cli-3.so.200.26.0 libnl-cli-3.so.200 && ln -sf libnl-cli-3.so.200 libnl-cli-3.so && ln -sf libnftnl.so.11.6.0 libnftnl.so.11 && ln -sf libnftnl.so.11 libnftnl.so && ls -la /libs | grep -E 'libnl|nftnl'" \
  || fail "link libnl symlinks"

# --- 2. Re-run make with the libnl link line ----------------------------------
log "running make with extended CGO_LDFLAGS"
rcnt "set -e; export PATH=/usr/local/go/bin:\$PATH; export CGO_ENABLED=1; export CGO_CFLAGS='-I/opt/libyang-include'; export LD_LIBRARY_PATH=/libs; cd /src/sonic-gnmi; rm -f build/bin/.formatcheck; make CGO_LDFLAGS='-L/libs -lswsscommon -lhiredis -lzmq -lnl-3 -lnl-route-3 -lnl-nf-3 -lnftnl -Wl,-rpath,/lib/x86_64-linux-gnu' > /tmp/make5i.log 2>&1 || { rc=\$?; tail -60 /tmp/make5i.log; exit \$rc; }; echo MAKE_OK; tail -12 /tmp/make5i.log" \
  || fail "make (see /tmp/make5i.log)"

# --- 3. Verify binary + linkage ------------------------------------------------
rcnt "cd /src/sonic-gnmi rcnt "cd /src/sonic-gnmi && test -x build/bin/telemetryrcnt "cd /src/sonic-gnmi && test -x build/bin/telemetry export LD_LIBRARY_PATH=/libs; test -x build/bin/telemetry && test -s build/bin/telemetry && ls -la build/bin/telemetry && ldd build/bin/telemetry > /tmp/ldd5i.txt; grep -E 'swsscommon|hiredis|yang|boost|nl|nftnl|python' /tmp/ldd5i.txt; if grep -q 'not found' /tmp/ldd5i.txt; then echo LDD_NOT_FOUND; exit 1; else echo LDD_CLEAN; fi" \
  || fail "telemetry binary missing or unlinked"

# --- 4. Assemble + push image ---------------------------------------------------
# Runtime libraries: the image already ships libboost_serialization 1.83, the
# libnl family, libyang.so.3, libhiredis, libzmq, libpython3.11, libuuid,
# libpam. The telemetry binary additionally NEEDs libboost_thread/system
# 1.74.0 (linked from the build env), which the image does not ship — bundle.
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
    ldd /usr/sbin/telemetry | grep -E 'swsscommon|hiredis|yang|boost|nl|nftnl|python|not found' || true
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
log "smoke: waiting 150s for supervisord + redis + telemetry"
sleep 150
docker exec ainetops-gnmi-smoke bash -c 'supervisorctl status 2>&1 | grep -E "telemetry|redis-server|start" || true; echo ---; tail -40 /var/log/telemetry-err.log 2>/dev/null || true; echo ---; (command -v ss >/dev/null && ss -ltn) 2>/dev/null | grep 8080 || (netstat -ltn 2>/dev/null | grep 8080) || echo "port 8080 not listening yet"' | tee -a "$LOG"
docker rm -f ainetops-gnmi-smoke >/dev/null 2>&1 || true
log "BUILD5G COMPLETE"
