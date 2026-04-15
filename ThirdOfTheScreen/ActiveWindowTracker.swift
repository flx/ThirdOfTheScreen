import AppKit
import ApplicationServices
import Foundation
import QuartzCore

struct WindowCutout: Equatable {
    let frame: CGRect
    let cornerRadius: CGFloat
}

@MainActor
final class ActiveWindowTracker: NSObject {
    private static let accessibilityAccessMessage =
        "Allow Accessibility access in System Settings > Privacy & Security > Accessibility. If it is already enabled, remove and re-add Third Of The Screen."
    private static let fastPathRefreshInterval = 1.0 / 120.0
    private static let slowPathRefreshInterval = 1.0 / 10.0
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

    var primaryWindowNumber: Int? { trackedPrimaryWindowNumber }
    var primaryWindowFrame: CGRect? { trackedPrimaryWindowFrame }

    private var workspaceObservers: [NSObjectProtocol] = []
    private var fastPathDisplayLink: CADisplayLink?
    private var fastPathFallbackTimer: Timer?
    private var slowPathTimer: Timer?
    private var observedProcessID: pid_t?
    private var observedApplicationElement: AXUIElement?
    private var observedWindowElement: AXUIElement?
    private var observer: AXObserver?
    private var trackedPrimaryWindowFrame: CGRect?
    private var trackedPrimaryWindowNumber: Int?
    private var cachedPrimaryCutout: WindowCutout?
    private var cachedAuxiliaryCutouts: [WindowCutout] = []
    private var cachedAuxiliaryWindows: [(windowNumber: Int, cornerRadius: CGFloat)] = []
    private var cachedTransientCutouts: [WindowCutout] = []
    private var cachedStatusMessage: String?

    func start(promptForAccess: Bool) -> Bool {
        guard isAccessibilityTrusted(prompt: promptForAccess) else {
            highlightedWindowCutouts = []
            trackedPrimaryWindowFrame = nil
            statusMessage = Self.accessibilityAccessMessage
            publishUpdate()
            return false
        }

        installWorkspaceObserversIfNeeded()
        startFastPathTimer()
        startSlowPathTimer()
        attachToFrontmostApplication()
        refreshFocusContext()
        return true
    }

    func stop() {
        removeWorkspaceObservers()
        stopFastPathTimer()
        stopSlowPathTimer()
        tearDownAccessibilityObservation()
        highlightedWindowCutouts = []
        trackedPrimaryWindowFrame = nil
        trackedPrimaryWindowNumber = nil
        cachedPrimaryCutout = nil
        cachedAuxiliaryCutouts = []
        cachedAuxiliaryWindows = []
        cachedTransientCutouts = []
        cachedStatusMessage = nil
        statusMessage = nil
        publishUpdate()
    }

