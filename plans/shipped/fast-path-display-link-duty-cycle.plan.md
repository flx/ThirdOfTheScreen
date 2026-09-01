# fast-path-display-link-duty-cycle — plan (standard tier, light)

## Review round (adv-review-edge, 2026-09-01, combined with screen-change-skips-emphasis-overlay) and disposition

9 findings, all accepted and fixed pre-commit:
- R1 HIGH: a stopped tracker could resurrect the display link (tracker's own
  workspace observers bypassed refresh()'s isRunning guard; retarget created a
  link when displayLinkScreenID was nil) → observers now route through
  refresh(); retargetDisplayLinkIfNeeded guards on an existing link and never
  creates one.
- R2: same call sites re-installed AX observation on a stopped tracker →
  fixed by R1's routing.
- R3: screen-params refresh was defeated by publish dedupe (same window, same
  frame ⇒ no push, panel kept old screen-derived frame) → OverlayManager now
  calls pushActiveWindowToEmphasis() unconditionally after the refresh.
- R4: verifyPrimaryWindowPresence stamped motion without unpausing ⇒ slow-path
  discovered motion stayed at 10 Hz → uses noteWindowMotion().
- R5: dropping refresh() from moved/resized deleted the focus self-heal for
  toolkits with unreliable AX focus notifications → ~1 Hz focus re-resolve
  added to the slow path.
- R6: retarget thrash at a screen boundary (max-intersection flips on 0.5 px)
  → 1.25× area hysteresis.
- R7: grace+hold worst case grew to ~430 ms with a paused link → a first miss
  now unpauses the link so the grace is measured at frame rate; the
  OverlayManager comment was corrected to state the real bound.
- R8: the slow-path link self-heal started on NSScreen.main regardless of the
  window's screen → passes screenContaining(primaryWindowFrame).
- R9 (pre-existing, aggravated): panelGeometry picked the FIRST intersecting
  screen while the tracker picks max-intersection — a straddling window could
  leave most of its real screen undimmed → panelGeometry now picks
  max-intersection too.
Clean per reviewer: pause/resume ordering converges both ways on the main
actor, retarget's self-invalidation is the sanctioned CADisplayLink pattern,
numerical edges (null/zero rects, monotonic clock, display-ID bridge) all
probed clean. Re-review skipped — fixes are the findings' own remedies.


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
