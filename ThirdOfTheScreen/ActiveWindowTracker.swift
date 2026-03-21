import AppKit
import ApplicationServices
import Foundation

struct WindowCutout: Equatable {
    let frame: CGRect
    let cornerRadius: CGFloat
}

@MainActor
final class ActiveWindowTracker {
    private static let accessibilityAccessMessage =
        "Allow Accessibility access in System Settings > Privacy & Security > Accessibility. If it is already enabled, remove and re-add Third Of The Screen."
    private static let fallbackRefreshInterval = 1.0 / 60.0
    private static let menuBarAttachmentTolerance: CGFloat = 48
    private static let focusedElementSearchDepth = 16
    private static let preferredTransientRoles: Set<String> = [
        kAXMenuRole as String,
        "AXPopover",
        kAXSheetRole as String,
        "AXDialog",
        kAXWindowRole as String
    ]

    private static let standardCornerRadius: CGFloat = {
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26 ? 16 : 10
    }()

    private static let panelCornerRadius: CGFloat = {
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26 ? 15 : 10
    }()

    var onUpdate: (([WindowCutout], String?) -> Void)?
    var excludedWindowNumbersProvider: (() -> Set<Int>)?

    private(set) var highlightedWindowCutouts: [WindowCutout] = []
    private(set) var statusMessage: String?

    private var workspaceObservers: [NSObjectProtocol] = []
    private var fallbackTimer: Timer?
    private var observedProcessID: pid_t?
    private var observedApplicationElement: AXUIElement?
    private var observedWindowElement: AXUIElement?
    private var observer: AXObserver?
    private var trackedPrimaryWindowFrame: CGRect?

    func start(promptForAccess: Bool) -> Bool {
        guard isAccessibilityTrusted(prompt: promptForAccess) else {
            highlightedWindowCutouts = []
            trackedPrimaryWindowFrame = nil
            statusMessage = Self.accessibilityAccessMessage
            publishUpdate()
            return false
        }

        installWorkspaceObserversIfNeeded()
        startFallbackTimer()
        attachToFrontmostApplication()
        refreshFocusContext()
        return true
    }

    func stop() {
        removeWorkspaceObservers()
        stopFallbackTimer()
        tearDownAccessibilityObservation()
        highlightedWindowCutouts = []
        trackedPrimaryWindowFrame = nil
        statusMessage = nil
        publishUpdate()
    }

    func refresh() {
        guard AXIsProcessTrusted() else {
            highlightedWindowCutouts = []
            trackedPrimaryWindowFrame = nil
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

    private func startFallbackTimer() {
        guard fallbackTimer == nil else { return }

        // Run in common modes so refreshes continue while the user is actively dragging a window.
        let timer = Timer(timeInterval: Self.fallbackRefreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshTrackedWindowFrames()
            }
        }
        timer.tolerance = 0.005
        RunLoop.main.add(timer, forMode: .common)
        fallbackTimer = timer
    }

    private func stopFallbackTimer() {
        fallbackTimer?.invalidate()
        fallbackTimer = nil
    }

    private func attachToFrontmostApplication() {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            tearDownAccessibilityObservation()
            trackedPrimaryWindowFrame = nil
            return
        }

        let processID = app.processIdentifier
        guard processID != observedProcessID else { return }

        tearDownAccessibilityObservation()
        trackedPrimaryWindowFrame = nil

        observedProcessID = processID
        observedApplicationElement = AXUIElementCreateApplication(processID)

        var observer: AXObserver?
        let result = AXObserverCreate(processID, activeWindowObserverCallback, &observer)
        if result == .success, let observer {
            self.observer = observer
            CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
            addApplicationNotification(kAXFocusedWindowChangedNotification as CFString)
            addApplicationNotification(kAXMainWindowChangedNotification as CFString)
            addApplicationNotification(kAXApplicationActivatedNotification as CFString)
        }
    }

