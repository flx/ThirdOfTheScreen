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

## Review round (adv-review-behavior, 2026-09-01, combined with cross-app-activation-latency) and disposition

6 findings. The reviewer probed on this machine: `.optionIncludingWindow`
returns 0 records for every window absent from the current Space's on-screen
list (129/129), and `_AXUIElementGetWindow` returns `kAXErrorCannotComplete`
for unservable elements.

- R1 CRITICAL (window-gone teardown livelocks: AX is Space-agnostic, so the
  direct path re-adopted a minimized/other-Space window right after gone-fired;
  publish deduped; emphasis stayed up forever — regressed item 1 for Space
  switches and Electron-style minimize) — ACCEPTED, verified against my own
  code. Fix: adoption now requires `fetchOnScreenWindowInfo` to return a
  record.
- R2 HIGH (direct path dropped the matcher's layer==0 / alpha>0 filters —
  would adopt Spotlight's window) — ACCEPTED. Same fix carries the filters.
  The 4 pt floor is deliberately NOT re-applied to adoption, consistent with
  the round-1 F5 decision.
- R3 LOW (pid branch skipped display-link self-heal) — ACCEPTED, reordered.
- R4 LOW (tick queued across stop() re-attaches observation) — ACCEPTED,
  `isRunning` guard; also covers the display-link-restart sibling from item 1.
- R5 NIT (first publish carried AX frame) — ACCEPTED via R1's fix (adoption
  publishes the CG bounds).
- R6 NIT (comment overclaimed "never entered") — ACCEPTED, reworded; the
  per-call fallback and its retry loop are now stated accurately.
- Clean per reviewer: own-panel adoption impossible (self-pid guard),
  fallback semantics verbatim, no dead code, item A does not fight the
  notification path, ABI of the thunk sane.
- Re-review SKIPPED, deliberately: fixes implement the findings' own remedies;
  the adoption filter reuses exactly the predicate the old matcher applied.

## Decisions taken

- 2026-09-01: fallback keeps the OLD matcher semantics (including its
  weaknesses) rather than trying to harden a path that no shipping macOS
  takes; hardening it would be untestable dead code on every current system.
- 2026-09-01: continuous 10 Hz re-matching (which also re-wrote
  `primaryWindowFrame` from snapshots) is dropped in favor of match-once-
  when-nil; the fast path owns frame freshness. This also removes a source of
  fights between the two paths.
