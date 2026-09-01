# fast-path-display-link-duty-cycle — plan (standard tier, light)

Evidence: `arch-reviews/2026-09-01-active-window-tracking.md` F4/F5.

## Acceptance criteria

1. With emphasis on and the active window idle, no per-frame
   `CGWindowListCopyWindowInfo` IPC — the display link is paused.
2. During a window drag/resize the cutout still follows at frame rate
   (link resumes on the first `kAXWindowMoved`/`kAXWindowResized` and keeps
   running until ~250 ms after the last one).
3. Window-gone detection (item 1's consecutive-nil counter) still fires for a
   window closed while idle — the slow path must carry that check when the
   link is paused.
4. F5: the display link follows the screen the active window is on (re-created
   when the primary window's screen changes), so ProMotion vs 60 Hz externals
   each get their native cadence.

## Sketch

- Keep the link object; use `isPaused` (CADisplayLink has it on macOS 14+ via
  NSScreen.displayLink) or invalidate/recreate. Resume + arm a deadline
  timestamp on each moved/resized AX notification; a slow-path tick pauses it
  when `now - lastMotion > 0.25 s`.
- Move the consecutive-nil "window gone" check into a shared helper called
  from both fast path (running) and slow path (paused): the slow path calls
  `fetchWindowBounds` once per tick when the link is paused — 10 Hz, cheap,
  and exactly what keeps AC3 true.
