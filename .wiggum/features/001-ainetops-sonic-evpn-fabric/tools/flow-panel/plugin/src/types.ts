export interface FlowNode {
  name: string;
  role: string; // spine | leaf | client
}

export interface FlowEndpoint {
  node: string;
  if: string; // interface name, e.g. eth1
}

export interface FlowLink {
  source: FlowEndpoint;
  target: FlowEndpoint;
}

export interface FlowTopology {
  nodes: FlowNode[];
  links: FlowLink[];
}

export interface FlowPanelOptions {
  topology?: FlowTopology;
  // Optional: when true, the panel reads per-link state from its data query
  // (a vector with device/interface labels and numeric up/down values).
  useQueryState?: boolean;
}

export const defaultOptions: Partial<FlowPanelOptions> = {
  topology: { nodes: [], links: [] },
  useQueryState: true,
};
