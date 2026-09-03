import { useEffect, useMemo, useState } from 'react'
import Chat from './components/Chat/Chat'
import MainArea from './components/MainArea/MainArea'
import Navigation from './components/Navigation/Navigation'
import Sidebar from './components/Sidebar/Sidebar'
import { useAgentAPI } from './hooks/useAgentAPI'

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
        <main className="operator-console">
          <MainArea events={agent.events} pending={agent.pending} health={health} />
          <Chat agent={agent} prompts={prompts} />
        </main>
      </div>
    </div>
  )
}
