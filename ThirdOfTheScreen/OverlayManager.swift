import AppKit
import SwiftUI

struct ScreenCutout {
    let frame: CGRect
    let topLeadingRadius: CGFloat
    let topTrailingRadius: CGFloat
    let bottomLeadingRadius: CGFloat
    let bottomTrailingRadius: CGFloat
}

@MainActor
final class OverlayManager: ObservableObject {
    static let shared = OverlayManager()

    enum EmphasisStrength: String, CaseIterable, Identifiable {
        case subtle
        case balanced
        case strong
        case heavy

        var id: String { rawValue }

        var label: String {
            switch self {
            case .subtle:
                "Subtle"
            case .balanced:
                "Balanced"
            case .strong:
                "Strong"
            case .heavy:
                "Heavy"
            }
        }

        var opacity: Double {
            switch self {
            case .subtle:
                0.24
            case .balanced:
                0.36
            case .strong:
                0.50
            case .heavy:
                0.64
            }
        }
    }

    @Published private(set) var isGridOverlayEnabled = false
    @Published private(set) var isActiveWindowEmphasisEnabled = false
    @Published private(set) var emphasisStatusMessage: String?
    @Published private(set) var emphasisStrength: EmphasisStrength = .balanced

    private var overlayPanels: [CGDirectDisplayID: OverlayPanelEntry] = [:]
    private var observers: [NSObjectProtocol] = []
    private var workspaceObservers: [NSObjectProtocol] = []
    private let activeWindowTracker = ActiveWindowTracker()
    private var highlightedWindowCutouts: [WindowCutout] = []
    private var hasRestoredState = false

    private enum DefaultsKey {
        static let emphasizeActiveWindowEnabled = "emphasizeActiveWindowEnabled"
        static let emphasisStrength = "emphasisStrength"
    }

