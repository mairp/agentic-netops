import { Check, ChevronDown, Copy, LoaderCircle, Send, Trash2, X } from 'lucide-react'
import { useMemo, useState } from 'react'
import type { AgentEvent, UseAgentAPI } from '../../hooks/useAgentAPI'

type Props = {
  agent: UseAgentAPI
  prompts: string[]
  /** Whether the conversation body is expanded (owned by App so the divider can react). */
  expanded: boolean
  onExpandedChange: (expanded: boolean) => void
  /** Divider-controlled conversation height in px (only applied while expanded). */
  chatHeight: number
}

function CorrelationChip({ correlationId }: { correlationId: string }) {
  const onCopy = async () => {
    try {
      await navigator.clipboard.writeText(correlationId)
    } catch {
      // Clipboard access is optional.
    }
  }
  return (
    <button className="correlation-chip" onClick={onCopy} title="Copy correlation id">
      <Copy size={11} /> {correlationId.slice(0, 8)}
    </button>
  )
}

function StageCard({ evt }: { evt: Extract<AgentEvent, { type: 'stage' }> }) {
  const details = evt.payload ?? evt.result
  return (
    <article className="event-card stage-event">
      <div className="event-card-heading">
        <span className="event-stage">{evt.stage === 'deployer-tools' ? 'deployer' : evt.stage}</span>
        <span className="event-status"><Check size={12} />{evt.status}</span>
        <CorrelationChip correlationId={evt.correlation_id} />
      </div>
      {evt.stage === 'deployer' && <p>Deployment in progress…</p>}
      {details && (
        <details open>
          <summary>{evt.stage === 'mapper' ? 'Interpretation' : evt.stage === 'allocator' ? 'Assignment' : 'Tool result'}</summary>
          <pre aria-label={evt.stage === 'mapper' ? 'interpretation-json' : evt.stage === 'allocator' ? 'assignment-json' : 'tools-result-json'}>{JSON.stringify(details, null, 2)}</pre>
        </details>
      )}
    </article>
  )
}

function Confirmation({ evt, onConfirm, onDecline }: { evt: Extract<AgentEvent, { type: 'confirmation_request' }>; onConfirm: () => void; onDecline: () => void }) {
  return (
    <article className="event-card confirmation-event">
      <div><span className="event-stage">Approval requested</span><p>{evt.prompt}</p></div>
      <div className="confirmation-actions">
        <button className="secondary-button" onClick={onDecline} aria-label={`decline-${evt.stage}`}><X size={15} />Decline</button>
        <button className="primary-button" onClick={onConfirm} aria-label={`confirm-${evt.stage}`}><Check size={15} />Confirm</button>
      </div>
    </article>
  )
}

function Clarification({ evt }: { evt: Extract<AgentEvent, { type: 'clarification_request' }> }) {
  return (
    <article className="event-card clarification-event">
      <div className="event-card-heading">
        <span className="event-stage">More detail needed</span>
        <CorrelationChip correlationId={evt.correlation_id} />
      </div>
      <p>{evt.prompt}</p>
      {evt.missing_fields.length > 0 && <small>Missing: {evt.missing_fields.join(', ')}</small>}
    </article>
  )
}

function FailureCard({ evt }: { evt: Extract<AgentEvent, { type: 'error' }> }) {
  return (
    <article className="event-card failure-event">
      <div className="event-card-heading"><span className="event-stage">{evt.stage} failed</span><CorrelationChip correlationId={evt.correlation_id} /></div>
      <p aria-label="failure-reason">{evt.reason}</p>
      {evt.suggestion && <small aria-label="failure-suggestion">Suggestion: {evt.suggestion}</small>}
    </article>
  )
}

