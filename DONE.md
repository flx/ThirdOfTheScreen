# DONE

Shipped items, newest first. Format: slug — date, commit, one-line record.

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
