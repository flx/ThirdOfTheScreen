# DONE

Shipped items, newest first. Format: slug — date, commit, one-line record.

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
