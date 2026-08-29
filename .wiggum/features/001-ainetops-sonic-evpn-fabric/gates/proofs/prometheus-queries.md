# Prometheus duplicate-series assertions (T063)

The following Prometheus query expressions assert that there is exactly one exporter path for device metrics and no duplicate time series per {device,interface,metric}.

- Distinct exporters per device for sonic metrics equals 1:

  expr: count without(instance) (count by(device, instance) (sonic_interface_packets_total{device!=""}))

  Expected: The result vector has one sample per device, each with value 1 and the device label present (e.g., device=spine01, spine02, leaf01, leaf02).

- No duplicate time series for same {device,interface} for packet metrics:

  expr: max by(device,interface) (count by(device,interface) (sonic_interface_packets_total{device!="",interface!=""}))

  Expected: Value is 1 for all device/interface combinations.

- No duplicate time series for same {device,interface} for octet metrics:

  expr: max by(device,interface) (count by(device,interface) (sonic_interface_octets_total{device!="",interface!=""}))

  Expected: Value is 1 for all device/interface combinations.

To collect a proof snapshot at runtime:

  kubectl --context kind-ainetops -n monitoring port-forward deploy/prometheus 9090:9090 &
  curl -s 'http://localhost:9090/api/v1/query?query=count%20without(instance)%20(count%20by(device%2C%20instance)%20(sonic_interface_packets_total%7Bdevice!%3D%22%22%7D))' | jq | nl -ba > .wiggum/features/001-ainetops-sonic-evpn-fabric/gates/proofs/prom-query-no-duplicates.json
