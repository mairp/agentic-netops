# grafana-flow-panel

AINETOPS physical fabric flow/topology panel plugin (Grafana >= 11).

Presentation-only visualization panel (FR-032 boundary: presentation pattern
reference; it is NOT an SR Linux runtime artifact and adds no runtime
dependency). The panel renders the topology embedded in its options by the
dashboard provisioning step (generated from containerlab metadata) and colors
links from an optional Prometheus state query (device/interface labels,
1=up 0=down).

## Build

    npm install
    npm run build        # -> dist/module.js (IIFE, global grafanaFlowPanelPlugin)

## Packaging (for the pinned Grafana image)

The plugin is baked into the AINETOPS Grafana image under
`/usr/share/grafana/plugins/grafana-flow-panel/` (unsigned; loaded via
`GF_PLUGINS_ALLOW_LOADING_UNSIGNED_PLUGINS`). The sha256 of the packaged zip
is the immutable pin recorded in `versions.lock.yaml` (tooling.grafana_flow_plugin).
