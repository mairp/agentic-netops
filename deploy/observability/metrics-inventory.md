# Metrics Inventory and Labels

This document inventories metrics from the pinned SONiC schema, SDC, provider, Kubernetes, containerlab, and SRv6 MySID counters. It defines bounded labels, topology joins, and required dashboards/alerts.

Sources and examples (series names are indicative; exporters must label consistently):

- SONiC (via gNMIc OTLP):
  - sonic_interface_packets_total{device,interface,dir}
  - sonic_interface_octets_total{device,interface,dir}
  - sonic_bgp_session_state{device,neighbor,state}
  - sonic_srv6_mysid_packets_total{device,sid,behavior}
- SDC:
  - sdc_target_reachable{target}
  - sdc_config_apply_total{target,result}
  - sdc_deviation_total{target,path}
- Provider (Go Prom client):
  - agentic_netops_sonicprovider_applies_total{}
  - controller_runtime_reconcile_errors_total{controller}
- Kubernetes:
  - up{job}
  - kube_pod_status_ready{namespace,pod}
- gNMIc exporter:
  - gnmic_output_errors_total{output}
  - gnmic_subscribe_errors_total{target}
- OTel Collector:
  - otelcol_exporter_queue_size{exporter}
  - otelcol_exporter_enqueue_failed{exporter}
  - otelcol_exporter_sent_metric_points{exporter}

Bounded labels and joins:
- device: one of {spine01, spine02, leaf01, leaf02}
- interface: Ethernet[0-9]+ on SONiC; joined to containerlab link map to derive peer
- neighbor: IPv4/IPv6 address string; joined to device by BGP sessions from intent
- sid: SRv6 endpoint SID; joined to SRv6Service intent
- pod/namespace: Kubernetes topology
- link (derived): nodeA:ifA<->nodeB:ifB constructed from containerlab inspect

Topology join:
- ConfigMap deploy/observability/topology-configmap.yaml contains nodes/links that can be loaded by Grafana Flow to render a physical fabric view and join series by {device,interface} labels.

Dashboards/alerts mapping:
- Physical fabric view (Grafana Flow): rate/utilization using sonic_interface_* metrics; node/link status bound to up and sonic_* state counters.
- SRv6 Service Path: MySID packet counters and active primary/alternate path state.
- Pipeline health: receiver/exporter health, queue fill, dropped/refused points, subscribe errors.
- Alerts: See deploy/observability/rules/agentic-netops.rules.yaml and prometheus.yaml rules.
