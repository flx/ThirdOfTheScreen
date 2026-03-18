import AppKit
import SwiftUI

@MainActor
final class OverlayManager: ObservableObject {
    static let shared = OverlayManager()

    @Published private(set) var isOverlayVisible = false

    private var overlayPanels: [OverlayPanel] = []
    private var observers: [NSObjectProtocol] = []
    private var workspaceObservers: [NSObjectProtocol] = []

    private init() {
        let notificationCenter = NotificationCenter.default
        observers.append(
            notificationCenter.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.refreshOverlay()
                }
            }
        )

        let workspaceCenter = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(
            workspaceCenter.addObserver(
                forName: NSWorkspace.activeSpaceDidChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.refreshOverlay()
                }
            }
        )
    }

    deinit {
        let notificationCenter = NotificationCenter.default
        observers.forEach(notificationCenter.removeObserver)

        let workspaceCenter = NSWorkspace.shared.notificationCenter
        workspaceObservers.forEach(workspaceCenter.removeObserver)
    }

    func toggleOverlay() {
        if isOverlayVisible {
            hideOverlay()
        } else {
            showOverlay()
        }
    }

    func showOverlay() {
        isOverlayVisible = true
        rebuildOverlayPanels()
    }

    func hideOverlay() {
        isOverlayVisible = false
        closeOverlayPanels()
    }

    func refreshOverlay() {
        guard isOverlayVisible else { return }
        rebuildOverlayPanels()
    }

    private func rebuildOverlayPanels() {
        closeOverlayPanels()

        overlayPanels = NSScreen.screens.compactMap { screen in
            guard !screen.visibleFrame.isEmpty else { return nil }

            let panel = OverlayPanel(contentRect: screen.visibleFrame)
            panel.contentView = NSHostingView(rootView: GridOverlayView())
            panel.orderFrontRegardless()
            return panel
        }
    }

    private func closeOverlayPanels() {
        overlayPanels.forEach { panel in
            panel.orderOut(nil)
            panel.close()
        }
        overlayPanels.removeAll()
    }
}

private final class OverlayPanel: NSPanel {
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
