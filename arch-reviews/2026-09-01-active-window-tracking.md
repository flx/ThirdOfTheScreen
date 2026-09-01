# Arch review — active-window tracking latency & stale emphasis punch-out

2026-09-01. Reviewed against the **uncommitted working copy** (HEAD `50b2803` plus
the staged `EmphasisStripsController → EmphasisOverlayController` rename and
related edits). Line numbers cite that working-copy state, not any commit.

Scope, per Felix: (1) can "Emphasize Active Window" track faster than it does;
(2) the bright punch-out sometimes outlives its window — "if a small Finder
window closes, the bright punch-out may stay there for a bit until I select a
new window."

## How tracking works today (verified, not from CLAUDE.md — which is stale, see F7)

`ActiveWindowTracker` has four inputs:

1. **Workspace notifications** — `NSWorkspace.didActivateApplicationNotification`
   and `activeSpaceDidChangeNotification` re-attach an `AXObserver` to the
   frontmost app (`ActiveWindowTracker.swift:76-105`).
2. **AX notifications** on the observed app/window — focused-window changed,
   main-window changed, app activated, window moved/resized
   (`:212-214`, `:266-277`). Callback hops to the main actor and runs
   `refresh()` (`:484-491`).
3. **Fast path** — a `CADisplayLink` at display refresh rate re-reads the known
   window's bounds via `CGWindowListCopyWindowInfo(.optionIncludingWindow)`
   every frame (`:131-174`).
4. **Slow path** — a 10 Hz timer; if a frame is known it re-runs
   `matchPrimaryWindowNumber()`, which copies the **entire on-screen window
   list** and geometry-matches it against the last AX frame (`:153-163`,
   `:320-335`, `:378-406`).

The AX side never learns the `CGWindowID` directly: the focused `AXUIElement`'s
frame is matched against `CGWindowListCopyWindowInfo` snapshots by
IoU-plus-center-distance score (`matchScore`, `:430-438`). The emphasis panel is
then parented to that window ID via private `SLSSetWindowParent`
(`EmphasisOverlayController.swift:32-62`, `PrivateWindowServer.swift`), so drag
motion is handled by the WindowServer, and the cutout follows via the fast path.

## F1 — Stale punch-out when the focused window closes (the Finder complaint) — CONFIRMED, mechanism found

Nothing in the tracker observes window destruction, and both fallback paths are
written to *hold* stale state rather than drop it:

- `kAXUIElementDestroyedNotification` is never registered — the only
  window-element notifications are moved/resized (`:266-277`). Miniaturize and
  app-hide are equally unobserved.
- `fastPathTick` (`:165-174`): when `fetchWindowBounds` returns nil — which is
  exactly what happens once the window is gone, `CGWindowListCopyWindowInfo`
  with `.optionIncludingWindow` comes back empty — it **silently returns**,
  keeping `primaryWindowNumber`/`primaryWindowFrame` forever.
- `slowPathTick` (`:153-163`): takes the `else` branch because
  `primaryWindowFrame` is still non-nil, and `matchPrimaryWindowNumber`
  (`:320-335`) returns without clearing anything when the app has no other
  on-screen windows. Worse: `bestMatchingPrimarySnapshot` is `snapshots.max`
  with **no minimum score**, so with other windows present it silently re-locks
  onto a window with zero overlap.
- Even when the AX side *does* notice (closing the last Finder window fires
  `kAXFocusedWindowChangedNotification`, `refreshFocusContext` finds no focused
  window and resets state, `:296-299`), the display side keeps the panel:
  `OverlayManager.pushActiveWindowToEmphasis` guards on
  `primaryWindowNumber`/`primaryWindowFrame` being present and otherwise
  **"keep[s] current parenting"** (`OverlayManager.swift:224-228`). The panel
  stays up, cutout and all, until a new primary arrives — precisely "until I
  select a new window."

