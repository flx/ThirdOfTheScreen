# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build

The project uses [XcodeGen](https://github.com/yonaskolb/XcodeGen) (v2.38.0+). After changing `project.yml` or adding/removing source files:

```bash
xcodegen generate
```

Build and run from Xcode (`Cmd+R`). There are no tests or linting configured.

## Architecture

macOS menu bar utility (no Dock icon) that overlays a thirds-grid and optionally dims everything except the active window. Requires macOS 14.0+, Accessibility permission for window emphasis.

**Component responsibilities:**

- **ThirdOfTheScreenApp** — `@main` entry point. Creates `MenuBarExtra` with toggles/pickers bound to manager state via custom `Binding`s.
- **OverlayManager** — `@MainActor` singleton. Owns grid/emphasis state and persistence (`UserDefaults`), wires `ActiveWindowTracker` output into `EmphasisOverlayController`, forwards screen/space changes to the controllers.
- **ActiveWindowTracker** — `@MainActor`. Resolves the active window via the Accessibility API (`AXUIElement`/`AXObserver` on the frontmost app and its focused window) plus `CGWindowListCopyWindowInfo`; a `CADisplayLink` fast path follows the window's bounds per frame and a 10 Hz slow-path timer backstops missed notifications. Communicates via `onUpdate` callback and `excludedWindowNumbersProvider` closure.
- **GridOverlayController** — one borderless `NSPanel` per display (keyed by `CGDirectDisplayID`) hosting `ScreenOverlayView`.
- **EmphasisOverlayController** — a single borderless `EmphasisPanel` dimming the screen with a `CAShapeLayer` even-odd mask cut out around the active window. The panel is parented to the active window through private WindowServer calls so it follows drags without polling.
- **PrivateWindowServer** — dlsym-resolved private SkyLight/CGS symbols (`SLSSetWindowParent`, `SLSOrderWindow`) with graceful nil fallback when a future macOS removes them.
- **ScreenOverlayView** — Stateless SwiftUI view drawing the thirds-grid columns for one display.
- **LaunchAtLoginManager** — `@MainActor` wrapper around `SMAppService`.

**Key patterns:**

- Callback-based coupling between tracker and manager (no direct references)
- Global (top-left origin) coordinates from Accessibility/CG are converted to Cocoa (bottom-left origin) via the main display's frame
- `@Published` properties drive SwiftUI reactivity in the menu; the overlay panels are plain AppKit updated imperatively
- Private symbols are always resolved at runtime with a documented fallback — follow `PrivateWindowServer`'s pattern for any new one
- No external dependencies — pure Apple frameworks (SwiftUI, AppKit, ApplicationServices, ServiceManagement)
