import { useMemo, useState } from 'react'
import { Bot, Braces, Check, CircuitBoard, LocateFixed, Minus, Network, Plus, Route, ServerCog } from 'lucide-react'
import type { HealthState } from '../../App'
import type { AgentEvent } from '../../hooks/useAgentAPI'

type Props = {
  events: AgentEvent[]
  pending: boolean
  health: HealthState
}

type AgentNodeProps = {
  id: string
  title: string
  role: string
  active: boolean
  ready: boolean
  icon: typeof Bot
}

function AgentNode({ id, title, role, active, ready, icon: Icon }: AgentNodeProps) {
  return (
    <div className={`graph-node ${active ? 'active' : ''}`} data-node={id}>
      <div className="graph-node-icon"><Icon size={18} /></div>
      <div className="graph-node-copy"><strong>{title}</strong><span>{role}</span></div>
      <span className={`node-state ${active ? 'active' : ready ? 'ready' : ''}`}>
        {active ? 'WORKING' : ready ? <Check size={12} /> : 'IDLE'}
      </span>
    </div>
  )
}

function activeStage(events: AgentEvent[], pending: boolean) {
  if (!pending) return ''
  for (let index = events.length - 1; index >= 0; index -= 1) {
    const event = events[index]
    if (event.type === 'stage') return event.stage === 'deployer-tools' ? 'deployer' : event.stage
    if (event.type === 'confirmation_request') return event.stage
    if (event.type === 'clarification_request') return event.stage
  }
  return 'supervisor'
}

export default function MainArea({ events, pending, health }: Props) {
  const [zoom, setZoom] = useState(1)
  const active = activeStage(events, pending)
  const workers = health.workers
  const hasActivity = events.length > 0
  const workflowStatus = useMemo(() => {
    const last = events.at(-1)
    if (!last) return 'Ready for intent'
    if (last.type === 'error') return 'Action required'
    if (last.type === 'clarification_request') return 'Needs detail'
    if (last.type === 'final') return last.status.replaceAll('_', ' ')
    return pending ? 'Agents working' : 'Workflow paused'
  }, [events, pending])

  return (
    <section className="canvas-panel" aria-label="Agent topology">
      <div className="canvas-heading">
        <div><span className="eyebrow">LIVE ORCHESTRATION</span><h1>Agent-to-agent workflow</h1></div>
        <div className={`workflow-state ${pending ? 'active' : ''}`}><span />{workflowStatus}</div>
      </div>

      <div className="graph-viewport">
        <div className="dot-grid" />
        <div className="graph-scale" style={{ transform: `scale(${zoom})` }}>
          <div className="topology-flow">
            <AgentNode id="supervisor" title="Supervisor Agent" role="Intent coordinator" active={active === 'supervisor'} ready={health.status === 'ok'} icon={Bot} />
            <div className={`vertical-link ${pending ? 'active' : ''}`}><span /></div>
            <div className={`transport-rail ${pending ? 'active' : ''}`}>
              <span className="rail-label">A2A · {health.transport || 'SLIM'}</span>
            </div>
            <div className="worker-connectors"><i /><i /><i /></div>
            <div className="worker-row">
              <AgentNode id="mapper" title="Mapper Agent" role="Interpret intent" active={active === 'mapper'} ready={workers.mapper === 'ok'} icon={Route} />
              <AgentNode id="allocator" title="Allocator Agent" role="Claim identifiers" active={active === 'allocator'} ready={workers.allocator === 'ok'} icon={Braces} />
              <AgentNode id="deployer" title="Deployer Agent" role="Submit resources" active={active === 'deployer'} ready={workers.deployer === 'ok'} icon={ServerCog} />
            </div>
            <div className={`control-link ${active === 'deployer' ? 'active' : ''}`}><span /></div>
            <div className="control-plane-row">
              <div className="system-node"><CircuitBoard size={18} /><div><strong>Kubernetes controllers</strong><span>Continuous reconciliation</span></div></div>
              <div className={`system-arrow ${hasActivity ? 'active' : ''}`}><span>desired state</span></div>
              <div className="system-node fabric-node"><Network size={18} /><div><strong>SONiC fabric</strong><span>EVPN / VXLAN</span></div></div>
            </div>
          </div>
        </div>

        <div className="canvas-controls" aria-label="Canvas controls">
          <button onClick={() => setZoom(value => Math.min(1.2, value + 0.1))} title="Zoom in" aria-label="Zoom in"><Plus size={17} /></button>
          <button onClick={() => setZoom(value => Math.max(0.7, value - 0.1))} title="Zoom out" aria-label="Zoom out"><Minus size={17} /></button>
          <button onClick={() => setZoom(1)} title="Fit view" aria-label="Fit view"><LocateFixed size={17} /></button>
        </div>
      </div>
    </section>
  )
}
