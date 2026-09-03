import { Activity, HelpCircle, Menu, Moon, Network, Sun } from 'lucide-react'

type Props = {
  health: 'checking' | 'ok' | 'degraded' | 'offline'
  theme: 'dark' | 'light'
  onToggleTheme: () => void
  onToggleSidebar: () => void
}

export default function Navigation({ health, theme, onToggleTheme, onToggleSidebar }: Props) {
  return (
    <header className="topbar">
      <div className="brand-group">
        <button className="icon-button mobile-menu" onClick={onToggleSidebar} title="Open navigation" aria-label="Open navigation">
          <Menu size={19} />
        </button>
        <div className="brand-mark" aria-hidden="true">
          <Network size={21} strokeWidth={2} />
        </div>
        <div className="brand-name">
          <strong>agentic-netops</strong>
          <span>Autonomous intent-to-fabric operations</span>
        </div>
        <span className="product-pill">INTENT FABRIC</span>
      </div>

      <div className="topbar-actions">
        <div className={`runtime-pill ${health}`}>
          <Activity size={14} />
          <span>{health === 'ok' ? 'Runtime ready' : health === 'checking' ? 'Checking runtime' : health}</span>
        </div>
        <button className="icon-button" onClick={onToggleTheme} title={`Switch to ${theme === 'dark' ? 'light' : 'dark'} mode`} aria-label={`Switch to ${theme === 'dark' ? 'light' : 'dark'} mode`}>
          {theme === 'dark' ? <Sun size={18} /> : <Moon size={18} />}
        </button>
        <a className="icon-button" href="https://github.com/mairp/agentic-netops" target="_blank" rel="noreferrer" title="Open project documentation" aria-label="Open project documentation">
          <HelpCircle size={18} />
        </a>
      </div>
    </header>
  )
}
