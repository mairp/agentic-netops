# Contract: telemetry (gnmic → Prometheus → Grafana)

`deploy/gnmi/gnmic.yaml` ConfigMap:

```yaml
username: ${GNMIC_USERNAME}
password: ${GNMIC_PASSWORD}
skip-verify: false
tls-ca: /etc/gnmic/tls/ca.crt
encoding: json_ietf
targets:
  spine01: {address: 172.31.0.11:57400}
  spine02: {address: 172.31.0.12:57400}
  leaf01:  {address: 172.31.0.21:57400}
  leaf02:  {address: 172.31.0.22:57400}
subscriptions:
  interface-stats:   {paths: [/interface[name=ethernet-1/*]/statistics], mode: stream, stream-mode: sample, sample-interval: 10s}
  interface-state:   {paths: [/interface[name=*]/oper-state, /interface[name=*]/subinterface[index=*]/oper-state], mode: stream, stream-mode: sample, sample-interval: 10s}
  bgp-neighbors:     {paths: [/network-instance[name=*]/protocols/bgp/neighbor[peer-address=*]/session-state, /network-instance[name=*]/protocols/bgp/neighbor[peer-address=*]/afi-safi[afi-safi-name=*]/received-routes], mode: stream, stream-mode: sample, sample-interval: 30s}
  platform:          {paths: [/platform/control[slot=*]/cpu[index=all]/total/instant, /platform/control[slot=*]/memory], mode: stream, stream-mode: sample, sample-interval: 30s}
outputs:
  prom: {type: prometheus, listen: :9273, path: /metrics, expiration: 60s, strings-as-labels: true,
         event-processors: [add-device-label]}
processors:
  add-device-label: {event-add-tag: {tags: {device: "{{ .Values.source }}"}}}
```
(the processor block is validated live; gnmic already labels series with
`source`, which the dashboards may use directly.)

Series the dashboards query (gnmic default naming, `_` joined path):
`interface_statistics_in_octets`, `interface_statistics_out_octets`,
`interface_statistics_in_packets`, `interface_statistics_out_packets`,
`interface_oper_state`, `network_instance_protocols_bgp_neighbor_session_state`,
`platform_control_cpu_total_instant`, `platform_control_memory_utilization`.
Labels: `source`, `interface_name`, `network_instance_name`, `neighbor_peer_address`, `subinterface_index`.

The `physical-fabric.json`, `srv6-service-path.json` (kept; panels show "not
applicable on SR Linux") and `sdc-orchestration.json` dashboards are updated
accordingly; `deploy/observability/metrics-inventory.md` lists the series.