    private func tearDownAccessibilityObservation() {
        if let observer, let windowElement = observedWindowElement {
            AXObserverRemoveNotification(observer, windowElement, kAXWindowMovedNotification as CFString)
            AXObserverRemoveNotification(observer, windowElement, kAXWindowResizedNotification as CFString)
        }

        if let observer, let applicationElement = observedApplicationElement {
            AXObserverRemoveNotification(observer, applicationElement, kAXFocusedWindowChangedNotification as CFString)
            AXObserverRemoveNotification(observer, applicationElement, kAXMainWindowChangedNotification as CFString)
            AXObserverRemoveNotification(observer, applicationElement, kAXApplicationActivatedNotification as CFString)
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }

        observedWindowElement = nil
        observedApplicationElement = nil
        observer = nil
        observedProcessID = nil
    }

    private func addApplicationNotification(_ notification: CFString) {
        guard let observer, let applicationElement = observedApplicationElement else { return }
        _ = AXObserverAddNotification(
            observer,
            applicationElement,
            notification,
            Unmanaged.passUnretained(self).toOpaque()
        )
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
            AXObserverRemoveNotification(observer, observedWindowElement, kAXWindowMovedNotification as CFString)
            AXObserverRemoveNotification(observer, observedWindowElement, kAXWindowResizedNotification as CFString)
        }

        observedWindowElement = windowElement

