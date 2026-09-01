import AppKit
import SwiftUI

@MainActor
final class GridOverlayController {
    private(set) var isEnabled = false
    private var panels: [CGDirectDisplayID: GridPanelEntry] = [:]

    var excludedWindowNumbers: Set<Int> {
        Set(panels.values.map { $0.panel.windowNumber })
    }

    func setEnabled(_ enabled: Bool) {
        guard isEnabled != enabled else { return }
        isEnabled = enabled
        if enabled {
            synchronizePanels()
        } else {
            closePanels()
        }
    }

    func synchronizePanels() {
        guard isEnabled else { return }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        var currentDisplayIDs = Set<CGDirectDisplayID>()

        for screen in NSScreen.screens {
            guard !screen.visibleFrame.isEmpty, let displayID = screen.displayID else { continue }
            currentDisplayIDs.insert(displayID)

            let overlayView = ScreenOverlayView(showGrid: true)

            if let entry = panels[displayID] {
                if entry.panel.frame != screen.visibleFrame {
                    entry.panel.setFrame(screen.visibleFrame, display: true)
                }
                entry.hostingView.rootView = overlayView
                if !entry.panel.isVisible {
                    entry.panel.orderFrontRegardless()
                }
            } else {
                let panel = GridPanel(contentRect: screen.visibleFrame)
                let hostingView = NSHostingView(rootView: overlayView)
                panel.contentView = hostingView
                panel.orderFrontRegardless()
                panels[displayID] = GridPanelEntry(panel: panel, hostingView: hostingView)
            }
        }

        let staleDisplayIDs = Set(panels.keys).subtracting(currentDisplayIDs)
        for displayID in staleDisplayIDs {
            if let entry = panels.removeValue(forKey: displayID) {
                entry.panel.orderOut(nil)
                entry.panel.close()
            }
        }
    }

    private func closePanels() {
        panels.values.forEach { entry in
            entry.panel.orderOut(nil)
            entry.panel.close()
        }
        panels.removeAll()
    }
}

private struct GridPanelEntry {
    let panel: GridPanel
    let hostingView: NSHostingView<ScreenOverlayView>
}

private final class GridPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        level = .screenSaver
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        ignoresMouseEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        hidesOnDeactivate = false
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)
            .map { CGDirectDisplayID(truncating: $0) }
    }
}
