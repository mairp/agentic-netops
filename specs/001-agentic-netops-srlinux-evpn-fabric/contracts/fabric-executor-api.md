# Contract: fabric-executor HTTP API (SR Linux backend)

Unchanged surface: `GET /healthz`, `GET /readyz`, `GET /v1/nodes`,
`POST /v1/node/apply`, `POST /v1/node/verify`. Bind `:8084` on the host; the
provider reaches it at the kind bridge gateway (`172.30.0.1:8084`).

## Environment

| Variable | Meaning |
|---|---|
| `FABRIC_NODE_MAP` | JSON `{logical: "host:port"}`; unknown nodes are refused with 400 (permanent error for the controller) |
| `FABRIC_GNMI_USER` / `FABRIC_GNMI_PASS` | lab-generated credentials (Secret `gnmi-lab-creds`) |
| `FABRIC_GNMI_CA` | PEM file: containerlab CA (`gnmi-lab-tls/ca.crt`) |
| `FABRIC_GNMI_SKIP_VERIFY` | `true` only for local debugging; provision never sets it |
| `FABRIC_EXECUTOR_BIND` | default `:8084` |

## Apply

Request:
```json
{"node":"leaf01","ops":[{"gnmi":{"updates":[{"path":"/network-instance[name=vlan-130]","value":{"type":"mac-vrf","admin-state":"enable","interface":[{"name":"ethernet-1/3.130"}]}}],"deletes":[]}}]}
```
Semantics:
- Each op is one gNMI `SetRequest` (JSON_IETF; deletes first, then updates, as gNMI orders them). SR Linux commits atomically per request.
- Ops run in order; the first failing op stops the sequence. `results[i]` carries `{kind:"ops[i].gnmi", ok, output, error}` with the node's error string verbatim.
- After every op sequence that ended `ok`, the executor sends `Set update /tools/system/configuration/save` (value `{}`), reported as an extra result `kind:"save"`; a save failure marks the apply `ok:false`.
- Idempotency: SR Linux treats an update that matches running config as a no-op commit.

Response: `{"node":"leaf01","ok":true,"results":[...]}` (HTTP 200 even when `ok:false`; 4xx only for malformed requests / unknown node).

## Verify

Request:
```json
{"node":"leaf01","checks":[
  {"type":"gnmi-equals","path":"/network-instance[name=vlan-130]/oper-state","expect":"up"},
  {"type":"gnmi-list-min","path":"/tunnel-interface[name=vxlan1]/vxlan-interface[index=10150]/bridge-table/multicast-destinations/destination","minCount":1}
]}
```
Semantics per type (Get with `type: ALL`, encoding JSON_IETF, 10 s):
- `gnmi-equals`: the leaf value (string-compared; JSON scalars stringified) equals `expect`.
- `gnmi-contains`: the compact JSON body contains `expect` as a substring.
- `gnmi-exists`: at least one update with a non-null value.
- `gnmi-list-min`: the value is a JSON list with length ≥ `minCount` (default 1), or the update carries ≥ `minCount` list entries.
- `gnmi-absent`: the Get returns no value or a NotFound error; any other RPC error is a failed check with the error text.

Response: `{"node":"leaf01","ok":true,"results":[{"check":"checks[0].gnmi-equals","ok":true,"actual":"up"}]}`.

## Security posture (unchanged intent)

Only the system tier can reach `:8084` (iptables INPUT rule scoped to docker bridges, NetworkPolicy `allow-fabric-executor-egress`). The executor holds no docker socket. Credentials come from the environment set by `provision.sh`, never from the request.
