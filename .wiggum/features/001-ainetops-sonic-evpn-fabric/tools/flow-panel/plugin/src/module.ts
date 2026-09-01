import { PanelPlugin } from '@grafana/data';
import { FlowPanel } from './FlowPanel';
import { FlowPanelOptions, defaultOptions } from './types';

export const plugin = new PanelPlugin<FlowPanelOptions>(FlowPanel).setPanelOptions(
  (builder) => {
    builder.addJSONEditor({
      path: 'topology',
      name: 'Topology',
      description:
        'Embedded topology {"nodes":[{"name","role"}],"links":[{"source":{"node","if"},"target":{"node","if"}}]} generated from containerlab metadata at dashboard provisioning time.',
      defaultValue: defaultOptions.topology,
    });
    builder.addBooleanSwitch({
      path: 'useQueryState',
      name: 'Color links from query state',
      description: 'When enabled, per-link color comes from the panel data query (device/interface labels, 1=up 0=down).',
      defaultValue: defaultOptions.useQueryState,
    });
  }
);
