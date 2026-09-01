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
- **OverlayManager** — `@MainActor` singleton. Owns grid/emphasis state, creates one `NSPanel` per display (keyed by `CGDirectDisplayID`), coordinates `ActiveWindowTracker`, persists to `UserDefaults`.
- **ActiveWindowTracker** — `@MainActor`. Uses Accessibility API (`AXUIElement`/`AXObserver`) + `CGWindowListCopyWindowInfo` snapshots + 60 FPS fallback polling. Resolves transient windows (menus, sheets, popovers) with a priority system. Communicates via `onUpdate` callback and `excludedWindowNumbersProvider` closure.
- **ScreenOverlayView** — Stateless SwiftUI view. Draws thirds-grid columns and emphasis overlay with transparent cutouts using `blendMode(.destinationOut)` + `compositingGroup()`.
- **LaunchAtLoginManager** — `@MainActor` wrapper around `SMAppService`.

**Key patterns:**

- Callback-based coupling between tracker and manager (no direct references)
- Global (bottom-left origin) coordinates from Accessibility/CG are converted to screen-local (top-left, menu-bar-relative) for SwiftUI
- `@Published` properties drive SwiftUI reactivity; panels are synchronized via `refreshOverlay()`
- No external dependencies — pure Apple frameworks (SwiftUI, AppKit, ApplicationServices, ServiceManagement)
