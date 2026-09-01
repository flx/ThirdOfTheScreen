import AppKit
import ApplicationServices
import Foundation
import OSLog
import QuartzCore

private let trackerLog = Logger(subsystem: "com.felix.thirdofthescreen", category: "ActiveWindow")

@MainActor
final class ActiveWindowTracker: NSObject {
    private static let accessibilityAccessMessage =
        "Allow Accessibility access in System Settings > Privacy & Security > Accessibility. If it is already enabled, remove and re-add Third Of The Screen."
    private static let slowPathRefreshInterval = 1.0 / 10.0
    private static let missedBoundsGrace: CFTimeInterval = 0.06

    var onUpdate: ((String?) -> Void)?
    var excludedWindowNumbersProvider: (() -> Set<Int>)?

    private(set) var statusMessage: String?
    private(set) var primaryWindowNumber: Int?
    private(set) var primaryWindowFrame: CGRect?

    private var workspaceObservers: [NSObjectProtocol] = []
    private var isRunning = false
    private var boundsMiss: (windowNumber: Int, since: CFTimeInterval)?
    private var fastPathDisplayLink: CADisplayLink?
    private var slowPathTimer: Timer?
    private var observedProcessID: pid_t?
    private var observedApplicationElement: AXUIElement?
    private var observedWindowElement: AXUIElement?
    private var observer: AXObserver?

    func start(promptForAccess: Bool) -> Bool {
        guard isAccessibilityTrusted(prompt: promptForAccess) else {
            resetPrimaryState()
            statusMessage = Self.accessibilityAccessMessage
            publishUpdate()
            return false
        }

        isRunning = true
        installWorkspaceObserversIfNeeded()
        startFastPathDisplayLink()
        startSlowPathTimer()
        attachToFrontmostApplication()
        refreshFocusContext()
        return true
    }

    func stop() {
        isRunning = false
        removeWorkspaceObservers()
        stopFastPathDisplayLink()
        stopSlowPathTimer()
        tearDownAccessibilityObservation()
        resetPrimaryState()
        statusMessage = nil
        publishUpdate()
    }

    func refresh() {
        guard AXIsProcessTrusted() else {
            resetPrimaryState()
            statusMessage = Self.accessibilityAccessMessage
            publishUpdate()
            return
        }

        attachToFrontmostApplication()
        refreshFocusContext()
    }

    private func isAccessibilityTrusted(prompt: Bool) -> Bool {
        let options = prompt
            ? [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            : nil

        return AXIsProcessTrustedWithOptions(options)
    }

    private func installWorkspaceObserversIfNeeded() {
        guard workspaceObservers.isEmpty else { return }

        let workspaceCenter = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(
            workspaceCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.attachToFrontmostApplication()
                    self?.refreshFocusContext()
                }
            }
        )

