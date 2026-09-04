import { useCallback, useEffect, useMemo, useRef, useState, type MouseEvent as ReactMouseEvent, type PointerEvent as ReactPointerEvent, type TransitionEvent as ReactTransitionEvent } from 'react'
import { Bot, Braces, Check, CircuitBoard, Minus, Network, Plus, Route, ServerCog } from 'lucide-react'
import type { HealthState } from '../../App'
import type { AgentEvent } from '../../hooks/useAgentAPI'
import { useSectionZoom } from '../../hooks/useSectionZoom'

type Props = {
  events: AgentEvent[]
  pending: boolean
  health: HealthState
}

/** The agent canvas scales independently of every other section (50%–200%). */
const CANVAS_ZOOM = { min: 0.5, max: 2, step: 0.1 }

type AgentNodeProps = {
  id: string
  title: string
  role: string
  active: boolean
  ready: boolean
  /** Changes on every backend event so the live ripple animation restarts. */
  rippleKey: number
  icon: typeof Bot
}

function AgentNode({ id, title, role, active, ready, rippleKey, icon: Icon }: AgentNodeProps) {
  return (
    <div className={`graph-node ${active ? 'active talking' : ''}`} data-node={id}>
      {active && <span key={rippleKey} className="node-ripple" aria-hidden="true" />}
      <div className="graph-node-icon"><Icon size={18} /></div>
      <div className="graph-node-copy"><strong>{title}</strong><span>{role}</span></div>
      <span className={`node-state ${active ? 'active' : ready ? 'ready' : ''}`}>
        {active ? 'WORKING' : ready ? <Check size={12} /> : 'IDLE'}
      </span>
    </div>
  )
}

/** The stage the stream is currently on, derived from events alone; whether
 *  anyone is lit right now is decided by `pending || liveTraffic`. */
function activeStage(events: AgentEvent[]) {
  for (let index = events.length - 1; index >= 0; index -= 1) {
    const event = events[index]
    if (event.type === 'stage') return event.stage === 'deployer-tools' ? 'deployer' : event.stage
    if (event.type === 'confirmation_request') return event.stage
    if (event.type === 'clarification_request') return event.stage
  }
  return events.length ? 'supervisor' : ''
}

