import { Bot, Braces, Check, Circle, Network, Route, ServerCog, ShieldCheck, Trash2, X } from 'lucide-react'
import type { HealthState } from '../../App'
import type { AgentEvent } from '../../hooks/useAgentAPI'

type Props = {
  open: boolean
  health: HealthState
  events: AgentEvent[]
  pending: boolean
  threadId: string | null
  onClose: () => void
  onClear: () => void
}

const stages = [
  { id: 'supervisor', label: 'Supervisor', detail: 'Intent routing', icon: Bot },
  { id: 'mapper', label: 'Mapper', detail: 'Service interpretation', icon: Route },
  { id: 'allocator', label: 'Allocator', detail: 'Identifier claims', icon: Braces },
  { id: 'deployer', label: 'Deployer', detail: 'Resource submission', icon: ServerCog },
] as const

function latestStage(events: AgentEvent[]) {
  for (let index = events.length - 1; index >= 0; index -= 1) {
    const event = events[index]
    if ('stage' in event && event.stage) {
      return event.stage === 'deployer-tools' ? 'deployer' : event.stage
    }
    if (event.type === 'confirmation_request') return event.stage
  }
  return events.length ? 'supervisor' : ''
}

export default function Sidebar({ open, health, events, pending, threadId, onClose, onClear }: Props) {
  const activeStage = latestStage(events)

  return (
    <aside className={`sidebar ${open ? 'open' : ''}`} aria-label="Agent navigation">
      <button className="sidebar-close" onClick={onClose} aria-label="Close navigation"><X size={18} /></button>

      <section className="sidebar-section conversation-section">
        <span className="section-label">CONVERSATION</span>
        <div className="conversation-title">Network provisioning</div>
        <div className="selected-nav-item"><Network size={16} /> Agent to Agent</div>
      </section>

      <section className="sidebar-section">
        <div className="section-heading">
          <span className="section-label">AGENT NETWORK</span>
          <span className="section-count">{health.status === 'ok' ? '4/4' : '--'}</span>
        </div>
        <div className="agent-list">
          {stages.map(({ id, label, detail, icon: Icon }) => {
            const workerState = id === 'supervisor' ? health.status : health.workers[id]
            const ready = id === 'supervisor' ? health.status === 'ok' : workerState === 'ok'
            const active = pending && activeStage === id
            return (
              <div className={`agent-list-item ${active ? 'active' : ''}`} key={id}>
                <div className="agent-list-icon"><Icon size={16} /></div>
                <div className="agent-list-copy"><strong>{label}</strong><span>{detail}</span></div>
                <span className={`status-dot ${active ? 'active' : ready ? 'ready' : 'muted'}`} title={active ? 'Active' : ready ? 'Ready' : 'Unavailable'} />
              </div>
            )
          })}
        </div>
      </section>

      <section className="sidebar-section">
        <span className="section-label">TRANSPORT</span>
        <div className="transport-summary">
          <div className="transport-icon"><ShieldCheck size={17} /></div>
          <div><strong>A2A over {health.transport || 'SLIM'}</strong><span>{health.status === 'ok' ? 'Secure channel ready' : 'Waiting for runtime'}</span></div>
          {health.status === 'ok' ? <Check size={15} className="ready-icon" /> : <Circle size={14} className="muted-icon" />}
        </div>
      </section>

      <section className="sidebar-section session-section">
        <div className="section-heading">
          <span className="section-label">SESSION</span>
          <button className="mini-icon-button" onClick={onClear} title="Clear conversation" aria-label="Clear conversation"><Trash2 size={14} /></button>
        </div>
        <div className="thread-id"><span>Thread</span><code>{threadId ? threadId.slice(0, 12) : 'New session'}</code></div>
      </section>
    </aside>
  )
}
