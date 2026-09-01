# ax-element-to-window-id-drop-geometry-matcher — plan (standard tier, light)

Evidence: `arch-reviews/2026-09-01-active-window-tracking.md` F3.

## Acceptance criteria

1. When `_AXUIElementGetWindow` resolves (every current macOS), the focused
   window's `CGWindowID` comes from the AX element directly: no full
   window-list scan, no IoU matching, no ≥4 pt frame-invalidation heuristic on
   that path.
2. When the symbol is missing (future macOS), the existing geometry matcher
   still works — same dlsym-with-fallback pattern as `PrivateWindowServer`'s
   SLS symbols.
3. The zero-overlap mis-lock (`bestMatchingPrimarySnapshot` = `snapshots.max`
   with no minimum score) can no longer fire on the direct path.

## Changes

- `PrivateWindowServer`: add `windowID(for: AXUIElement) -> WindowID?` wrapping
  dlsym-resolved `_AXUIElementGetWindow(AXUIElementRef, CGWindowID*) -> AXError`
  (HIServices; import ApplicationServices). nil on unresolved symbol, error, or
  windowID 0.
- `ActiveWindowTracker.refreshFocusContext`: try the direct lookup first; on
  success assign `primaryWindowNumber` + AX frame and skip both the ≥4 pt
  invalidation and `matchPrimaryWindowNumber()`. On nil, fall through to the
  existing heuristic path unchanged.
- `slowPathTick`: run `matchPrimaryWindowNumber()` only when
  `primaryWindowNumber == nil` (i.e. the fallback path hasn't resolved one) —
  the 10 Hz full-list re-match otherwise retires. Frame updates stay on the
  fast path; cross-app changes are covered by AX + the frontmost-pid check
  from `(cross-app-activation-latency)`.

## Decisions taken

- 2026-09-01: fallback keeps the OLD matcher semantics (including its
  weaknesses) rather than trying to harden a path that no shipping macOS
  takes; hardening it would be untestable dead code on every current system.
- 2026-09-01: continuous 10 Hz re-matching (which also re-wrote
  `primaryWindowFrame` from snapshots) is dropped in favor of match-once-
  when-nil; the fast path owns frame freshness. This also removes a source of
  fights between the two paths.