export default function MainArea({ events, pending, health }: Props) {
  const { zoom, nudgeZoom, zoomIn, zoomOut, resetZoom } = useSectionZoom('agentic-netops-zoom-canvas', CANVAS_ZOOM)
  const viewportRef = useRef<HTMLDivElement>(null)
  const scaleRef = useRef<HTMLDivElement>(null)
  const [rippleKey, setRippleKey] = useState(0)
  const workers = health.workers

  /*
   * Pan: the workflow is moved with transform, which never grows the viewport's
   * scrollable area, so the only way to reach the clipped parts when zoomed in
   * is dragging the layout itself. Pan is clamped so the diagram can never be
   * dragged completely out of sight.
   */
  const [pan, setPan] = useState({ x: 0, y: 0 })
  const panRef = useRef(pan)
  const dragRef = useRef<{ startX: number; startY: number; baseX: number; baseY: number } | null>(null)
  const [dragging, setDragging] = useState(false)
  useEffect(() => { panRef.current = pan }, [pan])

  // Panning is always available (the user positions the layout where they
  // like), bounded only by "the layout must stay reachable": at least
  // PAN_KEEP_VISIBLE of it remains inside the viewport on each axis.
  const PAN_KEEP_VISIBLE = 120
  const clampPan = useCallback((x: number, y: number) => {
    const viewport = viewportRef.current
    const scale = scaleRef.current
    if (!viewport || !scale) return { x, y }
    // The rect includes the current transform; subtract the current pan to get
    // the unpanned box, then work in viewport-relative coordinates.
    const frame = viewport.getBoundingClientRect()
    const box = scale.getBoundingClientRect()
    const current = panRef.current
    const left = box.left - current.x - frame.left
    const right = box.right - current.x - frame.left
    const top = box.top - current.y - frame.top
    const bottom = box.bottom - current.y - frame.top
    const width = viewport.clientWidth
    const height = viewport.clientHeight
    const maxX = width - PAN_KEEP_VISIBLE - left
    const minX = PAN_KEEP_VISIBLE - right
    const maxY = height - PAN_KEEP_VISIBLE - top
    const minY = PAN_KEEP_VISIBLE - bottom
    return { x: Math.min(maxX, Math.max(minX, x)), y: Math.min(maxY, Math.max(minY, y)) }
  }, [])

  const onPointerDown = (event: ReactPointerEvent<HTMLDivElement>) => {
    if (event.button !== 0) return
    if ((event.target as HTMLElement).closest('.canvas-controls')) return
    const viewport = viewportRef.current
    if (!viewport) return
    viewport.setPointerCapture(event.pointerId)
    dragRef.current = { startX: event.clientX, startY: event.clientY, baseX: panRef.current.x, baseY: panRef.current.y }
    setDragging(true)
  }
  const onPointerMove = (event: ReactPointerEvent<HTMLDivElement>) => {
    const drag = dragRef.current
    if (!drag) return
    const next = clampPan(drag.baseX + event.clientX - drag.startX, drag.baseY + event.clientY - drag.startY)
    setPan(next)
  }
  const endDrag = () => { dragRef.current = null; setDragging(false) }

  // Re-clamp when the zoom changes or the window resizes; the transform
  // transition animates, so also settle on transitionend.
  useEffect(() => { setPan(current => clampPan(current.x, current.y)) }, [zoom, clampPan])
  useEffect(() => {
    const onResize = () => setPan(current => clampPan(current.x, current.y))
    window.addEventListener('resize', onResize)
    return () => window.removeEventListener('resize', onResize)
  }, [clampPan])
  const onTransitionEnd = (event: ReactTransitionEvent) => {
    if (event.propertyName !== 'transform') return
    setPan(current => clampPan(current.x, current.y))
  }
  const resetView = () => { resetZoom(); setPan({ x: 0, y: 0 }) }
  const onDoubleClick = (event: ReactMouseEvent) => {
    const target = event.target as HTMLElement
    if (target.closest('.canvas-controls') || target.closest('.graph-node') || target.closest('.system-node')) return
    resetView()
  }

  /*
   * Live-traffic signal ("the grid is talking over SLIM"). True while the
   * exchange is pending and held briefly after every backend event, so even a
   * fast NDJSON stream keeps the blinking visible before it settles.
   */
  const [liveTraffic, setLiveTraffic] = useState(false)
  const eventCount = events.length
  const eventSeen = useRef(0)
  useEffect(() => {
    if (eventCount === 0 && !pending) {
      setLiveTraffic(false)
      return
    }
    if (eventCount !== eventSeen.current) {
      eventSeen.current = eventCount
      setRippleKey(key => key + 1)
    }
    setLiveTraffic(true)
    const timer = window.setTimeout(() => setLiveTraffic(false), pending ? 1500 : 1800)
    return () => window.clearTimeout(timer)
  }, [eventCount, pending])

  // The speaking agent follows the stream; during the afterglow the last
  // speaker stays lit, then everything settles back to idle/ready.
  const stage = activeStage(events)
  const active = pending || liveTraffic ? stage : ''
  const talking = pending || liveTraffic
  const hasActivity = events.length > 0

  // Ctrl/⌘ + wheel zooms only this canvas. A native non-passive listener is
  // required so the browser page-zoom can be suppressed.
  useEffect(() => {
    const viewport = viewportRef.current
    if (!viewport) return
    const onWheel = (event: WheelEvent) => {
      if (!event.ctrlKey && !event.metaKey) return
      event.preventDefault()
      nudgeZoom(event.deltaY > 0 ? -CANVAS_ZOOM.step : CANVAS_ZOOM.step)
    }
    viewport.addEventListener('wheel', onWheel, { passive: false })
    return () => viewport.removeEventListener('wheel', onWheel)
  }, [nudgeZoom])

  const workflowStatus = useMemo(() => {
    const last = events.at(-1)
    if (!last) return 'Ready for intent'
    if (last.type === 'error') return 'Action required'
    if (last.type === 'clarification_request') return 'Needs detail'
    if (last.type === 'final') return last.status.replaceAll('_', ' ')
    return pending ? 'Agents working' : 'Workflow paused'
  }, [events, pending])

  const workerLive = {
    mapper: active === 'mapper',
    allocator: active === 'allocator',
    deployer: active === 'deployer',
  }

  return (
    <section className="canvas-panel" aria-label="Agent topology">
      <div className="canvas-heading">
        <div><span className="eyebrow">LIVE ORCHESTRATION</span><h1>Agent-to-agent workflow</h1></div>
        <div className={`workflow-state ${pending ? 'active' : ''}`}><span />{workflowStatus}</div>
      </div>

      <div
        className={`graph-viewport ${dragging ? 'dragging' : ''}`}
        ref={viewportRef}
        title="Drag to pan · double-click the background to reset the view · Ctrl/⌘+wheel to zoom"
        onPointerDown={onPointerDown}
        onPointerMove={onPointerMove}
        onPointerUp={endDrag}
        onPointerCancel={endDrag}
        onDoubleClick={onDoubleClick}
        onTransitionEnd={onTransitionEnd}
      >
        <div className="dot-grid" />
        <div className="graph-scale" ref={scaleRef} style={{ transform: `translate(${pan.x}px, ${pan.y}px) scale(${zoom})` }}>
          <div className={`topology-flow ${talking ? 'talking' : ''}`}>
            <AgentNode id="supervisor" title="Supervisor Agent" role="Intent coordinator" active={active === 'supervisor'} ready={health.status === 'ok'} rippleKey={rippleKey} icon={Bot} />
            <div className={`vertical-link ${talking ? 'active' : ''}`}><span key={`v${rippleKey}`} /></div>
            <div className={`transport-rail ${talking ? 'active' : ''}`}>
              <span className="rail-label">A2A · {health.transport || 'SLIM'}</span>
              {talking && <span key={`r${rippleKey}`} className="rail-pulse" aria-hidden="true" />}
            </div>
            <div className={`worker-connectors ${talking ? 'talking' : ''}`}>
              <i className={workerLive.mapper ? 'live' : ''} />
              <i className={workerLive.allocator ? 'live' : ''} />
              <i className={workerLive.deployer ? 'live' : ''} />
            </div>
            <div className="worker-row">
              <AgentNode id="mapper" title="Mapper Agent" role="Interpret intent" active={workerLive.mapper} ready={workers.mapper === 'ok'} rippleKey={rippleKey} icon={Route} />
              <AgentNode id="allocator" title="Allocator Agent" role="Claim identifiers" active={workerLive.allocator} ready={workers.allocator === 'ok'} rippleKey={rippleKey} icon={Braces} />
              <AgentNode id="deployer" title="Deployer Agent" role="Submit resources" active={workerLive.deployer} ready={workers.deployer === 'ok'} rippleKey={rippleKey} icon={ServerCog} />
            </div>
            <div className={`control-link ${workerLive.deployer ? 'active' : ''}`}><span key={`c${rippleKey}`} /></div>
            <div className="control-plane-row">
              <div className="system-node"><CircuitBoard size={18} /><div><strong>Kubernetes controllers</strong><span>Continuous reconciliation</span></div></div>
              <div className={`system-arrow ${hasActivity ? 'active' : ''}`}><span>desired state</span></div>
              <div className="system-node fabric-node"><Network size={18} /><div><strong>SONiC fabric</strong><span>EVPN / VXLAN</span></div></div>
            </div>
          </div>
        </div>

        <div className="canvas-controls" aria-label="Canvas zoom controls">
          <button onClick={zoomIn} disabled={zoom >= CANVAS_ZOOM.max - 1e-9} title="Zoom in (Ctrl + wheel works too)" aria-label="Zoom in canvas"><Plus size={17} /></button>
          <button onClick={resetView} disabled={zoom === 1 && pan.x === 0 && pan.y === 0} title="Reset zoom and position" aria-label="Reset canvas view"><span className="zoom-percent">{Math.round(zoom * 100)}%</span></button>
          <button onClick={zoomOut} disabled={zoom <= CANVAS_ZOOM.min + 1e-9} title="Zoom out (Ctrl + wheel works too)" aria-label="Zoom out canvas"><Minus size={17} /></button>
        </div>
      </div>
    </section>
  )
}
