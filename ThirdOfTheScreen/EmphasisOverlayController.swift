import AppKit
import OSLog

private let emphasisLog = Logger(subsystem: "com.felix.thirdofthescreen", category: "Emphasis")

@MainActor
final class EmphasisOverlayController {
    private static let motionMargin: CGFloat = 500
    private static let maxPanelDimension: CGFloat = 7500
    private static let cornerRadius: CGFloat = {
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26 ? 16 : 10
    }()

    private var panel: EmphasisPanel?
    private var tintColor: NSColor = NSColor(red: 0.07, green: 0.08, blue: 0.10, alpha: 1)
    private var tintOpacity: CGFloat = 0.36
    private var parentedWindowID: PrivateWindowServer.WindowID?

    var excludedWindowNumbers: Set<Int> {
        guard let panel else { return [] }
        return [panel.windowNumber]
    }

    var isAvailable: Bool { PrivateWindowServer.isAvailable }

    func setAppearance(color: NSColor, opacity: CGFloat) {
        tintColor = color
        tintOpacity = opacity
        panel?.applyTint(color: color, opacity: opacity)
    }

    func setActiveWindow(windowID: PrivateWindowServer.WindowID, cocoaBounds: CGRect) {
        let panel = ensurePanel()
        let (panelFrame, cutout) = panelGeometry(for: cocoaBounds)

        panel.setFrame(panelFrame, display: false)
        panel.applyCutout(
            panelBounds: CGRect(origin: .zero, size: panelFrame.size),
            cutout: cutout,
            radius: Self.cornerRadius
        )

        if !panel.isVisible {
            panel.orderFrontRegardless()
        }

        let childID = CGWindowID(panel.windowNumber)
        if parentedWindowID != windowID {
            let parentOK = PrivateWindowServer.setWindowParent(child: childID, parent: windowID)
            let orderOK = PrivateWindowServer.orderWindow(window: childID, order: .above, relativeTo: windowID)
            emphasisLog.notice("reparent child=\(panel.windowNumber) parent=\(windowID) parentOK=\(parentOK) orderOK=\(orderOK) (was parent=\(self.parentedWindowID ?? 0))")
            parentedWindowID = windowID
        } else {
            // Even when parent hasn't changed, keep our z-order pinned above it — the
            // parent may have been raised by a user click which could have pushed us
            // below sibling windows.
            let orderOK = PrivateWindowServer.orderWindow(window: childID, order: .above, relativeTo: windowID)
            if !orderOK {
                emphasisLog.notice("orderWindow pin-above failed for child=\(panel.windowNumber) parent=\(windowID)")
            }
        }
    }

    func clear() {
        guard let panel else { return }
        emphasisLog.notice("clear() tearing down parenting (was parent=\(self.parentedWindowID ?? 0))")
        let ok = PrivateWindowServer.clearWindowParent(child: CGWindowID(panel.windowNumber))
        if !ok {
            emphasisLog.notice("clearWindowParent failed for child=\(panel.windowNumber)")
        }
        panel.orderOut(nil)
        parentedWindowID = nil
    }

    private func panelGeometry(for cocoaBounds: CGRect) -> (panelFrame: CGRect, cutout: CGRect) {
        // Max-intersection, matching the tracker's screen pick — first-match
        // could dim around the sliver screen of a straddling window and leave
        // most of its real screen undimmed.
        let bestScreen = NSScreen.screens
            .max(by: { $0.frame.intersectionArea(with: cocoaBounds) < $1.frame.intersectionArea(with: cocoaBounds) })
            .flatMap { $0.frame.intersects(cocoaBounds) ? $0 : nil }
        let screenFrame = (bestScreen ?? NSScreen.main)?.frame
        if screenFrame == nil {
            emphasisLog.notice("no screen intersects active window bounds \(String(describing: cocoaBounds), privacy: .public); falling back to default screen size")
        }
        let referenceFrame = screenFrame ?? CGRect(x: 0, y: 0, width: 3840, height: 2160)

        let margin = Self.motionMargin
        let maxD = Self.maxPanelDimension

        let panelFrame = CGRect(
            x: referenceFrame.minX - margin,
            y: referenceFrame.minY - margin,
            width: min(referenceFrame.width + 2 * margin, maxD),
            height: min(referenceFrame.height + 2 * margin, maxD)
        )

        // Cutout in the panel's flipped (top-left origin) local coordinate space.
        let cutout = CGRect(
            x: cocoaBounds.minX - panelFrame.minX,
            y: panelFrame.maxY - cocoaBounds.maxY,
            width: cocoaBounds.width,
            height: cocoaBounds.height
        )

        return (panelFrame, cutout)
    }

    private func ensurePanel() -> EmphasisPanel {
        if let panel { return panel }
        let panel = EmphasisPanel(tint: tintColor.withAlphaComponent(tintOpacity))
        self.panel = panel
        return panel
    }
}

private extension CGRect {
    func intersectionArea(with other: CGRect) -> CGFloat {
        let intersection = intersection(other)
        guard !intersection.isNull, !intersection.isEmpty else { return 0 }
        return intersection.width * intersection.height
    }
}

private final class EmphasisPanel: NSWindow {
    private let emphasisView: EmphasisContentView

    init(tint: NSColor) {
        emphasisView = EmphasisContentView(tint: tint)
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        ignoresMouseEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        hidesOnDeactivate = false
        // .floating sits above every .normal window. The cutout in our mask lets the
        // active window show through, and ignoresMouseEvents=true lets clicks pass
        // through the rest. Parenting still handles motion tracking during drags.
        level = .floating
        isReleasedWhenClosed = false
        contentView = emphasisView
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        // Bypass AppKit's keep-on-screen clamp so large screen-plus-margin rects
        // aren't silently snapped down.
        return frameRect
    }

    func applyTint(color: NSColor, opacity: CGFloat) {
        emphasisView.applyTint(color: color, opacity: opacity)
    }

    func applyCutout(panelBounds: CGRect, cutout: CGRect, radius: CGFloat) {
        emphasisView.applyCutout(panelBounds: panelBounds, cutout: cutout, radius: radius)
    }
}

private final class EmphasisContentView: NSView {
    private let dimLayer = CALayer()
    private let maskLayer = CAShapeLayer()

    init(tint: NSColor) {
        super.init(frame: .zero)
        wantsLayer = true
        layer = CALayer()

        CATransaction.begin()
        CATransaction.setDisableActions(true)

        dimLayer.backgroundColor = tint.cgColor
        dimLayer.mask = maskLayer
        layer?.addSublayer(dimLayer)

        maskLayer.fillRule = .evenOdd
        maskLayer.fillColor = NSColor.black.cgColor

        CATransaction.commit()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dimLayer.frame = bounds
        maskLayer.frame = bounds
        CATransaction.commit()
    }

    func applyTint(color: NSColor, opacity: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dimLayer.backgroundColor = color.withAlphaComponent(opacity).cgColor
        CATransaction.commit()
    }

    func applyCutout(panelBounds: CGRect, cutout: CGRect, radius: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dimLayer.frame = panelBounds
        maskLayer.frame = panelBounds
        let path = CGMutablePath()
        path.addRect(panelBounds)
        path.addPath(CGPath(roundedRect: cutout, cornerWidth: radius, cornerHeight: radius, transform: nil))
        maskLayer.path = path
        CATransaction.commit()
    }
}
