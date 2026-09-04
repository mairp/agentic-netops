import { useCallback, useEffect, useRef, useState } from 'react'

type Props = {
  /** Current chat panel height in px. */
  height: number
  /** Lowest usable chat height (smaller is unusable). */
  min: number
  /** Highest chat height given the console's current size. */
  max: number
  /** Comfortable height restored by double-click when the panel is maximized. */
  resetValue?: number
  /** Commit a newly clamped height (called continuously while dragging). */
  onResize: (height: number) => void
  /** Persist the final height (drag end / key up). */
  onResizeEnd: (height: number) => void
}

const KEYBOARD_STEP = 32
/** Home/End keys snap the conversation to its smallest/full-screen size. */
const SNAP_EPSILON = 8

/**
 * Draggable divider between the workflow canvas and the chat panel.
 *
 * Pointer-based (mouse + touch via pointer events, setPointerCapture so the
 * drag keeps tracking outside the element) with keyboard support
 * (ArrowUp/ArrowDown grow/shrink the conversation, Home/End snap to minimum
 * or full-screen). The chat sits BELOW the handle, so dragging up grows it:
 * newHeight = startHeight - dy. Dragging all the way up collapses the canvas
 * to its heading bar, giving the conversation practically the whole screen.
 * Double-click toggles between that maximized state and the comfortable
 * default height.
 */
export default function ResizeHandle({ height, min, max, resetValue, onResize, onResizeEnd }: Props) {
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
    if (event.key === 'Home' || event.key === 'End') {
      event.preventDefault()
      const next = clamp(event.key === 'Home' ? min : max)
      onResize(next)
      onResizeEnd(next)
      return
    }
    if (event.key !== 'ArrowUp' && event.key !== 'ArrowDown') return
    event.preventDefault()
    const next = clamp(height + (event.key === 'ArrowUp' ? KEYBOARD_STEP : -KEYBOARD_STEP))
    onResize(next)
    onResizeEnd(next)
  }

  // Double-click flips between "conversation fills the screen" and the
  // comfortable default, so the canvas is one gesture away either way.
  const toggleMaximize = () => {
    const maximized = height >= max - SNAP_EPSILON
    onResizeEnd(clamp(maximized ? (resetValue ?? min) : max))
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
      onDoubleClick={toggleMaximize}
      title="Drag to resize · double-click to maximize or restore"
    >
      <span className="resize-handle-grip" />
    </div>
  )
}
