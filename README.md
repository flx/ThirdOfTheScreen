# Third Of The Screen

A macOS menu bar utility that overlays a thirds-grid on your displays and optionally emphasizes the active window by dimming the rest of the screen.

## Features

- **Thirds Grid Overlay** — Divides each display into three equal columns with dashed dividers, showing column widths in points.
- **Active Window Emphasis** — Dims the entire screen except the focused window, drawing attention to what you're working on. Correctly tracks menus, sheets, dialogs, and popovers.
- **Configurable Emphasis Strength** — Four levels (Subtle, Balanced, Strong, Heavy) controlling the dimming opacity.
- **Multi-Display Support** — Automatically creates and manages overlays for every connected display, adapting when displays are added, removed, or reconfigured.
- **Launch at Login** — Register the app to start automatically via `SMAppService`.

## Requirements

- macOS 14.0 (Sonoma) or later
- Accessibility permission (required for active window emphasis)

## Building

The project uses [XcodeGen](https://github.com/yonaskolb/XcodeGen) (v2.38.0+) to generate the Xcode project from `project.yml`.

```bash
xcodegen generate
open ThirdOfTheScreen.xcodeproj
```

Build and run from Xcode. The app appears as a menu bar item ("1/3") with no Dock icon.

## Architecture

```
ThirdOfTheScreenApp          # Entry point, MenuBarExtra UI, state bindings
├── OverlayManager           # Singleton managing overlay state, panels, and persistence
│   ├── ActiveWindowTracker  # Accessibility API window detection and monitoring
│   └── OverlayPanel         # Custom NSPanel configured as a non-interactive screen overlay
├── ScreenOverlayView        # SwiftUI view rendering the grid and emphasis cutouts
└── LaunchAtLoginManager     # SMAppService wrapper for launch-at-login
```

### Components

| Component | Responsibility |
|---|---|
| `ThirdOfTheScreenApp` | App entry point. Creates the `MenuBarExtra` menu and binds UI controls to manager state. |
| `OverlayManager` | Central state manager (singleton). Owns the grid/emphasis toggle state, creates one `NSPanel` per display, coordinates `ActiveWindowTracker`, and persists preferences to `UserDefaults`. |
| `ActiveWindowTracker` | Monitors the focused window via the macOS Accessibility API (`AXUIElement`, `AXObserver`). Resolves transient windows (menus, sheets, popovers) against `CGWindowListCopyWindowInfo` snapshots, computes `WindowCutout` frames with per-corner radii, and publishes updates via an `onUpdate` callback. |
| `ScreenOverlayView` | Pure SwiftUI rendering. Draws the thirds-grid columns and, when emphasis is enabled, a dimmed overlay with transparent cutouts for active windows using blend-mode masking. |
| `LaunchAtLoginManager` | Wraps `SMAppService` to register/unregister login items, checks app location, and surfaces status messages. |

### Data Flow

```
User toggles menu item
  → SwiftUI binding calls OverlayManager method
    → @Published properties update → menu re-renders
    → refreshOverlay() synchronizes NSPanels with current displays
    → ActiveWindowTracker publishes window cutouts via onUpdate callback
      → OverlayManager updates ScreenOverlayView with new cutouts
```

### Key Design Decisions

- **Callback-based coupling**: `ActiveWindowTracker` communicates via `onUpdate` and `excludedWindowNumbersProvider` closures rather than direct references, keeping components loosely coupled.
- **Per-display NSPanels**: Each connected display gets its own `NSPanel` at screen-saver window level. Panels are keyed by `CGDirectDisplayID` and reused across refreshes.
- **Coordinate transformation**: Global (bottom-left origin) window frames from Accessibility/CoreGraphics are converted to screen-local (top-left origin, menu-bar-relative) coordinates for SwiftUI rendering.
- **Window priority system**: When multiple windows are candidates, menus take priority over sheets/dialogs, which take priority over regular windows.
- **Fallback polling**: A 60 FPS timer supplements Accessibility notifications to handle edge cases where notifications are missed (e.g., cross-space transitions).

### Persistence

| UserDefaults Key | Type | Purpose |
|---|---|---|
| `emphasizeActiveWindowEnabled` | `Bool` | Active window emphasis toggle state |
| `emphasisStrength` | `String` | Selected `EmphasisStrength` raw value |

## Project Structure

```
ThirdOfTheScreen/
├── ThirdOfTheScreen/
│   ├── ThirdOfTheScreenApp.swift       # App entry point and menu UI
│   ├── OverlayManager.swift            # Overlay state management and panel lifecycle
│   ├── ActiveWindowTracker.swift       # Accessibility-based window tracking
│   ├── ScreenOverlayView.swift         # SwiftUI overlay rendering
│   ├── LaunchAtLoginManager.swift      # Launch at login management
│   └── Assets.xcassets/                # App icon assets
├── project.yml                         # XcodeGen project definition
├── scripts/                            # Build/automation scripts
└── LICENSE                             # GPL v3
```

## License

[GNU General Public License v3.0](LICENSE)
