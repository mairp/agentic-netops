import { useCallback, useEffect, useState } from 'react'

/*
 * useSectionZoom — independent, persisted zoom level for one UI section.
 *
 * Every section (sidebar, agent canvas, conversation) owns its own hook
 * instance, so zooming one never affects the others. The level is clamped to
 * the section's bounds and remembered in localStorage under `storageKey`.
 */

export type ZoomBounds = {
  min: number
  max: number
  step?: number
}

const round = (value: number) => Math.round(value * 100) / 100

function clampZoom(value: number, min: number, max: number): number {
  return round(Math.min(max, Math.max(min, value)))
}

function loadZoom(storageKey: string, min: number, max: number, fallback: number): number {
  try {
    const stored = localStorage.getItem(storageKey)
    const parsed = stored ? Number.parseFloat(stored) : Number.NaN
    if (Number.isFinite(parsed)) return clampZoom(parsed, min, max)
  } catch {
    // Storage can be unavailable; the fallback applies.
  }
  return fallback
}

export function useSectionZoom(storageKey: string, bounds: ZoomBounds, fallback = 1) {
  const { min, max } = bounds
  const step = bounds.step ?? 0.1

  const [zoom, setZoomState] = useState(() => loadZoom(storageKey, min, max, fallback))

  useEffect(() => {
    try {
      localStorage.setItem(storageKey, String(zoom))
    } catch {
      // The level still applies for this session when storage is unavailable.
    }
  }, [storageKey, zoom])

  const setZoom = useCallback(
    (value: number) => setZoomState(clampZoom(value, min, max)),
    [min, max],
  )
  const nudgeZoom = useCallback(
    (delta: number) => setZoomState(current => clampZoom(current + delta, min, max)),
    [min, max],
  )
  const zoomIn = useCallback(() => nudgeZoom(step), [nudgeZoom, step])
  const zoomOut = useCallback(() => nudgeZoom(-step), [nudgeZoom, step])
  const resetZoom = useCallback(() => setZoomState(clampZoom(fallback, min, max)), [fallback, min, max])

  return {
    zoom,
    setZoom,
    nudgeZoom,
    zoomIn,
    zoomOut,
    resetZoom,
    canZoomIn: zoom < max - 1e-9,
    canZoomOut: zoom > min + 1e-9,
  }
}