        workspaceObservers.append(
            workspaceCenter.addObserver(
                forName: NSWorkspace.activeSpaceDidChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.attachToFrontmostApplication()
                    self?.refreshFocusContext()
                }
            }
        )
    }

    private func removeWorkspaceObservers() {
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        workspaceObservers.forEach(workspaceCenter.removeObserver)
        workspaceObservers.removeAll()
    }

    private func startFastPathDisplayLink() {
        guard fastPathDisplayLink == nil else { return }

        guard let screen = NSScreen.main ?? NSScreen.screens.first else {
            trackerLog.warning("no NSScreen available to drive fast-path CADisplayLink")
            return
        }

        let link = screen.displayLink(target: self, selector: #selector(handleDisplayLinkTick(_:)))
        link.add(to: .main, forMode: .common)
        fastPathDisplayLink = link
    }

    private func stopFastPathDisplayLink() {
        fastPathDisplayLink?.invalidate()
        fastPathDisplayLink = nil
    }

    @objc private func handleDisplayLinkTick(_ sender: CADisplayLink) {
        fastPathTick()
    }

    private func startSlowPathTimer() {
        guard slowPathTimer == nil else { return }

        let timer = Timer(timeInterval: Self.slowPathRefreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.slowPathTick()
            }
        }
        timer.tolerance = Self.slowPathRefreshInterval / 4
        RunLoop.main.add(timer, forMode: .common)
        slowPathTimer = timer
    }

    private func stopSlowPathTimer() {
        slowPathTimer?.invalidate()
        slowPathTimer = nil
    }

    private func slowPathTick() {
        // A tick can be queued across stop(): the timer fires into a Task, so
        // it may run after teardown and must not re-install observation.
        guard isRunning else { return }

        // The display link can be missing for the whole session (no screen at
        // start, e.g. launch-at-login before displays enumerate) — retry, and
        // never let the window-gone check depend on the link existing.
        if fastPathDisplayLink == nil {
            startFastPathDisplayLink()
        }

        // NSWorkspace.didActivateApplicationNotification lands well after the
        // visual focus switch; this pid compare caps cross-app latency at one
        // slow-path period instead of the notification's lag.
        if let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier,
           frontmostPID != observedProcessID {
            attachToFrontmostApplication()
            refreshFocusContext()
            return
        }

        // Backstop for missed AX focus notifications (common when an app has
        // just launched and the observer attached before the focused window
        // existed). Retry the focus query so we self-heal within ~100 ms.
        if primaryWindowFrame == nil, observedApplicationElement != nil {
            refreshFocusContext()
        } else {
            verifyPrimaryWindowPresence()
            // Retry geometry matching only while the number is unresolved —
            // the case where _AXUIElementGetWindow failed for this element (or
            // is gone entirely). While the number is resolved, the 10 Hz full
            // window-list scan does not run.
            if primaryWindowNumber == nil {
                matchPrimaryWindowNumber()
            }
            publishUpdate()
        }
    }

    private func fastPathTick() {
        verifyPrimaryWindowPresence()
    }

    // A window absent from the on-screen list is closed, minimized, hidden or
    // on another Space — in every one of those the emphasis must come down.
    // The grace period is time-based (not frame-counted: refresh rates differ
    // per display) and keyed to the window number so a newly adopted window
    // gets a fresh budget.
    private func verifyPrimaryWindowPresence() {
        guard let windowNumber = primaryWindowNumber else { return }

        guard let observedBounds = fetchWindowBounds(windowNumber: windowNumber) else {
            let now = CACurrentMediaTime()
            guard let miss = boundsMiss, miss.windowNumber == windowNumber else {
                boundsMiss = (windowNumber, now)
                return
            }
            if now - miss.since >= Self.missedBoundsGrace {
                trackerLog.notice("window \(windowNumber) no longer resolves; treating as gone")
                resetPrimaryState()
                // Re-resolve before anything is published: if focus already
                // moved to another window this publishes that window, not an
                // intermediate nil.
                refreshFocusContext()
            }
            return
        }

        boundsMiss = nil
        guard primaryWindowFrame != observedBounds else { return }
        primaryWindowFrame = observedBounds
        publishUpdate()
    }

    private struct OnScreenWindowInfo {
        let bounds: CGRect
        let layer: Int
        let alpha: Double
    }

    private func fetchWindowBounds(windowNumber: Int) -> CGRect? {
        fetchOnScreenWindowInfo(windowNumber: windowNumber)?.bounds
    }

    // Returns nil for any window not on the current Space's on-screen list —
    // closed, minimized, hidden and other-Space windows are indistinguishable
    // here, and all of them must read as "no longer present".
    // No minimum-size floor: this call doubles as the liveness probe for the
    // tracked window, and a live window dragged very small must not read as
    // closed. The floor stays in windowSnapshots(), where it filters matcher
    // candidates.
    private func fetchOnScreenWindowInfo(windowNumber: Int) -> OnScreenWindowInfo? {
        guard let infoList = CGWindowListCopyWindowInfo(
            [.optionIncludingWindow],
            CGWindowID(windowNumber)
        ) as? [[String: Any]], let info = infoList.first else {
            return nil
        }

        guard let boundsDictionary = info[kCGWindowBounds as String] as? NSDictionary,
              let windowServerBounds = CGRect(dictionaryRepresentation: boundsDictionary),
              let cocoaBounds = convertFromWindowServerCoordinates(windowServerBounds) else {
            return nil
        }

        let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
        let alpha = (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1

        return OnScreenWindowInfo(bounds: cocoaBounds, layer: layer, alpha: alpha)
    }

    private func attachToFrontmostApplication() {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            tearDownAccessibilityObservation()
            resetPrimaryState()
            return
        }

        let processID = app.processIdentifier
        guard processID != observedProcessID else { return }

        tearDownAccessibilityObservation()
        resetPrimaryState()

        observedProcessID = processID
        observedApplicationElement = AXUIElementCreateApplication(processID)

        var observer: AXObserver?
        let result = AXObserverCreate(processID, axFocusChangeCallback, &observer)
        guard result == .success, let observer else {
            trackerLog.error("AXObserverCreate failed for pid \(processID, privacy: .public): \(String(describing: result), privacy: .public)")
            return
        }

        self.observer = observer
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        addApplicationNotification(kAXFocusedWindowChangedNotification as CFString)
        addApplicationNotification(kAXMainWindowChangedNotification as CFString)
        addApplicationNotification(kAXApplicationActivatedNotification as CFString)
        addApplicationNotification(kAXApplicationHiddenNotification as CFString)
    }

    private static let windowElementNotifications: [CFString] = [
        kAXWindowMovedNotification as CFString,
        kAXWindowResizedNotification as CFString,
        kAXUIElementDestroyedNotification as CFString,
        kAXWindowMiniaturizedNotification as CFString,
    ]

    private func tearDownAccessibilityObservation() {
        if let observer, let windowElement = observedWindowElement {
            for notification in Self.windowElementNotifications {
                AXObserverRemoveNotification(observer, windowElement, notification)
            }
        }

        if let observer, let applicationElement = observedApplicationElement {
            AXObserverRemoveNotification(observer, applicationElement, kAXFocusedWindowChangedNotification as CFString)
            AXObserverRemoveNotification(observer, applicationElement, kAXMainWindowChangedNotification as CFString)
            AXObserverRemoveNotification(observer, applicationElement, kAXApplicationActivatedNotification as CFString)
            AXObserverRemoveNotification(observer, applicationElement, kAXApplicationHiddenNotification as CFString)
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }

        observedWindowElement = nil
        observedApplicationElement = nil
        observer = nil
        observedProcessID = nil
    }

    private func addApplicationNotification(_ notification: CFString) {
        guard let observer, let applicationElement = observedApplicationElement else { return }
        let result = AXObserverAddNotification(
            observer,
            applicationElement,
            notification,
            Unmanaged.passUnretained(self).toOpaque()
        )
        if result != .success {
            trackerLog.notice("AXObserverAddNotification \(notification as String, privacy: .public) failed: \(String(describing: result), privacy: .public)")
        }
    }

    private func updateWindowObservationIfNeeded(with windowElement: AXUIElement) {
        guard let observer else {
            observedWindowElement = windowElement
            return
        }

        if let observedWindowElement, CFEqual(observedWindowElement, windowElement) {
            return
        }

        if let observedWindowElement {
            for notification in Self.windowElementNotifications {
                AXObserverRemoveNotification(observer, observedWindowElement, notification)
            }
        }

        observedWindowElement = windowElement

        for notification in Self.windowElementNotifications {
            let result = AXObserverAddNotification(
                observer,
                windowElement,
                notification,
                Unmanaged.passUnretained(self).toOpaque()
            )
            if result != .success {
                trackerLog.notice("AXObserverAddNotification \(notification as String, privacy: .public) failed: \(String(describing: result), privacy: .public)")
            }
        }
    }

    private func refreshFocusContext() {
        guard let applicationElement = observedApplicationElement, let processID = observedProcessID else {
            resetPrimaryState()
            updateStatus(nil)
            return
        }

        if processID == ProcessInfo.processInfo.processIdentifier {
            resetPrimaryState()
            updateStatus(nil)
            return
        }

        guard let focusedWindowElement = focusedWindowElement(from: applicationElement) else {
            resetPrimaryState()
            updateStatus("Active window unavailable.")
            return
        }

        updateWindowObservationIfNeeded(with: focusedWindowElement)

        guard let axFrame = axFrame(for: focusedWindowElement),
              let cocoaFrame = convertFromWindowServerCoordinates(axFrame) else {
            resetPrimaryState()
            updateStatus("Active window unavailable.")
            return
        }

        if let directWindowID = PrivateWindowServer.windowID(forAXElement: focusedWindowElement) {
            // AX is Space-agnostic: it keeps reporting a focused window that is
            // minimized, hidden or on another Space, and re-adopting one here
            // would livelock the window-gone teardown. Adopt only a window
            // that is actually on the current on-screen list, in the normal
            // layer and visible — the same filters the matcher path applies.
            if let info = fetchOnScreenWindowInfo(windowNumber: Int(directWindowID)),
               info.layer == 0,
               info.alpha > 0 {
                primaryWindowNumber = Int(directWindowID)
                primaryWindowFrame = info.bounds
            } else {
                resetPrimaryState()
            }
        } else {
            // Fallback when _AXUIElementGetWindow is unavailable: match the AX
            // frame against on-screen window snapshots by geometry.
            if let previousFrame = primaryWindowFrame, !previousFrame.nearlyEquals(cocoaFrame, tolerance: 4) {
                primaryWindowNumber = nil
            }
            primaryWindowFrame = cocoaFrame
            matchPrimaryWindowNumber()
        }
        updateStatus(nil)
    }

    private func matchPrimaryWindowNumber() {
        guard let processID = observedProcessID,
              processID != ProcessInfo.processInfo.processIdentifier,
              let referenceFrame = primaryWindowFrame else {
            return
        }

        let appSnapshots = windowSnapshots().filter { $0.ownerPID == processID }

        guard let primarySnapshot = bestMatchingPrimarySnapshot(from: appSnapshots, near: referenceFrame) else {
            return
        }

        primaryWindowNumber = primarySnapshot.windowNumber
        primaryWindowFrame = primarySnapshot.bounds
    }

    private func focusedWindowElement(from applicationElement: AXUIElement) -> AXUIElement? {
        if let focusedWindow: AXUIElement = copyAttributeValue(
            from: applicationElement,
            attribute: kAXFocusedWindowAttribute as CFString
        ) {
            return focusedWindow
        }

        return copyAttributeValue(from: applicationElement, attribute: kAXMainWindowAttribute as CFString)
    }

    private func axFrame(for windowElement: AXUIElement) -> CGRect? {
        guard let positionValue: AXValue = copyAttributeValue(from: windowElement, attribute: kAXPositionAttribute as CFString),
              let sizeValue: AXValue = copyAttributeValue(from: windowElement, attribute: kAXSizeAttribute as CFString) else {
            return nil
        }

        var position = CGPoint.zero
        var size = CGSize.zero

        guard AXValueGetValue(positionValue, .cgPoint, &position),
              AXValueGetValue(sizeValue, .cgSize, &size),
              size.width > 0,
              size.height > 0 else {
            return nil
        }

        return CGRect(origin: position, size: size)
    }

    private func convertFromWindowServerCoordinates(_ windowServerFrame: CGRect) -> CGRect? {
        guard let menuBarScreen = screen(for: CGMainDisplayID()) ?? NSScreen.screens.first else { return nil }

        return CGRect(
            x: menuBarScreen.frame.minX + windowServerFrame.minX,
            y: menuBarScreen.frame.maxY - windowServerFrame.minY - windowServerFrame.height,
            width: windowServerFrame.width,
            height: windowServerFrame.height
        )
    }

    private func windowSnapshots() -> [WindowSnapshot] {
        let excludedWindowNumbers = excludedWindowNumbersProvider?() ?? []

        guard let windowInfoList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return []
        }

        return windowInfoList.compactMap { info in
            guard let ownerPID = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  let windowNumber = (info[kCGWindowNumber as String] as? NSNumber)?.intValue,
                  !excludedWindowNumbers.contains(windowNumber),
                  let alpha = (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue,
                  alpha > 0,
                  let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue,
                  layer == 0,
                  let cocoaBounds = cocoaBounds(fromWindowInfo: info) else {
                return nil
            }

            return WindowSnapshot(
                windowNumber: windowNumber,
                ownerPID: ownerPID,
                bounds: cocoaBounds
            )
        }
    }

    private func cocoaBounds(fromWindowInfo info: [String: Any]) -> CGRect? {
        guard let boundsDictionary = info[kCGWindowBounds as String] as? NSDictionary,
              let windowServerBounds = CGRect(dictionaryRepresentation: boundsDictionary),
              let cocoaBounds = convertFromWindowServerCoordinates(windowServerBounds),
              cocoaBounds.width >= 4,
              cocoaBounds.height >= 4 else {
            return nil
        }

        return cocoaBounds
    }

    private func bestMatchingPrimarySnapshot(
        from snapshots: [WindowSnapshot],
        near referenceFrame: CGRect
    ) -> WindowSnapshot? {
        snapshots.max { lhs, rhs in
            matchScore(for: lhs.bounds, referenceFrame: referenceFrame)
                < matchScore(for: rhs.bounds, referenceFrame: referenceFrame)
        }
    }

    private func matchScore(for candidateFrame: CGRect, referenceFrame: CGRect) -> Double {
        let intersection = candidateFrame.intersection(referenceFrame)
        let overlapArea = intersection.isNull ? 0 : intersection.area
        let unionArea = candidateFrame.area + referenceFrame.area - overlapArea
        let overlapScore = unionArea > 0 ? overlapArea / unionArea : 0
        let centerDistance = hypot(candidateFrame.midX - referenceFrame.midX, candidateFrame.midY - referenceFrame.midY)

        return overlapScore * 1_000 - centerDistance
    }

    private func resetPrimaryState() {
        primaryWindowNumber = nil
        primaryWindowFrame = nil
        boundsMiss = nil
    }

    private func updateStatus(_ message: String?) {
        statusMessage = message
        publishUpdate()
    }

    private var lastPublishedPrimaryNumber: Int?
    private var lastPublishedPrimaryFrame: CGRect?
    private var lastPublishedStatus: String?

    private func publishUpdate() {
        if lastPublishedPrimaryNumber == primaryWindowNumber,
           lastPublishedPrimaryFrame == primaryWindowFrame,
           lastPublishedStatus == statusMessage {
            return
        }
        lastPublishedPrimaryNumber = primaryWindowNumber
        lastPublishedPrimaryFrame = primaryWindowFrame
        lastPublishedStatus = statusMessage
        onUpdate?(statusMessage)
    }

    private func screen(for displayID: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first { screen in
            guard let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
                return false
            }

            return CGDirectDisplayID(truncating: screenNumber) == displayID
        }
    }

    private func copyAttributeValue<T>(from element: AXUIElement, attribute: CFString) -> T? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard error == .success, let value else { return nil }
        return value as? T
    }
}

private let axFocusChangeCallback: AXObserverCallback = { _, _, _, refcon in
    guard let refcon else { return }
    let tracker = Unmanaged<ActiveWindowTracker>.fromOpaque(refcon).takeUnretainedValue()

    Task { @MainActor in
        tracker.refresh()
    }
}

private struct WindowSnapshot {
    let windowNumber: Int
    let ownerPID: pid_t
    let bounds: CGRect
}

private extension CGRect {
    var area: Double {
        guard !isNull, !isEmpty else { return 0 }
        return width * height
    }

    func nearlyEquals(_ other: CGRect, tolerance: CGFloat = 1) -> Bool {
        abs(minX - other.minX) <= tolerance &&
        abs(minY - other.minY) <= tolerance &&
        abs(width - other.width) <= tolerance &&
        abs(height - other.height) <= tolerance
    }
}
