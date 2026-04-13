import AppKit
import OSLog
import SwiftUI

private let overlayLog = Logger(subsystem: "com.felix.thirdofthescreen", category: "Overlay")

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
                0.12
            case .balanced:
                0.22
            case .strong:
                0.36
            case .heavy:
                0.52
            }
        }
    }

    enum EmphasisTint: String, CaseIterable, Identifiable {
        case neutral
        case red
        case green
        case blue

        var id: String { rawValue }

        var label: String {
            switch self {
            case .neutral: "Neutral"
            case .red: "Red"
            case .green: "Green"
            case .blue: "Blue"
            }
        }

        var color: NSColor {
            switch self {
            case .neutral:
                NSColor(red: 0.07, green: 0.08, blue: 0.10, alpha: 1.0)
            case .red:
                NSColor(red: 0.22, green: 0.05, blue: 0.05, alpha: 1.0)
            case .green:
                NSColor(red: 0.05, green: 0.18, blue: 0.07, alpha: 1.0)
            case .blue:
                NSColor(red: 0.05, green: 0.08, blue: 0.24, alpha: 1.0)
            }
        }
    }

    @Published private(set) var isGridOverlayEnabled = false
    @Published private(set) var isActiveWindowEmphasisEnabled = false
    @Published private(set) var emphasisStatusMessage: String?
    @Published private(set) var emphasisStrength: EmphasisStrength = .balanced
    @Published private(set) var emphasisTint: EmphasisTint = .neutral

    private var overlayPanels: [CGDirectDisplayID: OverlayPanelEntry] = [:]
    private var observers: [NSObjectProtocol] = []
    private var workspaceObservers: [NSObjectProtocol] = []
    private let activeWindowTracker = ActiveWindowTracker()
    private let emphasisStrips = EmphasisStripsController()
    private var hasRestoredState = false

    private enum DefaultsKey {
        static let emphasizeActiveWindowEnabled = "emphasizeActiveWindowEnabled"
        static let emphasisStrength = "emphasisStrength"
        static let emphasisTint = "emphasisTint"
    }

    private init() {
        activeWindowTracker.excludedWindowNumbersProvider = { [weak self] in
            self?.excludedWindowNumbers ?? []
        }

        activeWindowTracker.onUpdate = { [weak self] _, statusMessage in
            guard let self else { return }
            self.emphasisStatusMessage = statusMessage
            self.updateEmphasisStrips()
        }

        applyEmphasisAppearance()

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
        var set = Set(overlayPanels.values.map { $0.panel.windowNumber })
        set.formUnion(emphasisStrips.excludedWindowNumbers)
        return set
    }

    func restoreState() {
        guard !hasRestoredState else { return }
        hasRestoredState = true

        if let storedStrength = UserDefaults.standard.string(forKey: DefaultsKey.emphasisStrength),
           let emphasisStrength = EmphasisStrength(rawValue: storedStrength) {
            self.emphasisStrength = emphasisStrength
        }

        if let storedTint = UserDefaults.standard.string(forKey: DefaultsKey.emphasisTint),
           let emphasisTint = EmphasisTint(rawValue: storedTint) {
            self.emphasisTint = emphasisTint
        }

        applyEmphasisAppearance()

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
                emphasisStrips.clear()
            }
            UserDefaults.standard.set(didStart, forKey: DefaultsKey.emphasizeActiveWindowEnabled)
        } else {
            activeWindowTracker.stop()
            isActiveWindowEmphasisEnabled = false
            emphasisStatusMessage = nil
            emphasisStrips.clear()
            UserDefaults.standard.set(false, forKey: DefaultsKey.emphasizeActiveWindowEnabled)
        }

        refreshOverlay()
        updateEmphasisStrips()
    }

    func setEmphasisStrength(_ emphasisStrength: EmphasisStrength) {
        guard self.emphasisStrength != emphasisStrength else { return }
        self.emphasisStrength = emphasisStrength
        UserDefaults.standard.set(emphasisStrength.rawValue, forKey: DefaultsKey.emphasisStrength)
        applyEmphasisAppearance()
    }

    func setEmphasisTint(_ emphasisTint: EmphasisTint) {
        guard self.emphasisTint != emphasisTint else { return }
        self.emphasisTint = emphasisTint
        UserDefaults.standard.set(emphasisTint.rawValue, forKey: DefaultsKey.emphasisTint)
        applyEmphasisAppearance()
    }

    private func applyEmphasisAppearance() {
        emphasisStrips.setAppearance(color: emphasisTint.color, opacity: emphasisStrength.opacity)
    }

    func refreshOverlay() {
        guard hasAnyOverlay else {
            closeOverlayPanels()
            return
        }

        synchronizeOverlayPanels()
    }

    private var lastEmphasisWindowNumber: Int?

    private func updateEmphasisStrips() {
        guard isActiveWindowEmphasisEnabled else {
            emphasisStrips.clear()
            return
        }

        guard let windowNumber = activeWindowTracker.primaryWindowNumber,
              let bounds = activeWindowTracker.primaryWindowFrame
        else {
            overlayLog.notice("updateEmphasisStrips: no primary (windowNumber=\(self.activeWindowTracker.primaryWindowNumber ?? -1), frame-present=\(self.activeWindowTracker.primaryWindowFrame != nil)) — keeping current parenting")
            return
        }

        if lastEmphasisWindowNumber != windowNumber {
            overlayLog.notice("updateEmphasisStrips: primary window changed \(self.lastEmphasisWindowNumber ?? -1) -> \(windowNumber)")
            lastEmphasisWindowNumber = windowNumber
        }

        emphasisStrips.setActiveWindow(windowID: CGWindowID(windowNumber), cocoaBounds: bounds)
    }

    private func synchronizeOverlayPanels() {
        var currentDisplayIDs = Set<CGDirectDisplayID>()

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        for screen in NSScreen.screens {
            guard !screen.visibleFrame.isEmpty, let displayID = screen.displayID else { continue }
            currentDisplayIDs.insert(displayID)

            let overlayView = ScreenOverlayView(showGrid: isGridOverlayEnabled)

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
