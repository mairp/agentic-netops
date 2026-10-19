# SONiC VM Profile — Bootstrap

Scope: identical service surface to sonic-vs — management reachability, TLS
materials, gNMI service enablement and persistence, PLUS the fabric bootstrap:
the lab carries today's services from bring-up. `configure-fabric.sh` writes
node identity (§7: hostnames, ASNs 65000/65101/65102, loopbacks, router-ids),
the fabric link addressing (same /31 + /127 plan as sonic-vs), the underlay BGP
(leaf 2 peers per family, spine 3 incl. the spine-spine iBGP over the
loopbacks), the leaf kernel SRv6 prerequisites, the per-node SRv6 locator with
its advertisement, and persists through `config save` + `config reload` +
re-assert. `tests/integration/fabric_baseline.sh --identity|--underlay|--locators`
checks all of it read-only.

VM-specific execution model (differs from sonic-vs):
- The containerlab `sonic-vm` kind runs a QEMU *launcher* container; SONiC runs
  inside a VM. `clab::bootstrap` docker-exec's `init-sonic-bootstrap.sh` into the
  launcher, which then provisions the guest over SSH (vrnetlab forwards guest
  port 22 into the launcher namespace; `sshpass` ships in the vrnetlab sonic
  image). vrnetlab resets the guest admin password to containerlab's `PASSWORD`
  env (default `admin`) during launch — the factory `YourPaSsWoRd` no longer
  works afterward. The guest is reachable on the **launcher's own mgmt IP**, not
  127.0.0.1 (the loopback→slirp path stalls); `SONIC_VM_GUEST_ADDR`,
  `SONIC_VM_ADMIN_USER` / `SONIC_VM_ADMIN_PASS` override the discovery/creds.
- TLS key/cert are installed into the guest's /etc/sonic/telemetry/ (mandatory
  .cer suffixes, same YANG validation as the VS profile).
- gNMI/telemetry is enabled via the **`GNMI` CONFIG_DB table** (`GNMI|gnmi` +
  `GNMI|certs`) in the guest (`config load` + `config save` for persistence),
  TLS only, JSON_IETF encoding. In the 202505 image `gnmi-native.sh` renders
  `telemetry_vars.j2` against `GNMI` — writing only the legacy `TELEMETRY`
  table leaves the table undefined and the server starts with `--noTLS`. The
  bootstrap applies both tables (`gnmi_config_db.json`) for compatibility.
  The gNMI account is created as a Linux user in the guest (PAM/sshd
  password auth), with the lab-generated credentials from gnmi_creds.json.
- Fabric configuration CANNOT use sonic-vs's configure-fabric-bgp.sh: it drives
  FRR/redis via docker exec, which cannot cross into the VM guest. The sonic-vm
  fabric bootstrap therefore runs on the HOST (`configure-fabric.sh`), talks to
  the guests through the same node_exec path as the tests (SSH into the
  launcher address), and writes only the write classes proven against the
  202505 image (scripts/spike/): GCU apply-patches (one remove/add pair per
  patch, whole-table re-adds), a silent locator remove then add in separate
  processes, vtysh re-assertions for the live-only FRR pieces, /proc writes for
  the kernel pieces, and a systemd (never `docker restart`) bgp unit restart
  only when bgpcfgd's render still carries the /64 loopback form.
- The fabric executor's SSH transport material is created once per bring-up by
  `install-executor-key.sh` (ed25519 pair + known_hosts under secrets/, 0600;
  `containerlab.sh destroy` removes them — guest host keys are fresh per lab).

Artifacts:
- gnmi_config_db.json — minimal CONFIG_DB snippet enabling gNMI/telemetry with TLS paths.
- install-gnmi-certs.sh — guest-side idempotent TLS installer (invoked over SSH).
- init-sonic-bootstrap.sh — launcher-side orchestrator (SSH into guest, run 1-4).
- configure-fabric.sh — host-side fabric bootstrap driven by
  ../fabric.yaml; `--dry-run` prints the per-node plan and writes nothing.
- install-executor-key.sh — per-lab executor SSH key + known_hosts material.

The image itself is built by scripts/build-sonic-vm.sh (vrnetlab, KVM required)
and pinned in versions.lock.yaml (sonic_images.sonic_vm + sonic_yang.compatibility).