The keep-parenting guard exists for a reason (transient nils while a menu or
sheet has focus shouldn't flicker the overlay), but it currently cannot tell
"transient nil" from "window is dead," and the WindowServer parent it clings to
no longer exists.

Fix directions (they compose; the first two suffice):
- Register `kAXUIElementDestroyedNotification` on the observed window element in
  `updateWindowObservationIfNeeded`; on fire, clear primary state, clear the
  overlay, and `refreshFocusContext()`.
- In `fastPathTick`, treat N consecutive nil bounds fetches (N=2–3 frames guards
  against snapshot hiccups) as "window gone": clear + re-resolve. This is the
  belt-and-braces path that also catches destroyed windows the AX observer
  missed.
- Give `pushActiveWindowToEmphasis`'s keep-parenting branch a deadline: keep
  through a nil lasting under ~200 ms (menu/sheet transitions), clear after.
- Also cover miniaturize (`kAXWindowMiniaturizedNotification`) and app hide
  (`kAXApplicationHiddenNotification`): a minimized window still resolves via
  `.optionIncludingWindow`, so the nil-fetch heuristic does NOT catch those two.

## F2 — Cross-app switch latency is bounded by `didActivateApplicationNotification`

Within one app, focus changes arrive via AX notifications — effectively
immediate. Across apps, the only trigger is
`NSWorkspace.didActivateApplicationNotification` (`:80-91`), which is delivered
noticeably after the visual focus switch (order 100 ms+, and it can be later
under load — estimating from experience, not a citation). Until it lands, the
overlay still emphasizes the previous app's window. The 10 Hz slow path does not
help: it only re-matches windows of the *already-observed* pid.

Fix directions, in ascending order of invasiveness:
- Keep the workspace notification but add a cheap frontmost-app poll to the
  existing 10 Hz slow path (`NSWorkspace.shared.frontmostApplication.processIdentifier
  != observedProcessID` → re-attach). Caps cross-app latency at ~100 ms for one
  pointer compare per tick. Smallest change, big perceived win.
- The AltTab/yabai pattern (standard practice in this app category): keep one
  `AXObserver` per *running* application, registered for
  `kAXApplicationActivatedNotification` + `kAXFocusedWindowChangedNotification`,
  maintained against `didLaunch`/`didTerminate` workspace notifications. Gets
  sub-frame cross-app latency with documented APIs; costs the observer-pool
  bookkeeping.
- Private route: `SLSRegisterNotifyProc`-family frontmost/window notifications.
  In character with `PrivateWindowServer`, but more undocumented surface for
  little gain over the observer pool. Not recommended first.

## F3 — The AX→CGWindowID geometry matcher is the structural weak point

`matchPrimaryWindowNumber` + `windowSnapshots` + `bestMatchingPrimarySnapshot` +
the ≥4 pt `nearlyEquals` invalidation in `refreshFocusContext` (`:311-313`)
exist only to answer one question: *which `CGWindowID` belongs to this
`AXUIElement`?* The private symbol `_AXUIElementGetWindow(AXUIElement,
UnsafeMutablePointer<CGWindowID>)` answers it directly; it is the same trick
AltTab/yabai/Rectangle-class utilities use, and this app already commits to
dlsym-resolved private symbols with graceful fallback (`PrivateWindowServer`).
Adopting it (with the current matcher kept as the fallback when the symbol is
missing) deletes:
- the zero-overlap mis-lock (F1's third bullet),
- the 10 Hz full-window-list scan (F4),
- the frame-tolerance invalidation heuristic,
and shrinks F1/F2 fixes because identity becomes exact.

## F4 — Standing cost: full window-list copy at 10 Hz, plus one IPC per frame

While emphasis is on, `slowPathTick` copies and filters the entire on-screen
window list ten times a second even when nothing changes (`:378-406`), and the
`CADisplayLink` does one `CGWindowListCopyWindowInfo` IPC per frame — 120 Hz on
ProMotion — even when the window is idle (`:165-174`). Parenting already makes
the panel *move* with the window; the fast path only serves the cutout. A duty
cycle fixes it: run the display link only while an AX moved/resized burst is
live (start on `kAXWindowMoved`/`kAXWindowResized`, stop ~250 ms after the last
one). The slow-path scan disappears with F3. Also: every `kAXWindowMoved` during
a drag runs `refresh()` → two AX attribute IPCs + a full list copy
(`:56-66` via `:283-318`) on top of the per-frame fast path — redundant work in
exactly the hot case.

## F5 — Display link is created for one screen, once

`startFastPathDisplayLink` picks `NSScreen.main ?? screens.first` at start and
never migrates (`:113-124`). On multi-display setups the tick rate is whatever
that screen refreshes at (wrong cadence when the active window is on the other
display), and the link is not re-created on screen-parameter changes. Minor —
worth folding into whatever F4 becomes.

## F6 — `didChangeScreenParametersNotification` skips the emphasis overlay

`OverlayManager`'s observer only calls `gridOverlay.synchronizePanels()`
(`OverlayManager.swift:112-122`). The emphasis panel's frame is recomputed only
on the next `setActiveWindow`, so after a display re-arrangement the dim layer
can sit wrong until focus next changes. Low impact because updates are frequent,
but it is an easy one-liner alongside a `refreshFocusContext()`.

## F7 — CLAUDE.md's architecture section no longer matches the code

CLAUDE.md still describes `ScreenOverlayView` drawing the "emphasis overlay with
transparent cutouts using `blendMode(.destinationOut)`" and an NSPanel-per-
display model for emphasis. Since the rename, emphasis is a single
`EmphasisPanel` with a `CAShapeLayer` even-odd mask, parented to the active
window via `PrivateWindowServer` (`EmphasisOverlayController.swift`), and
`ScreenOverlayView` draws only the grid. `EmphasisStripsController` no longer
exists. Doc-only, but it is the file this reviewer is told to trust.

## Noted, deliberately NOT filed

- `restoreState` force-enables the grid overlay and never persists its toggle
  (`OverlayManager.swift:167`) — looks intentional (the grid is the app's
  raison d'être); flagging only in case it isn't.
- `ScreenOverlayView`'s "Thirds Overlay" info card and per-column capsules read
  like debug chrome; product taste, not architecture.
- `axFocusChangeCallback` retains `self` unmanaged (`:484-491`) — safe today
  because the tracker is owned by a singleton and never deallocated; would need
  revisiting only if that changes.
- Overall structure (callback coupling, `@MainActor` everywhere, per-display
  grid panels, dlsym-guarded private symbols) is sound for the app's size; no
  structural refactor is warranted beyond F3.
