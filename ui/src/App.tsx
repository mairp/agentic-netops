import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import Chat from './components/Chat/Chat'
import MainArea from './components/MainArea/MainArea'
import Navigation from './components/Navigation/Navigation'
import ResizeHandle from './components/ResizeHandle/ResizeHandle'
import Sidebar from './components/Sidebar/Sidebar'
import { useAgentAPI } from './hooks/useAgentAPI'

/** Smallest conversation height that stays usable (header + a message + composer). */
const CHAT_MIN_HEIGHT = 220
/** Conversation height until the operator picks their own (persisted). */
const CHAT_DEFAULT_HEIGHT = 356
/** What the canvas keeps while the conversation is dragged to full screen:
 *  its 62px heading bar, so the divider stays reachable and the workflow
 *  status remains visible. */
const CANVAS_MIN_HEIGHT = 62
/** Rendered height of the divider row between the panels. */
const DIVIDER_HEIGHT = 6

function loadChatHeight(): number {
  try {
    const stored = localStorage.getItem('agentic-netops-chat-height')
    const parsed = stored ? Number.parseInt(stored, 10) : Number.NaN
    if (Number.isFinite(parsed) && parsed >= CHAT_MIN_HEIGHT) return parsed
  } catch {
    // Storage can be unavailable; the default applies.
  }
  return CHAT_DEFAULT_HEIGHT
}

export type HealthState = {
  status: 'checking' | 'ok' | 'degraded' | 'offline'
  transport: string
  endpoint: string
  workers: Record<string, string>
}

const apiBaseUrl: string =
  (import.meta as any).env?.VITE_BROWSER_API_URL ?? '/api'

function useIntentHealth() {
  const [health, setHealth] = useState<HealthState>({
    status: 'checking',
    transport: 'SLIM',
    endpoint: '',
    workers: {},
  })

  useEffect(() => {
    let active = true

    const refresh = async () => {
      try {
        const response = await fetch(`${apiBaseUrl}/v1/health`)
        const body = await response.json()
        if (!active) return
        setHealth({
          status: body.status === 'ok' ? 'ok' : 'degraded',
          transport: String(body.transport || 'SLIM').toUpperCase(),
          endpoint: body.endpoint || '',
          workers: body.workers || {},
        })
      } catch {
        if (active) {
          setHealth(current => ({ ...current, status: 'offline' }))
        }
      }
    }

    void refresh()
    const timer = window.setInterval(refresh, 15_000)
    return () => {
      active = false
      window.clearInterval(timer)
    }
  }, [])

  return health
}

function useSuggestedPrompts() {
  const fallback = useMemo(
    () => [
      'Create an L2 service for tenant blue between leaf01 eth3 and leaf02 eth3.',
      'What service types do you support?',
      'Show the status of my network services.',
    ],
    [],
  )
  const [prompts, setPrompts] = useState<string[]>(fallback)

  useEffect(() => {
    let active = true
    fetch(`${apiBaseUrl}/suggested-prompts`)
      .then(response => (response.ok ? response.json() : Promise.reject(response)))
      .then(body => {
        if (active && Array.isArray(body) && body.every(item => typeof item === 'string')) {
          setPrompts(body)
        }
      })
      .catch(() => undefined)
    return () => {
      active = false
    }
  }, [])

  return prompts
}

export default function App() {
  const agent = useAgentAPI()
  const health = useIntentHealth()
  const prompts = useSuggestedPrompts()
  const [sidebarOpen, setSidebarOpen] = useState(false)
  const [theme, setTheme] = useState<'dark' | 'light'>(() => {
    try {
      return localStorage.getItem('agentic-netops-theme') === 'light' ? 'light' : 'dark'
    } catch {
      return 'dark'
    }
  })

  const toggleTheme = () => {
    setTheme(current => {
      const next = current === 'dark' ? 'light' : 'dark'
      try {
        localStorage.setItem('agentic-netops-theme', next)
      } catch {
        // The theme still changes when storage is unavailable.
      }
      return next
    })
  }

  // Divider position between the workflow canvas and the conversation.
  const [chatExpanded, setChatExpanded] = useState(true)
  const [chatHeight, setChatHeight] = useState(loadChatHeight)
  const consoleRef = useRef<HTMLElement>(null)
  // The conversation may grow until only the canvas heading remains, i.e.
  // practically the full screen height. Before the console is measured fall
  // back to something generous rather than fighting the layout.
  const measuredMax = consoleRef.current?.clientHeight ?? 0
  const chatMaxHeight = measuredMax > 0
    ? measuredMax - CANVAS_MIN_HEIGHT - DIVIDER_HEIGHT
    : CHAT_DEFAULT_HEIGHT + 600
  const clampChatHeight = useCallback(
    (value: number) => Math.min(chatMaxHeight, Math.max(CHAT_MIN_HEIGHT, value)),
    [chatMaxHeight],
  )
  // Re-measure the console when its box changes (window resize, sidebar
  // toggling) so the drag bounds and the applied clamp follow the live layout.
  const [, setMeasureTick] = useState(0)
  useEffect(() => {
    const onResize = () => setMeasureTick(tick => tick + 1)
    const consoleEl = consoleRef.current
    if (!consoleEl || typeof ResizeObserver === 'undefined') {
      window.addEventListener('resize', onResize)
      return () => window.removeEventListener('resize', onResize)
    }
    const observer = new ResizeObserver(onResize)
    observer.observe(consoleEl)
    window.addEventListener('resize', onResize)
    return () => {
      observer.disconnect()
      window.removeEventListener('resize', onResize)
    }
  }, [])
  const safeChatHeight = clampChatHeight(chatHeight)
  const applyChatHeight = useCallback((value: number) => {
    setChatHeight(clampChatHeight(value))
  }, [clampChatHeight])
  const persistChatHeight = useCallback((value: number) => {
    const clamped = clampChatHeight(value)
    setChatHeight(clamped)
    try {
      localStorage.setItem('agentic-netops-chat-height', String(Math.round(clamped)))
    } catch {
      // Storage can be unavailable; the size just is not remembered.
    }
  }, [clampChatHeight])

  return (
    <div className="app-shell" data-theme={theme}>
      <Navigation
        health={health.status}
        theme={theme}
        onToggleTheme={toggleTheme}
        onToggleSidebar={() => setSidebarOpen(open => !open)}
      />
      <div className="workspace">
        <Sidebar
          open={sidebarOpen}
          health={health}
          events={agent.events}
          pending={agent.pending}
          threadId={agent.threadId}
          onClose={() => setSidebarOpen(false)}
          onClear={agent.clear}
        />
        {sidebarOpen && <button className="sidebar-scrim" aria-label="Close navigation" onClick={() => setSidebarOpen(false)} />}
        <main className="operator-console" ref={consoleRef}>
          <MainArea events={agent.events} pending={agent.pending} health={health} />
          {chatExpanded && (
            <ResizeHandle
              height={safeChatHeight}
              min={CHAT_MIN_HEIGHT}
              max={chatMaxHeight}
              resetValue={CHAT_DEFAULT_HEIGHT}
              onResize={applyChatHeight}
              onResizeEnd={persistChatHeight}
            />
          )}
          <Chat
            agent={agent}
            prompts={prompts}
            expanded={chatExpanded}
            onExpandedChange={setChatExpanded}
            chatHeight={safeChatHeight}
          />
        </main>
      </div>
    </div>
  )
}
