# Data model

## Unchanged (intent side)

- `Network` (network.kubenet.dev/v1alpha1) — `spec.routers[]{name,l3vni,rd,routeTargets,prefixes}`,
  `spec.bridgeDomains[]{name,vlan,l2vni,evpn.routeTargets,irb}`, `spec.vlans[]{name,vlan}`,
  `spec.attachments[]{node,attachment,vrf,vlan}`, `spec.accessLists[]{name,stage,type,defaultAction,rules[]}`.
- kuid pools: `fabric-vlan` 100–4000, `evpn-vni` 10000–20000 (L2), L3VNI 10000–14094, `rt-index` 1–65535.
- Status: `conditions[Ready|Degraded]`, `observedGeneration`.

## Changed (device side, `pkg/fabricplan`)

```go
type Op struct {
    // gNMI Set. Updates are JSON-IETF values at SR Linux native paths.
    GNMI *GNMISet `json:"gnmi,omitempty"`
}
type GNMISet struct {
    Updates []GNMIUpdate `json:"updates,omitempty"`
    Deletes []string     `json:"deletes,omitempty"`
}
type GNMIUpdate struct {
    Path  string `json:"path"`
    Value any    `json:"value"`
}
type Check struct {
    Type     string `json:"type"`     // gnmi-equals | gnmi-contains | gnmi-exists | gnmi-list-min | gnmi-absent
    Path     string `json:"path"`
    Expect   string `json:"expect,omitempty"`
    MinCount int    `json:"minCount,omitempty"`
}
```

`NodePlan{Node, Ops, Checks, Rollback}` and `Plan{Nodes}` are unchanged.

## Derived names (deterministic, shared by apply/verify/rollback)

| Intent | Device |
|---|---|
| router `vrf-<hex>` | NI `Vrf-<10 chars>` (`DeviceVRFName`, unchanged) |
| bridgeDomain `<name>` vlan V | NI `<sanitised name>` if valid else `macvrf-<V>`; subinterface index V; vxlan-interface index = l2vni |
| local vlan V | NI `vlan-<V>`; subinterface index V |
| router l3vni N | attachment subinterface index/tag `L3VLANForVNI(N)`; vxlan-interface index N; evi N |
| acl for service S stage st | filter `DeviceACLTableName(S, st)` (unchanged), type `ipv4`/`ipv6` from `l3`/`l3v6` |

## Site pins ConfigMap `fabric-compat-pins`

Keys: `srlinux-image`, `srlinux-yang`, `mapping-version`, `kubenet-commit`,
`kuid-commit`, `sdc-release`, `topology-label-contract`,
`telemetry-label-contract`, `cap-sai-srv6` (`"false"`).
Annotation names: `agentic-netops.dev/srlinux-image`, `agentic-netops.dev/srlinux-yang`.

## Executor environment

`FABRIC_NODE_MAP` = `{"leaf01":"172.31.0.21:57400", ...}`; `FABRIC_GNMI_USER`,
`FABRIC_GNMI_PASS`, `FABRIC_GNMI_CA` (file path). `FABRIC_EXECUTOR_BIND` unchanged.
