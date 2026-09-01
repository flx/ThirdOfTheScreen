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

    private let gridOverlay = GridOverlayController()
    private let activeWindowTracker = ActiveWindowTracker()
    private let emphasisOverlay = EmphasisOverlayController()

    private var notificationObservers: [NSObjectProtocol] = []
    private var workspaceObservers: [NSObjectProtocol] = []
    private var hasRestoredState = false
    private var lastEmphasisWindowNumber: Int?
    private var pendingEmphasisClear: Task<Void, Never>?

    private enum DefaultsKey {
        static let emphasizeActiveWindowEnabled = "emphasizeActiveWindowEnabled"
        static let emphasisStrength = "emphasisStrength"
        static let emphasisTint = "emphasisTint"
    }

    private init() {
        activeWindowTracker.excludedWindowNumbersProvider = { [weak self] in
            self?.excludedWindowNumbers ?? []
        }

        activeWindowTracker.onUpdate = { [weak self] statusMessage in
            guard let self else { return }
            self.emphasisStatusMessage = statusMessage
            self.pushActiveWindowToEmphasis()
        }

        applyEmphasisAppearance()

        let notificationCenter = NotificationCenter.default
        notificationObservers.append(
            notificationCenter.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.gridOverlay.synchronizePanels()
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
                    self?.gridOverlay.synchronizePanels()
                }
            }
        )
    }

    deinit {
        let notificationCenter = NotificationCenter.default
        notificationObservers.forEach(notificationCenter.removeObserver)

        let workspaceCenter = NSWorkspace.shared.notificationCenter
        workspaceObservers.forEach(workspaceCenter.removeObserver)
    }

    private var excludedWindowNumbers: Set<Int> {
        gridOverlay.excludedWindowNumbers.union(emphasisOverlay.excludedWindowNumbers)
    }

    func restoreState() {
        guard !hasRestoredState else { return }
        hasRestoredState = true

        if let storedStrength = UserDefaults.standard.string(forKey: DefaultsKey.emphasisStrength),
           let strength = EmphasisStrength(rawValue: storedStrength) {
            emphasisStrength = strength
        }

        if let storedTint = UserDefaults.standard.string(forKey: DefaultsKey.emphasisTint),
           let tint = EmphasisTint(rawValue: storedTint) {
            emphasisTint = tint
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
        gridOverlay.setEnabled(enabled)
    }

    func setActiveWindowEmphasisEnabled(_ enabled: Bool, promptForAccess: Bool = true) {
        if enabled {
            let didStart = activeWindowTracker.start(promptForAccess: promptForAccess)
            isActiveWindowEmphasisEnabled = didStart
            emphasisStatusMessage = activeWindowTracker.statusMessage
            if !didStart {
                emphasisOverlay.clear()
            }
            UserDefaults.standard.set(didStart, forKey: DefaultsKey.emphasizeActiveWindowEnabled)
        } else {
            activeWindowTracker.stop()
            isActiveWindowEmphasisEnabled = false
            emphasisStatusMessage = nil
            emphasisOverlay.clear()
            UserDefaults.standard.set(false, forKey: DefaultsKey.emphasizeActiveWindowEnabled)
        }

        pushActiveWindowToEmphasis()
    }

    func setEmphasisStrength(_ strength: EmphasisStrength) {
        guard emphasisStrength != strength else { return }
        emphasisStrength = strength
        UserDefaults.standard.set(strength.rawValue, forKey: DefaultsKey.emphasisStrength)
        applyEmphasisAppearance()
    }

    func setEmphasisTint(_ tint: EmphasisTint) {
        guard emphasisTint != tint else { return }
        emphasisTint = tint
        UserDefaults.standard.set(tint.rawValue, forKey: DefaultsKey.emphasisTint)
        applyEmphasisAppearance()
    }

    private func applyEmphasisAppearance() {
        emphasisOverlay.setAppearance(color: emphasisTint.color, opacity: emphasisStrength.opacity)
    }

    private func pushActiveWindowToEmphasis() {
        guard isActiveWindowEmphasisEnabled else {
            cancelPendingEmphasisClear()
            emphasisOverlay.clear()
            return
        }

        guard let windowNumber = activeWindowTracker.primaryWindowNumber,
              let bounds = activeWindowTracker.primaryWindowFrame else {
            overlayLog.notice("pushActiveWindowToEmphasis: no primary (windowNumber=\(self.activeWindowTracker.primaryWindowNumber ?? -1), frame-present=\(self.activeWindowTracker.primaryWindowFrame != nil)) — holding current parenting briefly")
            scheduleEmphasisClearAfterHold()
            return
        }

        cancelPendingEmphasisClear()

        if lastEmphasisWindowNumber != windowNumber {
            overlayLog.notice("pushActiveWindowToEmphasis: primary window changed \(self.lastEmphasisWindowNumber ?? -1) -> \(windowNumber)")
            lastEmphasisWindowNumber = windowNumber
        }

        emphasisOverlay.setActiveWindow(windowID: CGWindowID(windowNumber), cocoaBounds: bounds)
    }

    // A nil primary is usually a transient (a menu, sheet or popover holds
    // focus) and clearing immediately would flicker the overlay. But it is
    // also what a closed window leaves behind, so hold only briefly: if no
    // primary re-appears within the deadline, take the emphasis down.
    // 180 ms so that grace-period + hold stays under a quarter second on any
    // display; long enough that menu/sheet focus transients don't flicker.
    private static let emphasisClearHold = Duration.milliseconds(180)

    private func scheduleEmphasisClearAfterHold() {
        guard pendingEmphasisClear == nil else { return }
        pendingEmphasisClear = Task { [weak self] in
            try? await Task.sleep(for: Self.emphasisClearHold)
            guard let self, !Task.isCancelled else { return }
            self.pendingEmphasisClear = nil
            if self.activeWindowTracker.primaryWindowNumber == nil {
                overlayLog.notice("no primary window after hold deadline — clearing emphasis")
                self.emphasisOverlay.clear()
            }
        }
    }

    private func cancelPendingEmphasisClear() {
        pendingEmphasisClear?.cancel()
        pendingEmphasisClear = nil
    }
}
