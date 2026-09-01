# emphasis-punchout-outlives-closed-window — plan (standard tier, light)

Evidence: `arch-reviews/2026-09-01-active-window-tracking.md` F1.

## Acceptance criteria

1. Closing the emphasized window (incl. the last window of the frontmost app)
   removes the punch-out within ~a quarter second, without selecting anything.
2. Minimizing the emphasized window, or hiding its app, does the same.
3. Menu/sheet/popover transients (brief nil-primary states) still do NOT
   flicker the overlay — the keep-parenting behavior survives for short nils.

## Changes

**ActiveWindowTracker**
- `updateWindowObservationIfNeeded` / teardown: additionally observe
  `kAXUIElementDestroyedNotification` + `kAXWindowMiniaturizedNotification` on
  the window element (remove symmetrically; removal from a dead element errors
  harmlessly). App level: add `kAXApplicationHiddenNotification` alongside the
  existing three. All route through the existing uniform `refresh()` callback.
- `fastPathTick`: count consecutive nil results from `fetchWindowBounds` for a
  known `primaryWindowNumber`. At 3 consecutive nils (~2 frames of grace for
  snapshot hiccups) treat the window as dead: reset primary state, publish,
  `refreshFocusContext()`. Reset the counter on any successful fetch or when
  the primary changes.

**OverlayManager.pushActiveWindowToEmphasis**
- Replace the unconditional "keep current parenting" on nil-primary with a
  deadline: on first nil, start a ~220 ms `Task`; if the tracker still has no
  primary when it fires, `emphasisOverlay.clear()`. A successful push cancels
  it. Emphasis-disabled path is untouched (already clears immediately).

## Decisions taken

- 2026-09-01: 180 ms hold deadline and 60 ms time-based miss grace are chosen
  knobs, not measured constants — sized to be invisible for menu transients yet
  keep grace+hold under a quarter second on any refresh rate. Tune by feel if
  transients flicker.
- 2026-09-01: window-gone detection clears tracker state then calls
  `refreshFocusContext()` BEFORE any publish, so a focus that already moved is
  published directly instead of an intermediate nil (review F7).

## Review round (adv-review-edge, 2026-09-01) and disposition

7 findings; the reviewer probed empirically (measured 100 Hz cadence, empty-
array semantics of `CGWindowListCopyWindowInfo(.optionIncludingWindow)` for
off-screen windows, `NSWindow.windowNumber` stability across orderOut).

- F1 HIGH (gone-detection rode a display link that can silently not exist;
  slow path couldn't substitute) — ACCEPTED. `verifyPrimaryWindowPresence()`
  now runs from BOTH the display link and the 10 Hz slow path, and the slow
  path retries `startFastPathDisplayLink()` when the link is nil.
- F2 MED-HIGH (frame-counted grace + 220 ms hold is 270 ms on 60 Hz) —
  ACCEPTED. Grace is time-based (60 ms, `CACurrentMediaTime`), hold 180 ms.
- F3 MED (miniaturize AX notification is a state no-op) — ACCEPTED AS COVERED:
  the presence check catches minimize within grace+hold via the on-screen
  list; the notification remains as an immediacy hint. No further code.
- F4 MED (miss budget not window-scoped) — ACCEPTED. `boundsMiss` stores the
  window number it was accumulated for; a different number restarts it.
- F5 MED-LOW (4 pt floor makes a live 3 pt window read as closed, and
  unrecoverably so) — ACCEPTED for the liveness probe: `fetchWindowBounds` no
  longer applies the floor; it stays in `windowSnapshots()` for matcher
  candidates. The empty-`NSScreen.screens` arm (everything reads closed) is
  NOT changed: with no screens attached, clearing the emphasis is acceptable
  behavior.
- F6 LOW (latent unretained-refcon hazard if tracker ever non-singleton) —
  DEFERRED, recorded here: unreachable today (singleton + CADisplayLink
  retains target); revisit if ownership changes.
- F7 LOW (nil published before re-resolution) — ACCEPTED, see decision above.
- Re-review SKIPPED, deliberately: the fixes implement the reviewer's own
  recommendations (time-based grace, window-keyed budget, resolve-first) and
  the reviewer already verified the OverlayManager task lifecycle clean; a
  second full round would re-verify its own advice at ~18 min cost.