        _ = AXObserverAddNotification(
            observer,
            windowElement,
            kAXWindowMovedNotification as CFString,
            Unmanaged.passUnretained(self).toOpaque()
        )
        _ = AXObserverAddNotification(
            observer,
            windowElement,
            kAXWindowResizedNotification as CFString,
            Unmanaged.passUnretained(self).toOpaque()
        )
    }

    private func refreshFocusContext() {
        guard let observedApplicationElement, let processID = observedProcessID else {
            trackedPrimaryWindowFrame = nil
            refreshTrackedWindowFrames()
            return
        }

        let ownProcessID = ProcessInfo.processInfo.processIdentifier
        if processID == ownProcessID {
            trackedPrimaryWindowFrame = nil
            refreshTrackedWindowFrames(statusMessageWhenUnavailable: nil)
            return
        }

        guard let focusedWindowElement = focusedWindowElement(from: observedApplicationElement) else {
            trackedPrimaryWindowFrame = nil
            refreshTrackedWindowFrames(statusMessageWhenUnavailable: "Active window unavailable.")
            return
        }

        updateWindowObservationIfNeeded(with: focusedWindowElement)

        guard let axFrame = axFrame(for: focusedWindowElement),
              let cocoaFrame = convertFromWindowServerCoordinates(axFrame) else {
            trackedPrimaryWindowFrame = nil
            refreshTrackedWindowFrames(statusMessageWhenUnavailable: "Active window unavailable.")
            return
        }

        trackedPrimaryWindowFrame = cocoaFrame
        refreshTrackedWindowFrames()
    }

    private func refreshTrackedWindowFrames(statusMessageWhenUnavailable: String? = nil) {
        let allWindowSnapshots = windowSnapshots()
        let focusedTransientCutouts = focusedTransientCutouts(from: allWindowSnapshots)
        let transientCutouts = focusedTransientCutouts.isEmpty
            ? menuBarTransientCutouts(from: allWindowSnapshots)
            : focusedTransientCutouts

        guard let processID = observedProcessID else {
            trackedPrimaryWindowFrame = nil
            updateState(
                cutouts: deduplicatedCutouts(transientCutouts),
                statusMessage: transientCutouts.isEmpty ? statusMessageWhenUnavailable : nil
            )
            return
        }

        let ownProcessID = ProcessInfo.processInfo.processIdentifier
        if processID == ownProcessID {
            trackedPrimaryWindowFrame = nil
            updateState(
                cutouts: deduplicatedCutouts(transientCutouts),
                statusMessage: transientCutouts.isEmpty ? statusMessageWhenUnavailable : nil
            )
            return
        }

        guard let trackedPrimaryWindowFrame else {
            updateState(
                cutouts: deduplicatedCutouts(transientCutouts),
                statusMessage: transientCutouts.isEmpty ? "Active window unavailable." : nil
            )
            return
        }

        let appSnapshots = allWindowSnapshots.filter { $0.ownerPID == processID }

        let primaryCutout = bestMatchingPrimaryCutout(
            from: appSnapshots,
            near: trackedPrimaryWindowFrame
        ) ?? WindowCutout(frame: trackedPrimaryWindowFrame, cornerRadius: Self.standardCornerRadius)

        self.trackedPrimaryWindowFrame = primaryCutout.frame

        let auxiliaryCutouts = auxiliaryCutouts(
            from: appSnapshots,
            excludingPrimaryFrame: primaryCutout.frame
        )

        updateState(
            cutouts: deduplicatedCutouts([primaryCutout] + auxiliaryCutouts + transientCutouts),
            statusMessage: nil
        )
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
                  let boundsDictionary = info[kCGWindowBounds as String] as? NSDictionary,
                  let windowServerBounds = CGRect(dictionaryRepresentation: boundsDictionary),
                  let cocoaBounds = convertFromWindowServerCoordinates(windowServerBounds),
                  cocoaBounds.width >= 4,
                  cocoaBounds.height >= 4 else {
                return nil
            }

            return WindowSnapshot(
                windowNumber: windowNumber,
                ownerPID: ownerPID,
                bounds: cocoaBounds,
                layer: layer
            )
        }
    }

    private func menuBarTransientCutouts(from snapshots: [WindowSnapshot]) -> [WindowCutout] {
        let candidates = snapshots
            .filter { $0.layer > 0 }
            .filter { isMenuBarTransientFrame($0.bounds) }

        let survivingFrames = candidates.map(\.bounds).removingContainerFrames()

        return candidates
            .filter { snapshot in survivingFrames.contains { $0.nearlyEquals(snapshot.bounds) } }
            .map { WindowCutout(frame: $0.bounds, cornerRadius: Self.cornerRadius(forLayer: $0.layer)) }
    }

    private func isMenuBarTransientFrame(_ frame: CGRect) -> Bool {
        guard frame.width >= 40,
              frame.height >= 40,
              let screen = bestMatchingScreen(for: frame) else {
            return false
        }

        let visibleFrame = screen.visibleFrame
        let topDistance = abs(frame.maxY - visibleFrame.maxY)

        return topDistance <= Self.menuBarAttachmentTolerance &&
            frame.width <= visibleFrame.width * 0.9 &&
            frame.height <= visibleFrame.height * 0.95
    }

    private func focusedTransientCutouts(from snapshots: [WindowSnapshot]) -> [WindowCutout] {
        let systemWideElement = AXUIElementCreateSystemWide()

        guard let focusedElement: AXUIElement = copyAttributeValue(
            from: systemWideElement,
            attribute: kAXFocusedUIElementAttribute as CFString
        ) else {
            return []
        }

        var collectedCandidates: [AXFrameCandidate] = []

        if let windowElement: AXUIElement = copyAttributeValue(from: focusedElement, attribute: kAXWindowAttribute as CFString),
           let candidate = frameCandidate(for: windowElement) {
            collectedCandidates.append(candidate)
        }

        var currentElement: AXUIElement? = focusedElement
        var inspectedElements: [AXUIElement] = []
        var depth = 0

        while depth < Self.focusedElementSearchDepth, let element = currentElement {
            if inspectedElements.contains(where: { CFEqual($0, element) }) {
                break
            }

            inspectedElements.append(element)

            if let candidate = frameCandidate(for: element) {
                collectedCandidates.append(candidate)
            }

            let parentElement: AXUIElement? = copyAttributeValue(from: element, attribute: kAXParentAttribute as CFString)
            currentElement = parentElement
            depth += 1
        }

        let filteredCandidates = normalizedTransientCandidates(collectedCandidates)

        let prioritizedCandidates = filteredCandidates.sorted { lhs, rhs in
            let lhsPriority = transientRolePriority(for: lhs.role)
            let rhsPriority = transientRolePriority(for: rhs.role)

            if lhsPriority != rhsPriority {
                return lhsPriority < rhsPriority
            }

            return lhs.frame.area < rhs.frame.area
        }

        if let preferredCandidate = prioritizedCandidates.first(where: { candidate in
            guard let role = candidate.role else { return false }
            return Self.preferredTransientRoles.contains(role)
        }) {
            let frame = refinedTransientFrame(for: preferredCandidate.frame, using: snapshots)
            return [WindowCutout(frame: frame, cornerRadius: Self.panelCornerRadius)]
        }

        if let bestCandidate = prioritizedCandidates.first {
            let frame = refinedTransientFrame(for: bestCandidate.frame, using: snapshots)
            return [WindowCutout(frame: frame, cornerRadius: Self.panelCornerRadius)]
        }

        return []
    }

    private func frameCandidate(for element: AXUIElement) -> AXFrameCandidate? {
        guard let axFrame = axFrame(for: element),
              let cocoaFrame = convertFromWindowServerCoordinates(axFrame),
              cocoaFrame.width >= 40,
              cocoaFrame.height >= 40 else {
            return nil
        }

        let role: String? = copyAttributeValue(from: element, attribute: kAXRoleAttribute as CFString)
        return AXFrameCandidate(frame: cocoaFrame, role: role)
    }

    private func isReasonableTransientCandidateFrame(_ frame: CGRect) -> Bool {
        guard let screen = bestMatchingScreen(for: frame) else { return false }

        let visibleFrame = screen.visibleFrame
        let relativeArea = frame.area / visibleFrame.area

        return frame.width <= visibleFrame.width * 0.9 &&
            frame.height <= visibleFrame.height * 0.95 &&
            relativeArea <= 0.45
    }

    private func normalizedTransientCandidates(_ candidates: [AXFrameCandidate]) -> [AXFrameCandidate] {
        var deduplicatedCandidates: [AXFrameCandidate] = []

        for candidate in candidates where isReasonableTransientCandidateFrame(candidate.frame) {
            if let existingIndex = deduplicatedCandidates.firstIndex(where: {
                $0.frame.nearlyEquals(candidate.frame, tolerance: 4)
            }) {
                if transientRolePriority(for: candidate.role) < transientRolePriority(for: deduplicatedCandidates[existingIndex].role) {
                    deduplicatedCandidates[existingIndex] = candidate
                }
                continue
            }

            deduplicatedCandidates.append(candidate)
        }

        return deduplicatedCandidates.filter { candidate in
            !deduplicatedCandidates.contains { other in
                guard candidate.frame != other.frame else { return false }
                return candidate.frame.contains(other.frame.insetBy(dx: -12, dy: -12)) &&
                    candidate.frame.area > other.frame.area * 1.35
            }
        }
    }

    private func transientRolePriority(for role: String?) -> Int {
        switch role {
        case kAXMenuRole as String, "AXPopover":
            return 0
        case kAXSheetRole as String, "AXDialog":
            return 1
        case kAXWindowRole as String:
            return 2
        default:
            return 3
        }
    }

    private func refinedTransientFrame(for candidateFrame: CGRect, using snapshots: [WindowSnapshot]) -> CGRect {
        let center = CGPoint(x: candidateFrame.midX, y: candidateFrame.midY)

        let matchingSnapshots = snapshots
            .filter { $0.layer > 0 }
            .map(\.bounds)
            .filter { isReasonableTransientCandidateFrame($0) }
            .filter { !$0.intersection(candidateFrame).isNull }
            .filter { $0.insetBy(dx: -10, dy: -10).contains(center) }
            .filter { $0.area <= candidateFrame.area * 1.05 }

        guard let bestSnapshot = matchingSnapshots.min(by: { lhs, rhs in
            if abs(lhs.area - rhs.area) > 1 {
                return lhs.area < rhs.area
            }

            let lhsDistance = hypot(lhs.midX - center.x, lhs.midY - center.y)
            let rhsDistance = hypot(rhs.midX - center.x, rhs.midY - center.y)
            return lhsDistance < rhsDistance
        }) else {
            return candidateFrame
        }

        return bestSnapshot
    }

    private func bestMatchingPrimaryCutout(
        from snapshots: [WindowSnapshot],
        near referenceFrame: CGRect
    ) -> WindowCutout? {
        guard let best = snapshots
            .filter({ $0.layer == 0 })
            .max(by: { lhs, rhs in
                matchScore(for: lhs.bounds, referenceFrame: referenceFrame)
                    < matchScore(for: rhs.bounds, referenceFrame: referenceFrame)
            }) else {
            return nil
        }

        return WindowCutout(frame: best.bounds, cornerRadius: Self.cornerRadius(forLayer: best.layer))
    }

    private func auxiliaryCutouts(
        from snapshots: [WindowSnapshot],
        excludingPrimaryFrame primaryFrame: CGRect
    ) -> [WindowCutout] {
        snapshots
            .filter { $0.layer > 0 }
            .filter { !$0.bounds.nearlyEquals(primaryFrame) }
            .map { WindowCutout(frame: $0.bounds, cornerRadius: Self.cornerRadius(forLayer: $0.layer)) }
    }

    private static func cornerRadius(forLayer layer: Int) -> CGFloat {
        layer == 0 ? standardCornerRadius : panelCornerRadius
    }

    private func matchScore(for candidateFrame: CGRect, referenceFrame: CGRect) -> Double {
        let intersection = candidateFrame.intersection(referenceFrame)
        let overlapArea = intersection.isNull ? 0 : intersection.area
        let unionArea = candidateFrame.area + referenceFrame.area - overlapArea
        let overlapScore = unionArea > 0 ? overlapArea / unionArea : 0
        let centerDistance = hypot(candidateFrame.midX - referenceFrame.midX, candidateFrame.midY - referenceFrame.midY)

        return overlapScore * 1_000 - centerDistance
    }

    private func deduplicatedCutouts(_ cutouts: [WindowCutout]) -> [WindowCutout] {
        var deduplicated: [WindowCutout] = []

        for cutout in cutouts {
            guard !deduplicated.contains(where: { $0.frame.nearlyEquals(cutout.frame) }) else { continue }
            deduplicated.append(cutout)
        }

        return deduplicated
    }

    private func bestMatchingScreen(for frame: CGRect) -> NSScreen? {
        NSScreen.screens.max { lhs, rhs in
            let lhsArea = lhs.visibleFrame.intersection(frame).area
            let rhsArea = rhs.visibleFrame.intersection(frame).area
            return lhsArea < rhsArea
        }
    }

    private func updateState(cutouts: [WindowCutout], statusMessage: String?) {
        guard highlightedWindowCutouts != cutouts || self.statusMessage != statusMessage else { return }
        highlightedWindowCutouts = cutouts
        self.statusMessage = statusMessage
        publishUpdate()
    }

    private func publishUpdate() {
        onUpdate?(highlightedWindowCutouts, statusMessage)
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

private let activeWindowObserverCallback: AXObserverCallback = { _, _, _, refcon in
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
    let layer: Int
}

private struct AXFrameCandidate {
    let frame: CGRect
    let role: String?
}

private extension Array where Element == CGRect {
    func removingContainerFrames() -> [CGRect] {
        filter { candidate in
            !contains { other in
                guard candidate != other,
                      candidate.area > other.area * 1.01 else {
                    return false
                }
                let expandedCandidate = candidate.insetBy(dx: -4, dy: -4)
                return expandedCandidate.contains(other)
            }
        }
    }
}

private extension Array {
    func ifEmpty(_ fallback: @autoclosure () -> [Element]) -> [Element] {
        isEmpty ? fallback() : self
    }
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
