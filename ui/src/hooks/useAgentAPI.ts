/*
 * useAgentAPI.ts — NDJSON-streaming client for the supervisor HTTP surface.
 *
 * Contract: specs/002-agntcy-intent-tier/contracts/supervisor-http.md
 * - POST /agent/prompt/stream streams NDJSON (Content-Type: application/x-ndjson)
 * - There is NO WebSocket route; any attempt to use WebSockets is rejected.
 */

import { useCallback, useMemo, useRef, useState } from 'react'

export type AgentEvent =
  | { type: 'status'; status: string; stage?: string; thread_id?: string; correlation_id: string }
  | { type: 'stage'; stage: 'mapper' | 'allocator' | 'deployer' | 'deployer-tools'; status: string; payload?: any; tool?: string; result?: any; correlation_id: string }
  | { type: 'confirmation_request'; stage: 'mapper' | 'allocator' | 'deployer'; prompt: string; refusable: boolean; correlation_id: string }
  | { type: 'clarification_request'; stage: 'mapper'; status: string; prompt: string; missing_fields: string[]; correlation_id: string }
  | { type: 'progress'; stage: 'deployer'; status: string; message?: string; details?: any; correlation_id: string }
  | { type: 'final'; status: string; correlation_id: string }
  | { type: 'error'; stage: string; status: string; reason: string; suggestion?: string; correlation_id: string }

export type UseAgentAPI = {
  events: AgentEvent[]
  pending: boolean
  sendPrompt: (text: string) => Promise<void>
  confirm: () => Promise<void>
  decline: () => Promise<void>
  threadId: string | null
  clear: () => void
}

const supervisorApiUrl: string =
  (import.meta as any).env?.VITE_BROWSER_API_URL ?? '/api'

export const WEBSOCKETS_DISABLED = true
export function connectWebSocket(): never {
  throw new Error('WebSocket client is not supported; use NDJSON over POST /agent/prompt/stream')
}

function loadThreadId(): string | null {
  try {
    return localStorage.getItem('intent_thread_id')
  } catch {
    return null
  }
}

function saveThreadId(id: string) {
  try {
    localStorage.setItem('intent_thread_id', id)
  } catch {
    // ignore
  }
}

export function useAgentAPI(): UseAgentAPI {
  const [events, setEvents] = useState<AgentEvent[]>([])
  const [pending, setPending] = useState(false)
  const threadRef = useRef<string | null>(loadThreadId())
  const lastCorrelationRef = useRef<string>('')

  const pushEvent = useCallback((e: AgentEvent) => {
    setEvents(prev => [...prev, e])
    if ((e as any).correlation_id) {
      lastCorrelationRef.current = (e as any).correlation_id
    }
  }, [])

  const ndjsonFetch = useCallback(async (text: string) => {
    setPending(true)
    try {
      const body = JSON.stringify({ prompt: text, principal: 'operator@example', thread_id: threadRef.current ?? undefined })
      const resp = await fetch(`${supervisorApiUrl}/agent/prompt/stream`, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'Accept': 'application/x-ndjson',
        },
        body,
      })
      if (!resp.ok) {
        throw new Error(`supervisor returned HTTP ${resp.status}`)
      }
      if (!resp.body) {
        throw new Error(`no response body from supervisor at ${supervisorApiUrl}`)
      }
      const reader = resp.body.getReader()
      const decoder = new TextDecoder('utf-8')
      let buf = ''
      for (;;) {
        const { done, value } = await reader.read()
        if (done) break
        buf += decoder.decode(value, { stream: true })
        let idx: number
        while ((idx = buf.indexOf('\n')) >= 0) {
          const line = buf.slice(0, idx).trim()
          buf = buf.slice(idx + 1)
          if (!line) continue
          try {
            const obj = JSON.parse(line)
            // Thread id arrives on the first status chunk
            if (obj.type === 'status' && obj.thread_id) {
              threadRef.current = obj.thread_id
              saveThreadId(obj.thread_id)
            }
            // Normalize correlation id presence
            if (!obj.correlation_id) {
              obj.correlation_id = lastCorrelationRef.current || 'unknown'
            }
            pushEvent(obj as AgentEvent)
          } catch (e) {
            // ignore parse errors on junk lines
          }
        }
      }
      // Flush any trailing data
      if (buf.trim()) {
        try {
          const obj = JSON.parse(buf.trim())
          if (!obj.correlation_id) obj.correlation_id = lastCorrelationRef.current || 'unknown'
          pushEvent(obj as AgentEvent)
        } catch {
          /* ignore */
        }
      }
    } catch (error) {
      pushEvent({
        type: 'error',
        stage: 'supervisor',
        status: 'FAILED',
        reason: error instanceof Error ? error.message : 'supervisor request failed',
        correlation_id: lastCorrelationRef.current || 'unknown',
      })
    } finally {
      setPending(false)
    }
  }, [pushEvent])

  const sendPrompt = useCallback(async (text: string) => {
    await ndjsonFetch(text)
  }, [ndjsonFetch])

  const confirm = useCallback(async () => {
    await ndjsonFetch('confirm')
  }, [ndjsonFetch])

  const decline = useCallback(async () => {
    await ndjsonFetch('decline')
  }, [ndjsonFetch])

  const clear = useCallback(() => {
    setEvents([])
    threadRef.current = null
    lastCorrelationRef.current = ''
    try {
      localStorage.removeItem('intent_thread_id')
    } catch {
      // ignore
    }
  }, [])

  return useMemo(() => ({ events, pending, sendPrompt, confirm, decline, threadId: threadRef.current, clear }), [events, pending, sendPrompt, confirm, decline, clear])
}
