#!/usr/bin/env bash
# build_gnmi.sh — Build the SONiC gNMI server (sonic-gnmi "telemetry" binary) from
# the sonic-buildimage 202605 branch (commit adcef327e) inside a build container
# based on the exact pinned VS image, so the runtime ABI matches the lab image.
#
# Stages:
#   1. build container from pinned VS image
#   2. apt build deps (swig, python3-dev, libhiredis-dev, protobuf-compiler, pyang, ...)
#   3. Go toolchain 1.25.9
#   4. source staging (sonic-mgmt-common, sonic-gnmi, swsscommon headers)
#   5. sonic-mgmt-common: go-deps, models, cvl, translib
#   6. sonic-gnmi: go-deps, telemetry server binary
#   7. extract artifacts
set -uo pipefail

WORK="/root/ainetops-demo/.wiggum/features/001-ainetops-sonic-evpn-fabric/tools/gnmi-build"
LOGFILE="$WORK/build.log"
SRC_GENCFG="/tmp/gen_cfg_schema.py"
SRC="/root/ainetops-demo/vendor/sonic-buildimage"
IMG="localhost:5000/sonic-vs:202605"
BC="ainetops-gnmi-build2"
GOVER="1.25.9"
JOBS="${SONIC_BUILD_JOBS:-8}"

mkdir -p "$WORK"
: > "$LOGFILE"
ts() { date -u +%H:%M:%S; }
log() { echo "[$(ts)] $*" | tee -a "$LOGFILE"; }
stage() { log "==== STAGE: $* ===="; }
fail() { log "FATAL: $*"; exit 1; }

rex() { docker exec "$BC" bash -c "$*"; }
rexlog() { local out; out=$(docker exec "$BC" bash -c "$*" 2>&1); local rc=$?; echo "$out" >> "$LOGFILE"; return $rc; }
rexlogtail() { local n="${1:-10}"; shift; local out; out=$(docker exec "$BC" bash -c "$*" 2>&1 | tail -n "$n"); local rc=$?; echo "$out" >> "$LOGFILE"; echo "$out" | tail -n 5; return $rc; }

# ---------- Stage 1: build container ----------
stage "build container from pinned VS image"
docker rm -f "$BC" >/dev/null 2>&1
docker create --entrypoint /bin/sleep --name "$BC" "$IMG" 86400 >/dev/null || fail "docker create"
docker start "$BC" >/dev/null || fail "docker start"

# ---------- Stage 2: apt build deps ----------
stage "apt build dependencies"
rexlogtail 3 'export DEBIAN_FRONTEND=noninteractive; apt-get update -qq >/dev/null 2>&1; apt-get install -y -qq git swig python3-dev python3-pip libhiredis-dev libboost-dev libpcre2-dev libcap-dev libacl1-dev cmake pkg-config g++ gcc make protobuf-compiler rsync patch xz-utils ca-certificates curl file >/dev/null 2>&1' || fail "apt install"
# pyang is not in this distro's repos; install via pip (pyang 2.x)
rexlogtail 5 'python3 -m pip install --quiet "pyang>=2.7,<3" 2>&1 | tail -n 2; pyang --version' || fail "pyang install"
log "apt deps installed"

# ---------- Stage 3: Go toolchain ----------
stage "Go toolchain $GOVER"
if ! rexlogtail 2 "command -v /usr/local/go/bin/go >/dev/null && /usr/local/go/bin/go version"; then
  rexlogtail 2 "curl -fsSL https://go.dev/dl/go${GOVER}.linux-amd64.tar.gz -o /tmp/go.tgz" || fail "go download"
  rexlogtail 2 "rm -rf /usr/local/go && tar -C /usr/local -xzf /tmp/go.tgz && /usr/local/go/bin/go version" || fail "go install"
fi

