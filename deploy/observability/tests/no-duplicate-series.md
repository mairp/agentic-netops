# No duplicate device metric series

- SDC SyncProfile subscribe disabled: deploy/sdc/seed/sonic-schema.yaml (subscribe: {}).
- gNMIc is the only SONiC device metrics collector: deploy/gnmi/gnmic.yaml creates one Deployment labelled app.kubernetes.io/name=gnmic.
- Test: scripts/lib/observability.sh assert-single verifies there is exactly one gnmic Deployment and SDC subscribe is disabled.
- Prometheus queries asserting no duplicate series should be evaluated against the running Prometheus endpoint; save the results alongside this test plan.
