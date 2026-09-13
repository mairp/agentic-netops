# No duplicate device metric series

- SDC SyncProfile subscribe disabled: `deploy/sdc/seed/srlinux-schema.yaml`
  (`subscribe: {}`). Without this, SDC would subscribe to the same SR Linux
  gNMI paths as the collector and every device series would be produced twice.
- gNMIc is the only SR Linux device-metrics collector: `deploy/gnmi/gnmic.yaml`
  creates exactly one Deployment labelled `app.kubernetes.io/name=gnmic`.
- Test: `scripts/lib/observability.sh assert-single` verifies there is exactly
  one gnmic Deployment and that SDC subscribe is disabled.
- Prometheus queries asserting no duplicate series must be evaluated against the
  running Prometheus endpoint; save the results alongside this test plan. A
  useful one-liner once the stack is up:
  `count by(__name__) (count by(__name__, source, interface_name) (interface_statistics_in_octets)) `
  should equal the number of `(source, interface_name)` pairs, not twice it.
