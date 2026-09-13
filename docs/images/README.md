# docs/images

## `lab-topology.svg` → `lab-topology.png`

`lab-topology.svg` is the source of truth for the topology diagram. It has been
redrawn for the Nokia SR Linux fabric: the four fabric nodes carry an
`SR Linux` label, the diagram is titled "Nokia SR Linux fabric", the port
badges name the containerlab links `e1-1`…`e1-4` (the node itself calls them
`ethernet-1/1`…`ethernet-1/4`), and the two wan clients are labelled `WAN`
rather than `SRv6`, because SRv6 is not applicable on this target.

**`lab-topology.png` has NOT been regenerated and is still the SONiC-era
raster.** Neither `rsvg-convert` nor `inkscape` (nor `cairosvg`) is available in
the environment where the SVG was edited, so the PNG could not be re-rendered
there. Until it is, the PNG embedded in `README.md` shows the old labels while
the SVG shows the current ones.

Regenerate it on a host that has one of them, and commit the result:

```bash
rsvg-convert -w 1860 docs/images/lab-topology.svg -o docs/images/lab-topology.png
# or
inkscape docs/images/lab-topology.svg --export-type=png --export-width=1860 \
  --export-filename=docs/images/lab-topology.png
```

## Screenshots

`grafana-fabric-telemetry.png`, `grafana-physical-fabric.png`,
`grafana-fabric-overview.png`, `grafana-srv6-service-path.png`,
`agent-ui.png` and `agent-ui-outcome.png` were captured on the previous (SONiC)
fabric. The Grafana captures show series that no longer exist on this target;
the console captures still show the intent tier faithfully, except that the
fabric node in the system diagram was labelled "SONiC fabric" at the time (the
UI now renders "SR Linux fabric").

They are replaced with SR Linux captures by task T044 of
`specs/001-agentic-netops-srlinux-evpn-fabric/tasks.md`, during the live
bring-up phase. Until then they are historical, not evidence about this fabric.
