# cross-app-activation-latency — plan (standard tier, light)

Evidence: `arch-reviews/2026-09-01-active-window-tracking.md` F2.

## Acceptance criteria

1. After clicking a window of a different app, the emphasis moves to it within
   ~100 ms even when `NSWorkspace.didActivateApplicationNotification` is late.
2. No change in behavior when the frontmost app hasn't changed (the check must
   be cheap enough for the 10 Hz slow path — one pid compare).

## Changes

- `ActiveWindowTracker.slowPathTick`: before the existing branches, compare
  `NSWorkspace.shared.frontmostApplication?.processIdentifier` against
  `observedProcessID`; on mismatch run `attachToFrontmostApplication()` +
  `refreshFocusContext()` and return. This caps cross-app latency at one
  slow-path period (~100 ms) instead of the workspace notification's lag.

## Scope decision

The TODO entry's step 2 (per-running-app AXObserver pool for sub-frame
cross-app latency) is deliberately NOT built here: whether ~100 ms worst-case
still "feels slow" is Felix's call to make on the running app, and the pool
carries real bookkeeping (launch/terminate maintenance, observer lifetime).
Filed as `(ax-observer-pool-per-app)` in TODO §1, triggered on Felix judging
the capped latency still too slow.

## Decisions taken

- 2026-09-01: `frontmostApplication` is read once per slow tick (10 Hz). This
  is an inexpensive main-thread call; no separate timer added.