function EventFeed({ events, agent }: { events: AgentEvent[]; agent: UseAgentAPI }) {
  return (
    <div className="event-feed" aria-live="polite">
      {events.map((event, index) => {
        if (event.type === 'stage') return <StageCard evt={event} key={index} />
        if (event.type === 'confirmation_request') return <Confirmation evt={event} onConfirm={() => void agent.confirm()} onDecline={() => void agent.decline()} key={index} />
        if (event.type === 'clarification_request') return <Clarification evt={event} key={index} />
        if (event.type === 'error') return <FailureCard evt={event} key={index} />
        if (event.type === 'progress') return <div className="feed-line" key={index}><LoaderCircle size={13} />{event.message || JSON.stringify(event.details || {})}</div>
        if (event.type === 'status') return <div className="feed-line muted" key={index}>{event.status}{event.stage ? ` · ${event.stage}` : ''}</div>
        return (
          <div className="feed-line final" key={index}>
            <Check size={13} />
            <span>{event.message || event.status}</span>
          </div>
        )
      })}
    </div>
  )
}

export default function Chat({ agent, prompts, expanded, onExpandedChange, chatHeight }: Props) {
  const [text, setText] = useState('')
  const [lastPrompt, setLastPrompt] = useState('')
  const hasDeclined = agent.events.some(event => event.type === 'error' && /declined/.test(event.reason || ''))
  const latestCorrelation = useMemo(() => [...agent.events].reverse().find(event => event.correlation_id)?.correlation_id, [agent.events])
  const hasConversation = agent.events.length > 0
  // A divider-dragged height only applies to a real conversation; the bare
  // composer keeps its natural size.
  const sized = hasConversation && expanded

  const submit = async (prompt = text) => {
    const cleanPrompt = prompt.trim()
    if (!cleanPrompt || agent.pending) return
    setLastPrompt(cleanPrompt)
    setText('')
    onExpandedChange(true)
    await agent.sendPrompt(cleanPrompt)
  }

  return (
    <section
      className={`chat-panel ${hasConversation && expanded ? 'expanded' : ''} ${sized ? 'sized' : ''}`}
      style={sized ? { height: `${Math.round(chatHeight)}px` } : undefined}
      aria-label="Agent conversation"
    >
      {hasConversation && (
        <div className="chat-header">
          <button className="chat-title" onClick={() => onExpandedChange(!expanded)} aria-expanded={expanded}>
            <ChevronDown size={16} className={expanded ? '' : 'collapsed'} />
            <span>Agent conversation</span>
            {latestCorrelation && <code>{latestCorrelation.slice(0, 8)}</code>}
          </button>
          <button className="mini-icon-button" onClick={() => { agent.clear(); setLastPrompt('') }} title="Clear conversation" aria-label="Clear conversation"><Trash2 size={15} /></button>
        </div>
      )}

      {hasConversation && expanded && (
        <div className="conversation-body">
          {lastPrompt && <div className="user-message"><span>You</span><p>{lastPrompt}</p></div>}
          <EventFeed events={agent.events} agent={agent} />
          {hasDeclined && <div className="cancelled-message">Request cancelled. Amend your intent and continue in the same thread.</div>}
        </div>
      )}

      <div className="composer-wrap">
        <div className="composer-meta">
          <label className="prompt-select">
            <span>Suggested prompts</span>
            <select value="" onChange={event => { if (event.target.value) void submit(event.target.value) }} disabled={agent.pending}>
              <option value="">Choose a network scenario</option>
              {prompts.map(prompt => <option value={prompt} key={prompt}>{prompt}</option>)}
            </select>
            <ChevronDown size={14} />
          </label>
          <span className="thread-label">Thread: {agent.threadId ? agent.threadId.slice(0, 8) : 'new'}</span>
        </div>
        <form className="composer" onSubmit={event => { event.preventDefault(); void submit() }}>
          <input
            aria-label="Service request"
            value={text}
            onChange={event => setText(event.currentTarget.value)}
            placeholder="Describe the service you want on the fabric…"
            disabled={agent.pending}
          />
          <button type="submit" disabled={!text.trim() || agent.pending} title="Send intent" aria-label="Send intent">
            {agent.pending ? <LoaderCircle className="spin" size={18} /> : <Send size={18} />}
          </button>
        </form>
      </div>
    </section>
  )
}
