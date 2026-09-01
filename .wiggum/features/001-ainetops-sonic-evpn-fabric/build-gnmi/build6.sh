#!/usr/bin/env bash
# build6.sh — regenerate ocbinds with the FULL sonic yang set so the telemetry
# binary can serve sonic-srv6 / sonic-telemetry / sonic-device_metadata / etc.
# paths (path_validator.go walks the COMPILED-IN ocbinds schema; the vendored
# ocbinds only contained 6 sonic modules). Also enriches /usr/local/yang-models
# with models_list + OC/annot yangs so OC paths register via
# annotToDbMapBuild.
#
# Stages:
#  A) extract the 144 sonic yangs from the pinned gnmi image into
#     /src/sonic-mgmt-common/build/yang/sonic/
#  B) ygot-generate a new ocbinds/ocbinds.go from build/yang (Makefile rule)
#  C) sync regenerated ocbinds into sonic-gnmi's vendored mgmt-common
#  D) rebuild telemetry (make with the build5i CGO_LDFLAGS line)
#  E) assemble + push localhost:5000/sonic-vs-gnmi:202606 with new binary and
#     complete /usr/local/yang-models (sonic set + OC set + annots + models_list)
#  F) smoke: run the image, create gNMI linux user + sshd, gnmic --insecure
#     capabilities/get on a sonic-srv6 path; PASS criterion = the response is
#     NOT "Node sonic-srv6 ... not found in the given gnmi path".
set -uo pipefail
BASE=/root/ainetops-demo/.wiggum/features/001-ainetops-sonic-evpn-fabric/build-gnmi
LOG=${1:-$BASE/build6.log}
CONT=ainetops-gnmi-build
GNMI_BASE=localhost:5000/sonic-vs-gnmi:202605@sha256:c04b9edd49bb0037ac9d01fde8715d4c37eb45d7a68710ba9d64ac27b1870768
IMAGENAME=localhost:5000/sonic-vs-gnmi
TAG=202606

log() { echo "[build6] $(date -u +%Y-%m-%dT%H:%M:%SZ) $*" | tee -a "$LOG"; }
fail() { log "FAILED: $*"; exit 1; }
rcnt() { docker exec $CONT bash -c "$1" 2>&1 | tee -a "$LOG"; }

export DOCKER_BUILDKIT=0

# --- A) extract sonic yang set from the pinned image --------------------------
log "A: extracting yang set from pinned image"
rm -rf $BASE/yang-from-image; mkdir -p $BASE/yang-from-image
docker run --rm --entrypoint tar "$GNMI_BASE" -cf - -C /usr/local yang-models \
  | tar xf - -C $BASE/yang-from-image/ || fail "extract yang-models"