    private init() {
        activeWindowTracker.excludedWindowNumbersProvider = { [weak self] in
            self?.excludedWindowNumbers ?? []
        }

        activeWindowTracker.onUpdate = { [weak self] highlightedWindowCutouts, statusMessage in
            guard let self else { return }
            self.highlightedWindowCutouts = highlightedWindowCutouts
            self.emphasisStatusMessage = statusMessage
            self.refreshOverlay()
        }

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
                    self?.activeWindowTracker.refresh()
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

    var hasAnyOverlay: Bool {
        isGridOverlayEnabled || isActiveWindowEmphasisEnabled
    }

    private var excludedWindowNumbers: Set<Int> {
        Set(overlayPanels.values.map { $0.panel.windowNumber })
    }

    func restoreState() {
        guard !hasRestoredState else { return }
        hasRestoredState = true

        if let storedStrength = UserDefaults.standard.string(forKey: DefaultsKey.emphasisStrength),
           let emphasisStrength = EmphasisStrength(rawValue: storedStrength) {
            self.emphasisStrength = emphasisStrength
        }

        setGridOverlayEnabled(true)

        if UserDefaults.standard.bool(forKey: DefaultsKey.emphasizeActiveWindowEnabled) {
            setActiveWindowEmphasisEnabled(true, promptForAccess: false)
        }
    }

    func setGridOverlayEnabled(_ enabled: Bool) {
        guard isGridOverlayEnabled != enabled else { return }
        isGridOverlayEnabled = enabled
        refreshOverlay()
    }

    func setActiveWindowEmphasisEnabled(_ enabled: Bool, promptForAccess: Bool = true) {
        if enabled {
            let didStart = activeWindowTracker.start(promptForAccess: promptForAccess)
            isActiveWindowEmphasisEnabled = didStart
            emphasisStatusMessage = activeWindowTracker.statusMessage
            if !didStart {
                highlightedWindowCutouts = []
            }
            UserDefaults.standard.set(didStart, forKey: DefaultsKey.emphasizeActiveWindowEnabled)
        } else {
            activeWindowTracker.stop()
            isActiveWindowEmphasisEnabled = false
            emphasisStatusMessage = nil
            highlightedWindowCutouts = []
            UserDefaults.standard.set(false, forKey: DefaultsKey.emphasizeActiveWindowEnabled)
        }

        refreshOverlay()
    }

    func setEmphasisStrength(_ emphasisStrength: EmphasisStrength) {
        guard self.emphasisStrength != emphasisStrength else { return }
        self.emphasisStrength = emphasisStrength
        UserDefaults.standard.set(emphasisStrength.rawValue, forKey: DefaultsKey.emphasisStrength)
        refreshOverlay()
    }

    func refreshOverlay() {
        guard hasAnyOverlay else {
            closeOverlayPanels()
            return
        }

        synchronizeOverlayPanels()
    }

    private func synchronizeOverlayPanels() {
        var currentDisplayIDs = Set<CGDirectDisplayID>()

        for screen in NSScreen.screens {
            guard !screen.visibleFrame.isEmpty, let displayID = screen.displayID else { continue }
            currentDisplayIDs.insert(displayID)

            let overlayView = ScreenOverlayView(
                showGrid: isGridOverlayEnabled,
                emphasisEnabled: isActiveWindowEmphasisEnabled,
                emphasisOpacity: emphasisStrength.opacity,
                activeWindowCutouts: localCutouts(for: screen)
            )

            if let entry = overlayPanels[displayID] {
                if entry.panel.frame != screen.visibleFrame {
                    entry.panel.setFrame(screen.visibleFrame, display: true)
                }
                entry.hostingView.rootView = overlayView
                if !entry.panel.isVisible {
                    entry.panel.orderFrontRegardless()
                }
            } else {
                let panel = OverlayPanel(contentRect: screen.visibleFrame)
                let hostingView = NSHostingView(rootView: overlayView)
                panel.contentView = hostingView
                panel.orderFrontRegardless()
                overlayPanels[displayID] = OverlayPanelEntry(panel: panel, hostingView: hostingView)
            }
        }

        let staleDisplayIDs = Set(overlayPanels.keys).subtracting(currentDisplayIDs)
        for displayID in staleDisplayIDs {
            if let entry = overlayPanels.removeValue(forKey: displayID) {
                entry.panel.orderOut(nil)
                entry.panel.close()
            }
        }
    }

    private func closeOverlayPanels() {
        overlayPanels.values.forEach { entry in
            entry.panel.orderOut(nil)
            entry.panel.close()
        }
        overlayPanels.removeAll()
    }

    private func localCutouts(for screen: NSScreen) -> [ScreenCutout] {
        guard isActiveWindowEmphasisEnabled else { return [] }

        let visibleFrame = screen.visibleFrame
        let tolerance: CGFloat = 1

        return highlightedWindowCutouts.compactMap { cutout in
            let intersection = cutout.frame.intersection(visibleFrame)
            guard !intersection.isNull, !intersection.isEmpty else { return nil }

            let localFrame = CGRect(
                x: intersection.minX - visibleFrame.minX,
                y: visibleFrame.maxY - intersection.maxY,
                width: intersection.width,
                height: intersection.height
            )

            let r = cutout.cornerRadius

            // Only zero a corner's radius when the window extends far enough
            // beyond the visible frame that the rounded corner is fully
            // off-screen.  A window merely touching the edge still has its
            // corner visible.
            let clippedLeft   = cutout.frame.minX < visibleFrame.minX - r
            let clippedRight  = cutout.frame.maxX > visibleFrame.maxX + r
            let clippedTop    = cutout.frame.maxY > visibleFrame.maxY + r
            let clippedBottom = cutout.frame.minY < visibleFrame.minY - r

            return ScreenCutout(
                frame: localFrame,
                topLeadingRadius:     (clippedTop    && clippedLeft)  ? 0 : r,
                topTrailingRadius:    (clippedTop    && clippedRight) ? 0 : r,
                bottomLeadingRadius:  (clippedBottom && clippedLeft)  ? 0 : r,
                bottomTrailingRadius: (clippedBottom && clippedRight) ? 0 : r
            )
        }
    }
}

private struct OverlayPanelEntry {
    let panel: OverlayPanel
    let hostingView: NSHostingView<ScreenOverlayView>
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

private extension NSScreen {
    var displayID: CGDirectDisplayID? {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)
            .map { CGDirectDisplayID(truncating: $0) }
    }
}
