# SONiC VM Profile — Limited Bootstrap

Scope: identical to sonic-vs — management reachability, TLS materials, gNMI service
enablement, and persistence. No underlay/overlay control-plane or data-plane
configuration is applied by this profile; EVPN/SRv6 qualification drives
configuration over gNMI during qualification (scripts/lib/qualify.sh).

VM-specific execution model (differs from sonic-vs):
- The containerlab `sonic-vm` kind runs a QEMU *launcher* container; SONiC runs
  inside a VM. `clab::bootstrap` docker-exec's `init-sonic-bootstrap.sh` into the
  launcher, which then provisions the guest over SSH (vrnetlab forwards guest
  port 22 into the launcher namespace; `sshpass` ships in the vrnetlab sonic
  image; factory credentials `admin`/`YourPaSsWoRd` are overridable via
  `SONIC_VM_ADMIN_USER` / `SONIC_VM_ADMIN_PASS`).
- TLS key/cert are installed into the guest's /etc/sonic/telemetry/ (mandatory
  .cer suffixes, same YANG validation as the VS profile).
- gNMI/telemetry is enabled via TELEMETRY|gnmi + TELEMETRY|certs in the guest
  CONFIG_DB (`config load` + `config save` for persistence), TLS only, JSON_IETF
  encoding. The gNMI account is created as a Linux user in the guest (PAM/sshd
  password auth), with the lab-generated credentials from gnmi_creds.json.
- There is deliberately no configure-fabric-bgp.sh here: it drives FRR/redis via
  docker exec, which cannot cross into the VM guest. Fabric configuration is
  gNMI-driven by qualification.

Artifacts:
- gnmi_config_db.json — minimal CONFIG_DB snippet enabling gNMI/telemetry with TLS paths.
- install-gnmi-certs.sh — guest-side idempotent TLS installer (invoked over SSH).
- init-sonic-bootstrap.sh — launcher-side orchestrator (SSH into guest, run 1-4).

The image itself is built by scripts/build-sonic-vm.sh (vrnetlab, KVM required)
and pinned in versions.lock.yaml (sonic_images.sonic_vm + sonic_yang.compatibility).