    func refresh() {
        guard AXIsProcessTrusted() else {
            highlightedWindowCutouts = []
            trackedPrimaryWindowFrame = nil
            trackedPrimaryWindowNumber = nil
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

    private func startFastPathTimer() {
        // Drive the fast path from both a display-synced CADisplayLink *and* a 120 Hz
        // timer. The display link is ideal when it fires; the timer is a safety net in
        // case the vsync callback is missed (e.g. in some Space transitions). Duplicate
        // ticks are cheap because fastPathTick() bails when nothing has moved.
        if fastPathDisplayLink == nil, let screen = NSScreen.main ?? NSScreen.screens.first {
            let link = screen.displayLink(target: self, selector: #selector(handleDisplayLinkTick(_:)))
            link.add(to: .main, forMode: .common)
            fastPathDisplayLink = link
        }

        if fastPathFallbackTimer == nil {
            let timer = Timer(timeInterval: Self.fastPathRefreshInterval, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.fastPathTick()
                }
            }
            timer.tolerance = 0
            RunLoop.main.add(timer, forMode: .common)
            fastPathFallbackTimer = timer
        }
    }

    private func stopFastPathTimer() {
        fastPathDisplayLink?.invalidate()
        fastPathDisplayLink = nil
        fastPathFallbackTimer?.invalidate()
        fastPathFallbackTimer = nil
    }

    @objc private func handleDisplayLinkTick(_ sender: CADisplayLink) {
        fastPathTick()
    }

    private func startSlowPathTimer() {
        guard slowPathTimer == nil else { return }

        // Slow path: backstop for the AX-driven focus refresh. Runs the full snapshot +
        // transient-resolution pass at a low rate so focused/transient UI stays in sync
        // even if AX notifications are missed.
        let timer = Timer(timeInterval: Self.slowPathRefreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.slowPathTick()
            }
        }
        timer.tolerance = Self.slowPathRefreshInterval / 4
        RunLoop.main.add(timer, forMode: .common)
        slowPathTimer = timer
    }

    private func slowPathTick() {
        // If we have an AX observer attached to an app but no primary window
        // locked in yet, the AX focus notification probably fired before we
        // installed the observer (common when a brand-new app or window just
        // launched). Retry the focus query so we self-heal within ~100 ms
        // without the user needing to alt-tab away and back.
        if trackedPrimaryWindowFrame == nil, observedApplicationElement != nil {
            refreshFocusContext()
        } else {
            refreshTrackedWindowFrames()
        }
    }

    private func stopSlowPathTimer() {
        slowPathTimer?.invalidate()
        slowPathTimer = nil
    }

    private func fastPathTick() {
        guard let windowNumber = trackedPrimaryWindowNumber else { return }
        guard let observedBounds = fetchWindowBounds(windowNumber: windowNumber) else { return }

        let cornerRadius = cachedPrimaryCutout?.cornerRadius ?? Self.standardCornerRadius
        let updatedPrimary = WindowCutout(frame: observedBounds, cornerRadius: cornerRadius)

        let refreshedAuxiliary = cachedAuxiliaryWindows.compactMap { entry -> WindowCutout? in
            guard let auxBounds = fetchWindowBounds(windowNumber: entry.windowNumber) else { return nil }
            return WindowCutout(frame: auxBounds, cornerRadius: entry.cornerRadius)
        }

        let primaryUnchanged = cachedPrimaryCutout == updatedPrimary
        let auxiliaryUnchanged = refreshedAuxiliary == cachedAuxiliaryCutouts
        if primaryUnchanged && auxiliaryUnchanged { return }

        cachedPrimaryCutout = updatedPrimary
        cachedAuxiliaryCutouts = refreshedAuxiliary
        trackedPrimaryWindowFrame = observedBounds
        commitCachedCutouts()
    }

    private func fetchWindowBounds(windowNumber: Int) -> CGRect? {
        guard let infoList = CGWindowListCopyWindowInfo(
            [.optionIncludingWindow],
            CGWindowID(windowNumber)
        ) as? [[String: Any]],
            let info = infoList.first,
            let boundsDictionary = info[kCGWindowBounds as String] as? NSDictionary,
            let windowServerBounds = CGRect(dictionaryRepresentation: boundsDictionary),
            let cocoaBounds = convertFromWindowServerCoordinates(windowServerBounds),
            cocoaBounds.width >= 4,
            cocoaBounds.height >= 4
        else {
            return nil
        }

        return cocoaBounds
    }

    private func commitCachedCutouts() {
        var cutouts: [WindowCutout] = []
        if let cachedPrimaryCutout {
            cutouts.append(cachedPrimaryCutout)
        }
        cutouts.append(contentsOf: cachedAuxiliaryCutouts)
        cutouts.append(contentsOf: cachedTransientCutouts)
        updateState(cutouts: deduplicatedCutouts(cutouts), statusMessage: cachedStatusMessage)
    }

    private func attachToFrontmostApplication() {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            tearDownAccessibilityObservation()
            trackedPrimaryWindowFrame = nil
            trackedPrimaryWindowNumber = nil
            return
        }

        let processID = app.processIdentifier
        guard processID != observedProcessID else { return }

        tearDownAccessibilityObservation()
        trackedPrimaryWindowFrame = nil
        trackedPrimaryWindowNumber = nil

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
            trackedPrimaryWindowNumber = nil
            refreshTrackedWindowFrames()
            return
        }

        let ownProcessID = ProcessInfo.processInfo.processIdentifier
        if processID == ownProcessID {
            trackedPrimaryWindowFrame = nil
            trackedPrimaryWindowNumber = nil
            refreshTrackedWindowFrames(statusMessageWhenUnavailable: nil)
            return
        }