N=$(ls $BASE/yang-from-image/yang-models/*.yang 2>/dev/null | wc -l)
log "A: extracted $N sonic yang files"
[[ $N -lt 100 ]] && fail "too few yang files ($N)"

# --- B) assemble build/yang + regenerate ocbinds ------------------------------
log "B: assembling build/yang in build container"
rcnt "mkdir -p /src/sonic-mgmt-common/build/yang/sonic" || fail "mkdir"
docker cp $BASE/yang-from-image/yang-models/. $CONT:/tmp/img-yang/ || fail "stage img-yang"
# copy only sonic-*.yang not already present (do not clobber sonic/common)
rcnt "cd /tmp/img-yang && for f in sonic-*.yang; do dest=/src/sonic-mgmt-common/build/yang/sonic/\$f; [ -e \"\$dest\" ] || cp \"\$f\" \"\$dest\"; done; ls /src/sonic-mgmt-common/build/yang/sonic | wc -l" || fail "copy sonic yangs"

log "B: regenerating ocbinds via ygot generator (this can take a long time)"
rcnt "set -e; export PATH=/usr/local/go/bin:\$PATH; cd /src/sonic-mgmt-common/translib; YANG_DIR=../build/yang; YANG_FILES=\$(find \$YANG_DIR -name '*.yang' -not -path '*/annotations/*'); echo \"yang file count: \$(echo \"\$YANG_FILES\" | wc -l)\"; go run --mod=vendor ../vendor/github.com/openconfig/ygot/generator/generator.go --logtostderr --output_file=ocbinds/ocbinds.go.new --package_name=ocbinds --generate_fakeroot --fakeroot_name=device --compress_paths=false --path=\$YANG_DIR --exclude_modules=ietf-interfaces,sonic-types,sonic-common \$YANG_FILES > /tmp/ygot.log 2>&1 || { rc=\$?; tail -80 /tmp/ygot.log; exit \$rc; }; mv ocbinds/ocbinds.go.new ocbinds/ocbinds.go; wc -l ocbinds/ocbinds.go; grep -c 'sonic-srv6\|SRV6' ocbinds/ocbinds.go" \
  || fail "ocbinds generation (see /tmp/ygot.log)"

# --- C) sync vendored ocbinds into sonic-gnmi ---------------------------------
log "C: syncing regenerated ocbinds into sonic-gnmi vendor"
rcnt "set -e; rm -rf /src/sonic-gnmi/vendor/github.com/Azure/sonic-mgmt-common/translib/ocbinds.new; cp -r /src/sonic-mgmt-common/translib/ocbinds /src/sonic-gnmi/vendor/github.com/Azure/sonic-mgmt-common/translib/ocbinds.new; rm -rf /src/sonic-gnmi/vendor/github.com/Azure/sonic-mgmt-common/translib/ocbinds; mv /src/sonic-gnmi/vendor/github.com/Azure/sonic-mgmt-common/translib/ocbinds.new /src/sonic-gnmi/vendor/github.com/Azure/sonic-mgmt-common/translib/ocbinds; ls /src/sonic-gnmi/vendor/github.com/Azure/sonic-mgmt-common/translib/ocbinds" \
  || fail "vendor sync"

# --- D) rebuild telemetry ------------------------------------------------------
log "D: rebuilding telemetry binary"
rcnt "set -e; export PATH=/usr/local/go/bin:\$PATH; export CGO_ENABLED=1; export CGO_CFLAGS='-I/opt/libyang-include'; export LD_LIBRARY_PATH=/libs; cd /src/sonic-gnmi; rm -f build/bin/.formatcheck; make CGO_LDFLAGS='-L/libs -lswsscommon -lhiredis -lzmq -lnl-3 -lnl-route-3 -lnl-nf-3 -lnftnl -Wl,-rpath,/lib/x86_64-linux-gnu' > /tmp/make6.log 2>&1 || { rc=\$?; tail -80 /tmp/make6.log; exit \$rc; }; echo MAKE_OK; ls -la build/bin/telemetry" \
  || fail "make telemetry (see /tmp/make6.log)"
rcnt "cd /src/sonic-gnmi && export LD_LIBRARY_PATH=/libs && ldd build/bin/telemetry > /tmp/ldd6.txt; grep -E 'swsscommon|hiredis|yang|boost|nl|nftnl|python' /tmp/ldd6.txt; if grep -q 'not found' /tmp/ldd6.txt; then echo LDD_NOT_FOUND; exit 1; else echo LDD_CLEAN; fi" \
  || fail "telemetry linkage"

# --- E) assemble image with complete models dir --------------------------------
log "E: assembling stage"
STAGE=$BASE/stage/6
rm -rf $STAGE; mkdir -p $STAGE/models
docker cp $CONT:/src/sonic-gnmi/build/bin/telemetry $STAGE/telemetry || fail "copy telemetry"
# models dir = image sonic set + OC set + annots + models_list
cp -r $BASE/yang-from-image/yang-models/. $STAGE/models/ || fail "base models"
rcnt "set -e; cd /src/sonic-mgmt-common/build/yang; cp -f *.yang /stage/6/models/ 2>/dev/null || true; cp -f extensions/*.yang /stage/6/models/ 2>/dev/null || true; cp -f common/*.yang /stage/6/models/ 2>/dev/null || true; cp -f annotations/*.yang /stage/6/models/ 2>/dev/null || true; ls /stage/6/models | wc -l" || fail "copy OC yangs"
# models_list: upstream list + excluded common deps (per translib Makefile)
cat $BASE/src/sonic-mgmt-common/config/transformer/models_list > $STAGE/models/models_list
rcnt "cd /src/sonic-mgmt-common/build/yang/sonic/common && for f in *.yang; do echo \"-\$f\"; done" >> $STAGE/models/models_list || true
log "E: models dir contents: $(ls $STAGE/models | wc -l) files; models_list lines: $(wc -l < $STAGE/models/models_list)"

rcnt "cp /tmp/cvl-schema/*.yin /stage/6/schema/ && echo schema_files=\$(ls /stage/6/schema | wc -l)" || { mkdir -p $STAGE/schema; }
cp $BASE/telemetry.service.sh $STAGE/telemetry.sh
cp $BASE/telemetry.conf $STAGE/telemetry.conf
cp $BASE/libs/libboost_thread.so.1.74.0 $STAGE/ || fail "boost-thread"
cp $BASE/libs/libboost_system.so.1.74.0 $STAGE/ || fail "boost-system"
cat > $STAGE/Dockerfile <<EOF
FROM $GNMI_BASE
COPY telemetry /usr/sbin/telemetry
COPY models /usr/local/yang-models
COPY schema /usr/sbin/schema
COPY libboost_thread.so.1.74.0 /usr/lib/x86_64-linux-gnu/libboost_thread.so.1.74.0
COPY libboost_system.so.1.74.0 /usr/lib/x86_64-linux-gnu/libboost_system.so.1.74.0
COPY telemetry.sh /usr/bin/telemetry.sh
COPY telemetry.conf /etc/supervisor/conf.d/telemetry.conf
RUN chmod +x /usr/sbin/telemetry /usr/bin/telemetry.sh
EOF
( cd $STAGE && docker build -t $IMAGENAME:$TAG . ) 2>&1 | tee -a "$LOG" || fail "docker build"
( cd $STAGE && docker push $IMAGENAME:$TAG ) 2>&1 | tee -a "$LOG" || fail "docker push"
DIGEST=$(curl -s -I -H 'Accept: application/vnd.docker.distribution.manifest.v2+json' http://localhost:5000/v2/sonic-vs-gnmi/manifests/$TAG | tr -d '\r' | awk 'tolower($1)=="docker-content-digest:"{print $2}')
[[ -z $DIGEST ]] && fail "no registry digest after push"
echo "$IMAGENAME:$TAG@$DIGEST" > $BASE/image-digest-202606.txt
log "new image: $IMAGENAME:$TAG@$DIGEST"

# --- F) smoke test --------------------------------------------------------------
log "F: smoke test"
docker rm -f ainetops-smoke-202606 >/dev/null 2>&1 || true
docker run -d --name ainetops-smoke-202606 $IMAGENAME:$TAG >/dev/null || fail "smoke run"
sleep 60
# telemetry starts insecure (no certs in config_db); create linux user + sshd for password auth
docker exec ainetops-smoke-202606 bash -c '
  useradd -m -s /bin/bash gnmitest 2>/dev/null || true
  echo "gnmitest:gnmitestpw" | chpasswd
  ssh-keygen -A >/dev/null 2>&1 || true; mkdir -p /var/run/sshd; /usr/sbin/sshd || true
' || fail "smoke user/sshd setup"
SIP=$(docker inspect ainetops-smoke-202606 --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}')
log "F: smoke container IP=$SIP"
{
  echo "--- capabilities:"; timeout 10 gnmic -a ${SIP}:8080 --insecure -u gnmitest -p gnmitestpw capabilities 2>&1 | head -8
  echo "--- get oc-interfaces:"; timeout 10 gnmic -a ${SIP}:8080 --insecure -u gnmitest -p gnmitestpw get --path /openconfig-interfaces:interfaces 2>&1 | head -8
} 2>&1 | tee -a "$LOG"
SMOKE=$(timeout 10 gnmic -a ${SIP}:8080 --insecure -u gnmitest -p gnmitestpw get --path /sonic-srv6:sonic-srv6/SRV6_GLOBAL/SRV6_GLOBAL_LIST[name=default] 2>&1 | tee -a "$LOG")
if echo "$SMOKE" | grep -q "not found in the given gnmi path"; then
  docker rm -f ainetops-smoke-202606 >/dev/null 2>&1 || true
  log "SMOKE_FAIL: sonic-srv6 path still unregistered in compiled schema"
  exit 1
fi
docker rm -f ainetops-smoke-202606 >/dev/null 2>&1 || true
log "SMOKE_OK: sonic-srv6 path resolved by the compiled schema (no 'Node not found in path')"
log "BUILD6 COMPLETE image=$IMAGENAME:$TAG@$DIGEST"
