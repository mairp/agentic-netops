import { useCallback, useEffect, useRef, useState } from 'react'

type Props = {
  /** Current chat panel height in px. */
  height: number
  /** Lowest usable chat height (smaller is unusable). */
  min: number
  /** Highest chat height given the console's current size. */
  max: number
  /** Commit a newly clamped height (called continuously while dragging). */
  onResize: (height: number) => void
  /** Persist the final height (drag end / key up). */
  onResizeEnd: (height: number) => void
}

const KEYBOARD_STEP = 32

/**
 * Draggable divider between the workflow canvas and the chat panel.
 *
 * Pointer-based (mouse + touch via pointer events, setPointerCapture so the
 * drag keeps tracking outside the element) with keyboard support
 * (ArrowUp/ArrowDown grow/shrink the conversation). The chat sits BELOW the
 * handle, so dragging up grows it: newHeight = startHeight - dy.
 */
export default function ResizeHandle({ height, min, max, onResize, onResizeEnd }: Props) {
  const [dragging, setDragging] = useState(false)
  const dragStart = useRef({ pointerY: 0, baseHeight: 0 })

  // Lock text selection and force the resize cursor everywhere while dragging.
  useEffect(() => {
    if (!dragging) return
    const body = document.body
    const previousSelect = body.style.userSelect
    const previousCursor = body.style.cursor
    body.style.userSelect = 'none'
    body.style.cursor = 'row-resize'
    return () => {
      body.style.userSelect = previousSelect
      body.style.cursor = previousCursor
    }
  }, [dragging])

  const clamp = useCallback(
    (value: number) => Math.min(max, Math.max(min, value)),
    [min, max],
  )

  const onPointerDown = (event: React.PointerEvent<HTMLDivElement>) => {
    dragStart.current = { pointerY: event.clientY, baseHeight: height }
    event.currentTarget.setPointerCapture(event.pointerId)
    setDragging(true)
    event.preventDefault()
  }

  const onPointerMove = (event: React.PointerEvent<HTMLDivElement>) => {
    if (!dragging) return
    onResize(clamp(dragStart.current.baseHeight - (event.clientY - dragStart.current.pointerY)))
  }

  const endDrag = (event: React.PointerEvent<HTMLDivElement>) => {
    if (!dragging) return
    setDragging(false)
    event.currentTarget.releasePointerCapture(event.pointerId)
    onResizeEnd(height)
  }

  const onKeyDown = (event: React.KeyboardEvent<HTMLDivElement>) => {
    if (event.key !== 'ArrowUp' && event.key !== 'ArrowDown') return
    event.preventDefault()
    const next = clamp(height + (event.key === 'ArrowUp' ? KEYBOARD_STEP : -KEYBOARD_STEP))
    onResize(next)
    onResizeEnd(next)
  }

  return (
    <div
      className={`resize-handle ${dragging ? 'dragging' : ''}`}
      role="separator"
      aria-orientation="horizontal"
      aria-label="Resize conversation panel"
      aria-valuemin={min}
      aria-valuemax={max}
      aria-valuenow={Math.round(height)}
      tabIndex={0}
      onPointerDown={onPointerDown}
      onPointerMove={onPointerMove}
      onPointerUp={endDrag}
      onPointerCancel={endDrag}
      onKeyDown={onKeyDown}
      onDoubleClick={() => onResizeEnd(clamp((min + max) / 2))}
      title="Drag to resize the conversation panel"
    >
      <span className="resize-handle-grip" />
    </div>
  )
}
