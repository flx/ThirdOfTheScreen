# DONE

Shipped items, newest first. Format: slug — date, commit, one-line record.

- (ax-observer-pool-per-app) — 2026-09-01, CLOSED WITHOUT CODE, decided with
  Felix. The item was TRIGGERED on him judging the ~100 ms cross-app cap
  (from `(cross-app-activation-latency)`) still slow; testing the Release
  build he reported the opposite — "much faster" — so the trigger can never
  fire and the per-app AXObserver pool's bookkeeping is not bought. If
  cross-app latency ever regresses, re-file from the entry preserved in this
  repo's history (TODO.md at merge `9ed9921`) rather than re-deriving.

- (fast-path-display-link-duty-cycle) — 2026-09-01, commit: see log. The
  CADisplayLink now duty-cycles: AX moved/resized wake it (and no longer
  trigger a full AX refresh per drag frame); the slow path pauses it 250 ms
  after the last motion; a bounds-miss wakes it so window-gone grace is
  measured at frame rate; it is created on / retargeted to the tracked
  window's screen with 1.25× hysteresis. Idle cost drops from one CGWindowList
  IPC per frame to one per 100 ms. A ~1 Hz slow-path focus re-resolve replaces
  the self-heal that per-move refreshes used to provide. adv-review-edge
  (combined with the screen-change item): 9 findings incl. one HIGH
  (stopped-tracker link resurrection), all fixed pre-commit — disposition in
  `plans/shipped/fast-path-display-link-duty-cycle.plan.md`.

- (screen-change-skips-emphasis-overlay) — 2026-09-01, commit: see log.
  `didChangeScreenParametersNotification` now re-resolves the tracker AND
  re-pushes the emphasis unconditionally (the publish dedupe otherwise skips
  the recompute when only screen geometry changed — review R3);
  `ActiveWindowTracker.refresh()` gained an `isRunning` guard so space/screen
  observers can no longer re-install AX observation on a stopped tracker
  (pre-existing bug); `panelGeometry` picks the max-intersection screen,
  matching the tracker (review R9).

- (ax-element-to-window-id-drop-geometry-matcher) — 2026-09-01, commit: see
  log. Focused-window CGWindowID now comes from dlsym-resolved private
  `_AXUIElementGetWindow` (verified resolving at runtime); adoption is gated
  on the window being on the current on-screen list with layer 0 and
  alpha > 0 — the matcher's own filters, and the gate that prevents AX's
  Space-agnostic answer from livelocking the window-gone teardown (review R1,
  critical). Geometry matcher retained verbatim as per-call fallback; the
  10 Hz full window-list scan runs only while the number is unresolved.
  Review ran combined with the latency item: 6 findings, all accepted (R1
  critical fixed pre-commit), disposition in `plans/shipped/`.

- (cross-app-activation-latency) — 2026-09-01, commit: see log. Step 1 only:
  the 10 Hz slow path now compares `NSWorkspace.frontmostApplication`'s pid
  against the observed pid and re-attaches on mismatch, capping cross-app
  emphasis latency at ~100 ms instead of
  `didActivateApplicationNotification`'s lag. Step 2 (per-app AXObserver pool,
  sub-frame latency) filed as `(ax-observer-pool-per-app)`, TRIGGERED on Felix
  judging the cap still too slow. Code review ran combined with the matcher
  item's diff (same function) — see that plan's disposition.

- (emphasis-punchout-outlives-closed-window) — 2026-09-01, commit: see log.
  The reported Finder bug. Tracker now observes kAXUIElementDestroyed +
  kAXWindowMiniaturized on the window element and kAXApplicationHidden on the
  app; `verifyPrimaryWindowPresence()` (time-based 60 ms miss grace, keyed to
  the window number, no size floor) runs from BOTH the display link and the
  10 Hz slow path, re-resolving focus BEFORE publishing; the slow path
  self-heals a missing display link; OverlayManager's keep-parenting on
  nil-primary now has a 180 ms hold before clearing. adv-review-edge round:
  7 findings, 5 accepted+fixed, 1 covered, 1 deferred (latent refcon hazard,
  unreachable while singleton) — full disposition in
  `plans/shipped/emphasis-punchout-outlives-closed-window.plan.md`.
  NOT verified by hand: the by-eye check (close/minimize/hide with emphasis
  on; menus must not flicker) needs a GUI sitting.

- (claude-md-architecture-stale) — 2026-09-01, commit: see log. CLAUDE.md's
  architecture section rewritten to match the working-copy code: emphasis is a
  single SLS-parented `EmphasisPanel` with a `CAShapeLayer` even-odd mask (not
  `ScreenOverlayView` destinationOut cutouts), `GridOverlayController` /
  `EmphasisOverlayController` / `PrivateWindowServer` documented, the
  fictional "priority system for transient windows" and `refreshOverlay()`
  removed, coordinate-conversion direction corrected (CG is top-left origin →
  converted TO Cocoa bottom-left, not the reverse). Taken out of queue order
  (was last) while an adversarial review of item 1's diff was in flight —
  doc-only, touches no reviewed file.
