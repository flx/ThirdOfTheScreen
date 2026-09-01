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

- [ ] (emphasis-punchout-outlives-closed-window) **[standard · High]** The
  reported bug: close a window (e.g. a small Finder window) and the bright
  punch-out stays until a new window is selected. Mechanism CONFIRMED, three
  cooperating holes (arch review F1): no
  `kAXUIElementDestroyedNotification` on the observed window
  (`ActiveWindowTracker.swift:266-277`); `fastPathTick` silently returns when
  the dead window's bounds fetch comes back nil (`:165-174`), so stale state is
  held forever; and `OverlayManager.pushActiveWindowToEmphasis` deliberately
  "keep[s] current parenting" when the tracker has no primary
  (`OverlayManager.swift:224-228`), so even a *successful* AX reset leaves the
  panel up. Fix: register the destroyed notification in
  `updateWindowObservationIfNeeded` (clear + `refreshFocusContext()` on fire);
  treat 2–3 consecutive nil fetches in `fastPathTick` as window-gone; give the
  keep-parenting branch a ~200 ms deadline so menu/sheet transients still don't
  flicker. Cover miniaturize + app-hide too
  (`kAXWindowMiniaturizedNotification`, `kAXApplicationHiddenNotification`) —
  the nil-fetch heuristic does NOT catch those (a minimized window still
  resolves via `.optionIncludingWindow`).

- [ ] (cross-app-activation-latency) **[standard · High]** Cross-app focus
  switches wait on `NSWorkspace.didActivateApplicationNotification`
  (`ActiveWindowTracker.swift:80-91`), which lands well after the visual
  switch; within-app switches are already immediate via AX. Two-step direction
  (arch review F2): FIRST the cheap cap — add a frontmost-pid compare to the
  existing 10 Hz `slowPathTick` and re-attach on mismatch (caps latency at
  ~100 ms, a few lines). THEN, if still not fast enough, the AltTab/yabai
  observer pool: one `AXObserver` per running app registered for
  `kAXApplicationActivatedNotification` +
  `kAXFocusedWindowChangedNotification`, maintained against app
  launch/terminate notifications — sub-frame latency, documented APIs. The
  private SLS notification route was considered and is NOT recommended first.

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

