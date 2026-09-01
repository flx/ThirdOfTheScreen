# TODO

The single work queue. Format: `- [ ] (slug) **[tier · priority]** what, and where.`
Tier (`trivial|standard|hi`) governs plan and review depth — it is not priority.
Evidence for anything filed here lives in `arch-reviews/`. Work top to bottom
within a section.

All entries below were filed by the 2026-09-01 arch review of active-window
tracking (`arch-reviews/2026-09-01-active-window-tracking.md` — read it before
planning; it carries the verified mechanisms and the fix directions, including
one deliberate NOT-filed list). Line numbers cite the uncommitted working copy
of that date.

## 0. Next up — work these first, in this order

- [ ] (ax-element-to-window-id-drop-geometry-matcher) **[standard · Medium]**
  Replace the AX→CGWindowID geometry-matching heuristic
  (`matchPrimaryWindowNumber` + `windowSnapshots` +
  `bestMatchingPrimarySnapshot` + the ≥4 pt invalidation at
  `ActiveWindowTracker.swift:311-313`) with the private
  `_AXUIElementGetWindow(AXUIElement, &CGWindowID)`, dlsym-resolved with the
  current matcher kept as fallback — the same pattern `PrivateWindowServer`
  already uses. Retires a real mis-lock (`bestMatchingPrimarySnapshot` is
  `snapshots.max` with NO minimum score, so it will lock onto a zero-overlap
  window, `:420-428`) and deletes the 10 Hz full-window-list scan. Shrinks
  both items above; do it before, not after, any deeper tracker rework.
  (Arch review F3.)

## 1. Filed, not scheduled

- [ ] (ax-observer-pool-per-app) **[standard · TRIGGERED — do not schedule
  until it fires]** Step 2 of `(cross-app-activation-latency)`, deliberately
  not built with step 1: one `AXObserver` per running application registered
  for `kAXApplicationActivatedNotification` +
  `kAXFocusedWindowChangedNotification`, maintained against workspace
  launch/terminate notifications (the AltTab/yabai pattern) — sub-frame
  cross-app switch latency instead of the ~100 ms cap the slow-path pid
  compare provides. **Trigger: Felix reports the capped latency still feels
  slow on the running app.** The pool costs real bookkeeping (observer
  lifetime per pid, teardown on terminate, re-attach on relaunch); do not
  build it speculatively.

- [ ] (fast-path-display-link-duty-cycle) **[standard · Low]** While emphasis
  is on, the `CADisplayLink` does one `CGWindowListCopyWindowInfo` IPC per
  frame (120 Hz on ProMotion) even when nothing moves, and `slowPathTick`
  copies the whole on-screen window list at 10 Hz
  (`ActiveWindowTracker.swift:165-174`, `:378-406`). Parenting already moves
  the panel; the fast path only serves the cutout — so run the link only
  during an AX moved/resized burst (start on the notification, stop ~250 ms
  after the last). Fold in F5: the link is created for `NSScreen.main` once at
  start (`:113-124`) — wrong cadence on multi-display, never re-created on
  screen changes. The slow-path scan disappears with
  `(ax-element-to-window-id-drop-geometry-matcher)`. (Arch review F4/F5.)

- [ ] (screen-change-skips-emphasis-overlay) **[trivial · Low]**
  `didChangeScreenParametersNotification` only resynchronizes the grid panels
  (`OverlayManager.swift:112-122`); the emphasis panel keeps its old frame
  until the next focus change. Add `activeWindowTracker.refresh()` (and hence
  a re-push) to that observer. (Arch review F6.)

