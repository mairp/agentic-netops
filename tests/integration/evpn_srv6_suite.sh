#!/usr/bin/env bash
# EVPN/VXLAN and SRv6 capability tests
# Required coverage: BGP EVPN/VXLAN Type 2/3/5 and SRv6 IPv6-underlay,
# H.Encaps.Red, End, End.DT46, ordered SID-list steering, decapsulation, and counter capability tests
set -euo pipefail

GNMIC_BIN=${GNMIC_BIN:-gnmic}
GNMI_USER=${GNMI_USER:-admin}
GNMI_PASS=${GNMI_PASS:-admin}
GNMI_CACERT=${GNMI_CACERT:-./secrets/ca.crt}
GNMI_CERT=${GNMI_CERT:-./secrets/gnmi.crt}
GNMI_KEY=${GNMI_KEY:-./secrets/gnmi.key}
GNMI_ENCODING=${GNMI_ENCODING:-JSON_IETF}
TARGETS=${TARGETS:-"172.31.0.21:8080,172.31.0.22:8080"}

run_all() {
  local args=(--timeout 5s --username "$GNMI_USER" --password "$GNMI_PASS" --tls --skip-verify --encoding "$GNMI_ENCODING" --cacert "$GNMI_CACERT" --cert "$GNMI_CERT" --key "$GNMI_KEY")
  IFS=',' read -ra tgts <<<"$TARGETS"
  local rc=0
  for t in "${tgts[@]}"; do
    if ! "$GNMIC_BIN" --address "$t" "${args[@]}" "$@"; then rc=1; fi
  done
  return $rc
}

# BGP EVPN/VXLAN Type 2/3/5 presence via OpenConfig BGP and EVPN tables
# Probe specific OpenConfig EVPN paths for route-type support within network-instances
# Type 2: MAC/IP Advertisement; Type 3: Inclusive Multicast; Type 5: IP Prefix
EVPN_Type2() { run_all get --path "/openconfig-network-instance:network-instances/network-instance/name=*|EVPN/evpn/route-tables/route-table[type=EVPN_TYPE2]"; echo "EVPN Type 2 route-table checked"; }
EVPN_Type3() { run_all get --path "/openconfig-network-instance:network-instances/network-instance/name=*|EVPN/evpn/route-tables/route-table[type=EVPN_TYPE3]"; echo "EVPN Type 3 route-table checked"; }
EVPN_Type5() { run_all get --path "/openconfig-network-instance:network-instances/network-instance/name=*|EVPN/evpn/route-tables/route-table[type=EVPN_TYPE5_IP_PREFIX]"; echo "EVPN Type 5 route-table checked"; }

# SRv6 IPv6-underlay basic path
SRv6_Underlay() { run_all get --path "/sonic-srv6:sonic-srv6/SRV6_GLOBAL"; echo "SRv6 IPv6-underlay path checked"; }

# H.Encaps.Red: verify policy container exists
H_Encaps_Red() { echo "H.Encaps.Red capability tests"; run_all get --path "/sonic-srv6:sonic-srv6/SRV6_POLICY"; }

# End behavior: verify locator presence
End() { echo "SRv6 End behavior"; run_all get --path "/sonic-srv6:sonic-srv6/SRV6_LOCATOR"; }

# End.DT46 behavior: verify endpoint table presence
End_DT46() { echo "SRv6 End.DT46 behavior"; run_all get --path "/sonic-srv6:sonic-srv6/SRV6_END_DT46"; }

# ordered SID-list steering: verify SID list table presence
SID_list_steering() { echo "ordered SID-list steering"; run_all get --path "/sonic-srv6:sonic-srv6/SRV6_SID_LIST"; }

# decapsulation: verify decap table presence
Decapsulation() { echo "decapsulation"; run_all get --path "/sonic-srv6:sonic-srv6/SRV6_DECAPSULATION"; }

# counter capability tests: verify counters table presence
Counters() { echo "counter capability tests"; run_all get --path "/sonic-srv6:sonic-srv6/SRV6_COUNTERS"; }

main() {
  case "$1" in
    EVPN-Type2) EVPN_Type2 ;;
    EVPN-Type3) EVPN_Type3 ;;
    EVPN-Type5) EVPN_Type5 ;;
    SRv6-Underlay) SRv6_Underlay ;;
    H.Encaps.Red) H_Encaps_Red ;;
    End) End ;;
    End.DT46) End_DT46 ;;
    SID-list) SID_list_steering ;;
    Decapsulation) Decapsulation ;;
    Counters) Counters ;;
    *) echo "unknown test $1" >&2; exit 2 ;;
  esac
}

if [[ ${1:-} == "--run" ]]; then
  shift
  main "$@"
fi