        guard let focusedWindowElement = focusedWindowElement(from: observedApplicationElement) else {
            trackedPrimaryWindowFrame = nil
            trackedPrimaryWindowNumber = nil
            refreshTrackedWindowFrames(statusMessageWhenUnavailable: "Active window unavailable.")
            return
        }

        updateWindowObservationIfNeeded(with: focusedWindowElement)

        guard let axFrame = axFrame(for: focusedWindowElement),
              let cocoaFrame = convertFromWindowServerCoordinates(axFrame) else {
            trackedPrimaryWindowFrame = nil
            trackedPrimaryWindowNumber = nil
            refreshTrackedWindowFrames(statusMessageWhenUnavailable: "Active window unavailable.")
            return
        }

        if let previousFrame = trackedPrimaryWindowFrame, !previousFrame.nearlyEquals(cocoaFrame, tolerance: 4) {
            trackedPrimaryWindowNumber = nil
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

        cachedTransientCutouts = transientCutouts

        guard let processID = observedProcessID else {
            trackedPrimaryWindowFrame = nil
            trackedPrimaryWindowNumber = nil
            cachedPrimaryCutout = nil
            cachedAuxiliaryCutouts = []
            cachedAuxiliaryWindows = []
            cachedStatusMessage = transientCutouts.isEmpty ? statusMessageWhenUnavailable : nil
            commitCachedCutouts()
            return
        }

        let ownProcessID = ProcessInfo.processInfo.processIdentifier
        if processID == ownProcessID {
            trackedPrimaryWindowFrame = nil
            trackedPrimaryWindowNumber = nil
            cachedPrimaryCutout = nil
            cachedAuxiliaryCutouts = []
            cachedAuxiliaryWindows = []
            cachedStatusMessage = transientCutouts.isEmpty ? statusMessageWhenUnavailable : nil
            commitCachedCutouts()
            return
        }

        guard let referenceFrame = trackedPrimaryWindowFrame else {
            cachedPrimaryCutout = nil
            cachedAuxiliaryCutouts = []
            cachedAuxiliaryWindows = []
            cachedStatusMessage = transientCutouts.isEmpty ? "Active window unavailable." : nil
            commitCachedCutouts()
            return
        }

        let appSnapshots = allWindowSnapshots.filter { $0.ownerPID == processID }

        let primarySnapshot = bestMatchingPrimarySnapshot(
            from: appSnapshots,
            near: referenceFrame
        )

        let primaryCutout: WindowCutout
        if let primarySnapshot {
            primaryCutout = WindowCutout(
                frame: primarySnapshot.bounds,
                cornerRadius: Self.cornerRadius(forLayer: primarySnapshot.layer)
            )
            trackedPrimaryWindowNumber = primarySnapshot.windowNumber
        } else {
            primaryCutout = WindowCutout(frame: referenceFrame, cornerRadius: Self.standardCornerRadius)
        }

        trackedPrimaryWindowFrame = primaryCutout.frame
        cachedPrimaryCutout = primaryCutout
        cachedAuxiliaryCutouts = auxiliaryCutouts(
            from: appSnapshots,
            excludingPrimaryFrame: primaryCutout.frame
        )
        cachedAuxiliaryWindows = auxiliaryWindows(
            from: appSnapshots,
            excludingPrimaryFrame: primaryCutout.frame
        )
        cachedStatusMessage = nil

        commitCachedCutouts()
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

    private func bestMatchingPrimarySnapshot(
        from snapshots: [WindowSnapshot],
        near referenceFrame: CGRect
    ) -> WindowSnapshot? {
        snapshots
            .filter { $0.layer == 0 }
            .max { lhs, rhs in
                matchScore(for: lhs.bounds, referenceFrame: referenceFrame)
                    < matchScore(for: rhs.bounds, referenceFrame: referenceFrame)
            }
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

    private func auxiliaryWindows(
        from snapshots: [WindowSnapshot],
        excludingPrimaryFrame primaryFrame: CGRect
    ) -> [(windowNumber: Int, cornerRadius: CGFloat)] {
        snapshots
            .filter { $0.layer > 0 }
            .filter { !$0.bounds.nearlyEquals(primaryFrame) }
            .map { ($0.windowNumber, Self.cornerRadius(forLayer: $0.layer)) }
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
