import React, { useMemo } from 'react';
import { Data, DataFrame, FieldType, PanelProps } from '@grafana/data';
import { FlowPanelOptions } from './types';

interface NodePos {
  x: number;
  y: number;
}

const W = 1000;
const H = 420;

function tierY(role: string): number {
  switch (role) {
    case 'spine':
      return 80;
    case 'leaf':
      return 210;
    default:
      return 340;
  }
}

/**
 * Extract a map of "node/if" -> up(1)/down(0) from the panel data query result.
 * Accepts Prometheus-style frames whose rows carry device/interface labels and a
 * numeric value (sonic_interface_oper_status style, 1=up 0=down).
 */
function extractStates(data: Data | null | undefined): Map<string, number> {
  const states = new Map<string, number>();
  if (!data || !data.frames) {
    return states;
  }
  for (const frame of data.frames as DataFrame[]) {
    if (!frame.fields) {
      continue;
    }
    const labelField = frame.fields.find((f) => f.type === FieldType.labels);
    const valueField = frame.fields.find((f) => f.type === FieldType.number || f.type === FieldType.bullet);
    if (!valueField) {
      continue;
    }
    const len = frame.length;
    for (let i = 0; i < len; i++) {
      const labels = (labelField ? labelField.values.get(i) : {}) as Record<string, string> | null;
      const device = labels ? labels['device'] : undefined;
      const iface = labels ? labels['interface'] : labels ? labels['if'] : undefined;
      if (!device || !iface) {
        continue;
      }
      const v = Number(valueField.values.get(i));
      states.set(`${device}/${iface}`, Number.isFinite(v) ? v : 1);
    }
  }
  return states;
}

export function FlowPanel(props: PanelProps<FlowPanelOptions>) {
  const topology = props.options.topology ?? { nodes: [], links: [] };
  const states = useMemo(() => extractStates(props.data), [props.data]);

  const layout = useMemo(() => {
    const byRole: Record<string, string[]> = {};
    for (const n of topology.nodes) {
      const role = n.role || 'client';
      if (!byRole[role]) {
        byRole[role] = [];
      }
      byRole[role].push(n.name);
    }
    const pos = new Map<string, NodePos>();
    for (const [role, names] of Object.entries(byRole)) {
      const y = tierY(role);
      const step = W / (names.length + 1);
      names.forEach((name, i) => {
        pos.set(name, { x: step * (i + 1), y });
      });
    }
    return pos;
  }, [topology]);

  if (!topology.nodes.length) {
    return (
      <div className="flex justify-center items-center h-full text-muted">
        No topology embedded in panel options. Regenerate the dashboard from containerlab metadata.
      </div>
    );
  }

  const linkColor = (s: string, t: string): string => {
    if (!props.options.useQueryState || states.size === 0) {
      return '#73869d';
    }
    const sv = states.get(s);
    const tv = states.get(t);
    const known = [sv, tv].some((v) => v !== undefined);
    if (!known) {
      return '#73869d';
    }
    if ((sv ?? 1) < 1 || (tv ?? 1) < 1) {
      return '#e02f44';
    }
    return '#36a64f';
  };

  return (
    <div style={{ width: '100%', height: '100%' }}>
      <svg viewBox={`0 0 ${W} ${H}`} width="100%" height="100%" role="img" aria-label="AINETOPS physical fabric topology">
        {topology.links.map((l, i) => {
          const a = layout.get(l.source.node);
          const b = layout.get(l.target.node);
          if (!a || !b) {
            return null;
          }
          const sk = `${l.source.node}/${l.source.if}`;
          const tk = `${l.target.node}/${l.target.if}`;
          return (
            <g key={i}>
              <line x1={a.x} y1={a.y + 18} x2={b.x} y2={b.y - 18} stroke={linkColor(sk, tk)} strokeWidth={2} />
            </g>
          );
        })}
        {topology.nodes.map((n) => {
          const p = layout.get(n.name);
          if (!p) {
            return null;
          }
          const fill = n.role === 'spine' ? '#116378' : n.role === 'leaf' ? '#0d5e73' : '#3c1874';
          return (
            <g key={n.name}>
              <rect x={p.x - 44} y={p.y - 18} width={88} height={36} rx={6} fill={fill} stroke="#d1ddea" />
              <text x={p.x} y={p.y + 4} textAnchor="middle" fill="#ffffff" fontSize={13}>
                {n.name}
              </text>
            </g>
          );
        })}
      </svg>
      {props.options.useQueryState && states.size > 0 && (
        <div className="text-muted" style={{ fontSize: 11, textAlign: 'right' }}>
          {states.size} interface states from query
        </div>
      )}
    </div>
  );
}
