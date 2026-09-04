import { LocateFixed, Minus, Plus } from 'lucide-react'

type Props = {
  /** Current zoom level (1 = 100%). */
  zoom: number
  min: number
  max: number
  onZoomIn: () => void
  onZoomOut: () => void
  onReset: () => void
  /** Distinguishes the control clusters in accessibility trees and tests. */
  label: string
}

/**
 * Zoom controls for one UI section: zoom out, a percentage readout that
 * doubles as reset-to-100%, zoom in, and a fit shortcut. Each section wires
 * this to its own useSectionZoom, so clusters never affect each other.
 */
export default function ZoomControls({ zoom, min, max, onZoomIn, onZoomOut, onReset, label }: Props) {
  const percent = Math.round(zoom * 100)
  const canIn = zoom < max - 1e-9
  const canOut = zoom > min + 1e-9
  return (
    <div className="zoom-controls" role="group" aria-label={`${label} zoom`}>
      <button onClick={onZoomOut} disabled={!canOut} title={`Zoom out (${Math.round(min * 100)}% minimum)`} aria-label={`Zoom out ${label}`}>
        <Minus size={14} />
      </button>
      <button className="zoom-readout" onClick={onReset} disabled={zoom === 1} title="Reset zoom to 100%" aria-label={`Reset ${label} zoom`}>
        {percent}%
      </button>
      <button onClick={onZoomIn} disabled={!canIn} title={`Zoom in (${Math.round(max * 100)}% maximum)`} aria-label={`Zoom in ${label}`}>
        <Plus size={14} />
      </button>
      <button onClick={onReset} disabled={zoom === 1} title="Fit view" aria-label={`Fit ${label} view`}>
        <LocateFixed size={14} />
      </button>
    </div>
  )
}
