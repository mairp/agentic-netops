import React from 'react'
import { useAgentAPI, AgentEvent } from '../../hooks/useAgentAPI'

function StageCard({ evt }: { evt: Extract<AgentEvent, { type: 'stage' }> }) {
  const { stage, payload, tool, result, status, correlation_id } = evt
  return (
    <div style={{ border: '1px solid #ddd', padding: '0.75rem', borderRadius: 8, marginBottom: '0.5rem' }}>
      <div style={{ display: 'flex', justifyContent: 'space-between' }}>
        <strong>{stage}</strong>
        <span style={{ fontSize: 12, color: '#666' }}>{status}</span>
      </div>
      {stage === 'mapper' && payload && (
        <pre aria-label="interpretation-json" style={{ whiteSpace: 'pre-wrap' }}>{JSON.stringify(payload, null, 2)}</pre>
      )}
      {stage === 'allocator' && payload && (
        <pre aria-label="assignment-json" style={{ whiteSpace: 'pre-wrap' }}>{JSON.stringify(payload, null, 2)}</pre>
      )}
      {stage === 'deployer' && (
        <p>Deployment in progress…</p>
      )}
      {stage === 'deployer-tools' && (
        <>
          <div style={{ fontSize: 12, color: '#444' }}>tool: {tool}</div>
          <pre aria-label="tools-result-json" style={{ whiteSpace: 'pre-wrap' }}>{JSON.stringify(result, null, 2)}</pre>
        </>
      )}
      <div style={{ marginTop: 4 }}>
        <CorrelationChip correlationId={correlation_id} />
      </div>
    </div>
  )
}


const TEST_IDS = {
  mapper: { confirm: 'confirm-mapper', decline: 'decline-mapper' },
  allocator: { confirm: 'confirm-allocator', decline: 'decline-allocator' },
  deployer: { confirm: 'confirm-deployer', decline: 'decline-deployer' }
} as const

function Confirmation({ evt, onConfirm, onDecline }: { evt: Extract<AgentEvent, { type: 'confirmation_request' }>, onConfirm: () => void, onDecline: () => void }) {
  return (
    <div style={{ border: '1px dashed #bbb', padding: '0.75rem', borderRadius: 8, marginBottom: '0.5rem', background: '#fafafa' }}>
      <div style={{ marginBottom: '0.5rem' }}>{evt.prompt}</div>
      <div>
        <button onClick={onConfirm} aria-label={`confirm-${evt.stage}`}>Confirm</button>
        <button onClick={onDecline} aria-label={`decline-${evt.stage}`} style={{ marginLeft: 8 }}>Decline</button>
      </div>
    </div>
  )
}

function FailureCard({ evt }: { evt: Extract<AgentEvent, { type: 'error' }> }) {
  const { stage, reason, suggestion, correlation_id } = evt
  return (
    <div style={{ border: '1px solid #f3cccc', background: '#fff6f6', padding: '0.75rem', borderRadius: 8, marginBottom: '0.5rem' }}>
      <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
        <strong>Failure — {stage}</strong>
        <div style={{ display: 'flex', gap: 8, alignItems: 'center' }}>
          <a href={`http://grafana.monitoring.svc:3000/d/intent-tier?correlation_id=${encodeURIComponent(correlation_id)}`} target="_blank" rel="noreferrer" style={{ fontSize: 12 }}>View in Grafana</a>
          <CorrelationChip correlationId={correlation_id} />
        </div>
      </div>
      <div style={{ marginTop: 4 }} aria-label="failure-reason">{reason}</div>
      {suggestion && <div style={{ marginTop: 4, fontSize: 13, color: '#444' }} aria-label="failure-suggestion">Suggestion: {suggestion}</div>}
    </div>
  )
}

function CorrelationChip({ correlationId }: { correlationId: string }) {
  const onCopy = async () => {
    try { await navigator.clipboard.writeText(correlationId) } catch {}
  }
  return (
    <span role="button" onClick={onCopy} title="Copy correlation id" style={{ fontSize: 12, background: '#eef', border: '1px solid #ccd', padding: '2px 6px', borderRadius: 999 }}>
      {correlationId.slice(0,8)}…{correlationId.slice(-4)}
    </span>
  )
}

export default function Chat() {
  const { events, pending, sendPrompt, confirm, decline, threadId, clear } = useAgentAPI()
  const [text, setText] = React.useState('')

  const onSubmit = async (e: React.FormEvent) => {
    e.preventDefault()
    if (!text.trim()) return
    await sendPrompt(text)
    setText('')
  }

  const hasDeclined = events.some(e => e.type === 'error' && /declined/.test((e as any).reason || ''))

  return (
    <section>
      <form onSubmit={onSubmit}>
        <input
          aria-label="Service request"
          value={text}
          onChange={e => setText(e.currentTarget.value)}
          placeholder="provision a point-to-point 1Gbps L2 service between leaf01 client01 and leaf02 client02 for tenant ACME"
          style={{ width: '100%', padding: '0.5rem' }}
          disabled={pending}
        />
      </form>
      <div style={{ margin: '0.75rem 0', fontSize: 12, color: '#555' }}>
        Thread: {threadId || 'new'}
        <button onClick={clear} style={{ marginLeft: 8 }}>Clear</button>
      </div>

      <div>
        {events.map((evt, i) => (
          <div key={i}>
            {evt.type === 'stage' && <StageCard evt={evt} />}
            {evt.type === 'confirmation_request' && (
              <Confirmation evt={evt} onConfirm={confirm} onDecline={decline} />
            )}
            {evt.type === 'progress' && (
              <div style={{ fontSize: 13, color: '#444', marginBottom: '0.5rem' }}>Progress: {evt.message || JSON.stringify(evt.details || {})}</div>
            )}
            {evt.type === 'error' && <FailureCard evt={evt} />}
            {evt.type === 'status' && (
              <div style={{ fontSize: 12, color: '#666', marginBottom: '0.25rem' }}>status: {evt.status} {evt.stage ? `(stage ${evt.stage})` : ''}</div>
            )}
            {evt.type === 'final' && (
              <div style={{ fontSize: 12, color: '#333', marginBottom: '0.25rem' }}>final: {evt.status}</div>
            )}
          </div>
        ))}
      </div>

      {hasDeclined && (
        <div style={{ borderTop: '1px solid #eee', marginTop: '1rem', paddingTop: '0.5rem', fontSize: 13 }}>
          Request cancelled. You can amend your request and continue in the same thread.
        </div>
      )}
    </section>
  )
}
