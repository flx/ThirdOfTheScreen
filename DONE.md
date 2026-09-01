# DONE

Shipped items, newest first. Format: slug — date, commit, one-line record.

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