# ---------- Stage 4: source staging ----------
stage "stage sources (202605)"
rexlogtail 2 "mkdir -p /build /usr/share/swss /usr/include/swss" || fail "mkdir"
docker cp "$SRC/src/sonic-mgmt-common" "$BC:/build/sonic-mgmt-common" || fail "copy mgmt-common"
docker cp "$SRC/src/sonic-gnmi" "$BC:/build/sonic-gnmi" || fail "copy gnmi"
docker cp "$SRC/src/sonic-swss-common/pyext/swsscommon.i" "$BC:/usr/share/swss/swsscommon.i" || fail "copy swig iface"
# swsscommon C++ headers used by the swig-generated cgo wrapper
docker cp "$SRC/src/sonic-swss-common/common/." "$BC:/usr/include/swss/" || fail "copy swss headers"
docker cp "$SRC/src/sonic-swss-common/common" "$BC:/build/sonic-swss-common/common" 2>/dev/null || { mkdir -p "$BC" 2>/dev/null; docker exec "$BC" mkdir -p /build/sonic-swss-common && docker cp "$SRC/src/sonic-swss-common/common" "$BC:/build/sonic-swss-common/common" || fail "copy swss sibling"; }
docker cp "$SRC/src/sonic-swss-common/gen_cfg_schema.py" "$BC:/tmp/gen_cfg_schema.py" || fail "copy gen_cfg_schema"
docker cp "$SRC/src/libyang3/patch/0001-pr2362-lyd_validate_noextdeps.patch" "$BC:/tmp/ly-noextdeps.patch" || fail "copy ly patch"
# libyang 3.12.2 with sonic's LYD_VALIDATE_NOEXTDEPS patch (PR2362): build from the
# exact debian source the 202605 branch uses, so headers and runtime library match.
rexlogtail 6 'cd /tmp && curl -fsSL -o ly.xz http://deb.debian.org/debian/pool/main/liby/libyang/libyang_3.12.2.orig.tar.xz && rm -rf libyang-3.12.2 && tar xf ly.xz && cd libyang-3.12.2 && patch -p1 < /tmp/ly-noextdeps.patch && cmake -B build -DCMAKE_INSTALL_PREFIX=/usr -DBUILD_TESTING=OFF -DBUILD_EXAMPLES=OFF -DWITH_CLI=OFF -DWITH_PYTHON_EXT=OFF -DCMAKE_BUILD_TYPE=Release >/dev/null && cmake --build build -j8 2>&1 | tail -n 3 && cmake --install build >/dev/null && ldconfig && grep -c LYD_VALIDATE_NOEXTDEPS /usr/include/libyang/parser_data.h' || fail "libyang build"
# generate cfg_schema.h (auto-generated swss header, not shipped in the VS image)
rexlogtail 5 "python3 $SRC_GENCFG -d /usr/local/yang-models -o /usr/include/swss/cfg_schema.h 2>&1 | tail -n 5; grep -c define /usr/include/swss/cfg_schema.h" || fail "gen cfg_schema.h"
# dev symlinks for cgo linking (image ships runtime sonames only)
rexlogtail 2 'ln -sf /usr/lib/x86_64-linux-gnu/libswsscommon.so.0 /usr/lib/x86_64-linux-gnu/libswsscommon.so; ln -sf /usr/lib/x86_64-linux-gnu/libhiredis.so.0.14 /usr/lib/x86_64-linux-gnu/libhiredis.so; ln -sf /usr/lib/x86_64-linux-gnu/libpython3.11.so.1.0 /usr/lib/x86_64-linux-gnu/libpython3.11.so; ldconfig' || fail "dev symlinks"

# ---------- Stage 5: sonic-mgmt-common ----------
stage "sonic-mgmt-common go-deps (vendor)"
rexlogtail 20 "cd /build/sonic-mgmt-common && export PATH=/usr/local/go/bin:\$PATH GOPATH=/tmp/go GOFLAGS=-buildvcs=false && make go-deps 2>&1 | tail -n 25" || fail "mgmt-common go-deps"

stage "sonic-mgmt-common models"
rexlogtail 20 "cd /build/sonic-mgmt-common && export PATH=/usr/local/go/bin:\$PATH GOPATH=/tmp/go GOFLAGS=-buildvcs=false && make models 2>&1 | tail -n 25" || fail "mgmt-common models"

stage "sonic-mgmt-common cvl"
rexlogtail 20 "cd /build/sonic-mgmt-common && export PATH=/usr/local/go/bin:\$PATH GOPATH=/tmp/go GOFLAGS=-buildvcs=false && make NO_TEST_BINS=1 cvl 2>&1 | tail -n 25" || fail "mgmt-common cvl"

stage "sonic-mgmt-common translib"
rexlogtail 20 "cd /build/sonic-mgmt-common && export PATH=/usr/local/go/bin:\$PATH GOPATH=/tmp/go GOFLAGS=-buildvcs=false && make NO_TEST_BINS=1 translib 2>&1 | tail -n 25" || fail "mgmt-common translib"

# ---------- Stage 6: sonic-gnmi server ----------
stage "sonic-gnmi go-deps"
rexlogtail 25 "cd /build/sonic-gnmi && export PATH=/usr/local/go/bin:\$PATH GOPATH=/tmp/go GOFLAGS=-buildvcs=false CGO_LDFLAGS='-lswsscommon -lhiredis' CGO_CXXFLAGS='-I/usr/include/swss -w -Wall -fpermissive' && make go-deps 2>&1 | tail -n 30" || fail "gnmi go-deps"

stage "sonic-gnmi telemetry server"
rexlogtail 40 "cd /build/sonic-gnmi && export PATH=/usr/local/go/bin:\$PATH GOPATH=/tmp/go GOFLAGS=-buildvcs=false CGO_LDFLAGS='-lswsscommon -lhiredis' CGO_CXXFLAGS='-I/usr/include/swss -w -Wall -fpermissive' && make sonic-gnmi 2>&1 | tail -n 50" || fail "gnmi build"

# ---------- Stage 7: extract ----------
stage "extract artifacts"
rexlogtail 3 "ls -la /tmp/go/bin/ | head -20"
docker cp "$BC:/tmp/go/bin/telemetry" "$WORK/telemetry" || fail "copy telemetry"
docker cp "$BC:/build/sonic-mgmt-common/build/cvl/schema" "$WORK/cvl-schema" 2>/dev/null || true
log "binary: $(file "$WORK/telemetry" 2>/dev/null | head -1)"
log "BUILD_OK"
exit 0
