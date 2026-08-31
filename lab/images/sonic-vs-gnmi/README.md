# sonic-vs-gnmi — the SRv6/gNMI-qualified lab image

`localhost:5000/sonic-vs-gnmi:202605@sha256:c04b9edd49bb0037ac9d01fde8715d4c37eb45d7a68710ba9d64ac27b1870768`

## Why this image exists

The lab was pinned to `netreplica/docker-sonic-vs:20220111` (kept as
`sonic_vs_base` in `versions.lock.yaml`). That build ships **no gNMI server at
all**, so `scripts/lib/qualify.sh` had nothing to talk to and the capability gate
failed closed — correct behaviour, but it made SRv6 conformance (SC-013)
unprovable in this environment. The gap is a property of a build frozen since
January 2022, not a misconfiguration.

The upstream community `docker-sonic-vs.gz` artifacts (sonic.software, branches
202405/202411/202505/202511) do **not** close it either: they carry
`sonic-srv6.yang` but no telemetry binary, because upstream ships gNMI as a
separate `docker-sonic-telemetry` container. Verified 2026-08-31 against the
202505 build (build 1207609): `/usr/sbin/telemetry` absent, zero
`program:telemetry` entries.

So this image layers a `sonic-gnmi` telemetry server onto the pinned base.

## Provenance

| Component | Source |
|---|---|
| base image | `localhost:5000/sonic-vs:202605@sha256:097d1551…` (`sonic_vs_base`) |
| telemetry binary | built from `github.com/sonic-net/sonic-gnmi` @ `dd99be1` |
| build libs | the base image's own `libswsscommon`/`libnl-3`/`libnftnl`/`libyang` — the binary is linked against the runtime it will execute in |

## What it adds

- `/usr/sbin/telemetry` + `/usr/sbin/schema` (CVL YANG schema dir)
- `/usr/bin/telemetry.sh` — reads `TELEMETRY` from `/etc/sonic/config_db.json`
  (file-based, so it starts before redis), selects TLS vs plaintext, and sets
  `YANG_MODELS_PATH=/usr/local/yang-models/` so `sonic-*` gNMI paths resolve
- `/etc/supervisor/conf.d/telemetry.conf` — `[program:telemetry]`

## Verified (2026-08-31)

- `supervisorctl status telemetry` → RUNNING; listening on `:8080`
- `gnmic -a <node>:8080 --skip-verify -u admin -p admin capabilities` →
  gNMI 0.7.0, OpenConfig acl/lldp/platform/system + `sonic-db`
- `/usr/local/yang-models/sonic-srv6.yang` present (144 models)

## Rebuild

The build stages the telemetry binary out of a builder container that has the
base image's libraries, then assembles this Dockerfile. The full driver script
is `.wiggum/features/001-ainetops-sonic-evpn-fabric/build-gnmi/build5i.sh`;
`docker build` here needs `telemetry`, `schema/` and `boost-libs/` staged
alongside the Dockerfile first.

After a rebuild, push and re-pin:

    docker push localhost:5000/sonic-vs-gnmi:202605 && docker inspect --format '{{index .RepoDigests 0}}' localhost:5000/sonic-vs-gnmi:202605

then update `versions.lock.yaml` (`sonic_images.sonic_vs` + the `sonic_yang.compatibility` row), `lab/topology.clab.yml`, and `lab/profiles/sonic-vs/profile.yaml` with the new digest.
