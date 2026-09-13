The alerting rules are defined in
`deploy/observability/rules/agentic-netops.rules.yaml` and included via
ConfigMap in the Prometheus manifest. They cover fabric link loss, BGP session
loss (underlay eBGP and EVPN overlay iBGP), a silent gNMI target, provider
reconciliation failure and persistent deviation, unreachable SDC target,
topology-inventory mismatch, and gNMIc/OTel export failure.

There is deliberately no SRv6 rule: the SR Linux container has no SRv6 data
plane, so an SRv6 alert could never fire and would read as coverage this site
does not have.
