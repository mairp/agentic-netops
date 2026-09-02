import Navigation from './components/Navigation/Navigation'
import Sidebar from './components/Sidebar/Sidebar'
import MainArea from './components/MainArea/MainArea'

const supervisorApiUrl: string =
  (import.meta as any).env?.VITE_SUPERVISOR_API_URL ?? 'http://supervisor.ainetops-agents.svc:9090'

export default function App() {
  return (
    <div style={{ fontFamily: 'system-ui, sans-serif', display: 'flex', flexDirection: 'column', minHeight: '100vh' }}>
      <Navigation />
      <div style={{ display: 'flex', flex: 1 }}>
        <Sidebar />
        <main style={{ flex: 1 }}>
          <div style={{ padding: '1rem', borderBottom: '1px solid #eee', background: '#fafafa' }}>
            <strong>Supervisor:</strong> <code>{supervisorApiUrl}</code>
          </div>
          <MainArea />
        </main>
      </div>
    </div>
  )
}
