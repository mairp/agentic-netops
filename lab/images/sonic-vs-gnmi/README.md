# sonic-vs-gnmi — the SRv6/gNMI-qualified lab image

**Currently pinned** (`versions.lock.yaml` `sonic_images.sonic_vs`):
`localhost:5000/sonic-vs-gnmi:202505-v1@sha256:d1043aed28c98071c997a46d7e9e47823abacb06c31c068183541f8b5b5529e8`.

## Why this image exists

The clean upstream 202505 VS image ships **no gNMI server**, so
`scripts/lib/qualify.sh` has nothing to talk to without this layer. The former
202605 base carried gNMI but was an ASan debug build whose manager daemons could
abort under load. The current image combines the clean 202505 base with the
already-qualified gNMI userspace from the immutable 202605-v2 image.

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
| base image | `localhost:5000/sonic-vs:202505-clean-1207609@sha256:0fc84322…` (`sonic_vs_base`) |
| telemetry binary | built from `github.com/sonic-net/sonic-gnmi` @ `dd99be1` |
| telemetry runtime | qualified binary, schema, and exact private shared-library closure extracted from immutable `sonic-vs-gnmi:202605-v2@sha256:30c29456…` |

## What it adds

- `/usr/sbin/telemetry` + `/usr/sbin/schema` (CVL YANG schema dir)
- `/usr/bin/telemetry.sh` — reads `TELEMETRY` from `/etc/sonic/config_db.json`
  (file-based, so it starts before redis), selects TLS vs plaintext, and sets
  `YANG_MODELS_PATH=/usr/local/yang-models/` so `sonic-*` gNMI paths resolve
- `/etc/supervisor/conf.d/telemetry.conf` — `[program:telemetry]`

## Verified (2026-09-04)

- `supervisorctl status telemetry` → RUNNING; listening on `:8080`
- `gnmic -a <node>:8080 --skip-verify -u admin -p admin capabilities` →
  gNMI 0.7.0, OpenConfig acl/lldp/platform/system + `sonic-db`
- `/usr/local/yang-models/sonic-srv6.yang` present (144 models)
- SONiC managers are not linked to ASan; zero `AddressSanitizer` log entries
- unwaived fabric verification passes Type-2/3/5, remote VTEPs, and overlay traffic

## Rebuild

The tracked driver recreates the compatibility context from immutable images,
including the private telemetry library closure, and builds `Dockerfile.compat`:

    lab/images/sonic-vs-gnmi/build-compat.sh

Set `PUSH=1` to push after building. `SOURCE_IMAGE`, `BASE_IMAGE`, and
`OUTPUT_IMAGE` can override the pinned defaults.

After a rebuild, push and re-pin:

    PUSH=1 lab/images/sonic-vs-gnmi/build-compat.sh
    docker inspect --format '{{index .RepoDigests 0}}' localhost:5000/sonic-vs-gnmi:202505-v1

then update `versions.lock.yaml` (`sonic_images.sonic_vs` + the `sonic_yang.compatibility` row), `lab/topology.clab.yml`, and `lab/profiles/sonic-vs/profile.yaml` with the new digest.

## Compatibility layer (2026-09-04)

`Dockerfile.compat` isolates the 202605 telemetry libraries under
`/opt/agentic-netops/telemetry/lib`; only telemetry receives that
`LD_LIBRARY_PATH`, so clean 202505 SONiC daemons are not contaminated. It also
starts dbus and sonic-host-server for the GCU write path. After rebuilding,
re-pin the digest in `versions.lock.yaml`, `lab/topology.clab.yml`, and
`lab/profiles/sonic-vs/profile.yaml`, then run `make verify-pins`.

Bootstrap requirements for a working write path remain:
DEVICE_METADATA.localhost.switch_type=npu, cert paths with ".cer" suffix, and no
TELEMETRY|CLIENTS table in CONFIG_DB (see profile.yaml notes).
