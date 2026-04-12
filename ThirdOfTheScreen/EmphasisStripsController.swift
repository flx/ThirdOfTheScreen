import AppKit
import OSLog

private let emphasisLog = Logger(subsystem: "com.felix.thirdofthescreen", category: "Emphasis")

@MainActor
final class EmphasisStripsController {
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

        let screenFrame = (NSScreen.screens.first(where: { $0.frame.intersects(cocoaBounds) })
                           ?? NSScreen.main)?.frame
            ?? CGRect(x: 0, y: 0, width: 3840, height: 2160)

        let margin = Self.motionMargin
        let maxD = Self.maxPanelDimension

        let panelFrame = CGRect(
            x: screenFrame.minX - margin,
            y: screenFrame.minY - margin,
            width: min(screenFrame.width + 2 * margin, maxD),
            height: min(screenFrame.height + 2 * margin, maxD)
        )

        // Cutout expressed in the panel's flipped (top-left origin) local
        // coordinate space.
        let cutout = CGRect(
            x: cocoaBounds.minX - panelFrame.minX,
            y: panelFrame.maxY - cocoaBounds.maxY,
            width: cocoaBounds.width,
            height: cocoaBounds.height
        )

        panel.setFrame(panelFrame, display: false)
        panel.applyCutout(
            panelBounds: CGRect(origin: .zero, size: panelFrame.size),
            cutout: cutout,
            radius: Self.cornerRadius
        )

        if !panel.isVisible {
            panel.orderFrontRegardless()
        }

        if parentedWindowID != windowID {
            let childID = CGWindowID(panel.windowNumber)
            let okParent = PrivateWindowServer.setWindowParent(child: childID, parent: windowID)
            let okOrder = PrivateWindowServer.orderWindow(window: childID, order: .above, relativeTo: windowID)
            emphasisLog.notice("reparent child=\(panel.windowNumber) parent=\(windowID) parentOK=\(okParent) orderOK=\(okOrder) (was parent=\(self.parentedWindowID ?? 0))")
            parentedWindowID = windowID
        } else {
            // Even when parent hasn't changed, keep our z-order pinned above it — the
            // parent may have been raised by a user click which could have pushed us
            // below sibling windows.
            PrivateWindowServer.orderWindow(
                window: CGWindowID(panel.windowNumber),
                order: .above,
                relativeTo: windowID
            )
        }
    }

    func clear() {
        guard let panel else { return }
        emphasisLog.notice("clear() called, tearing down parenting (was parent=\(self.parentedWindowID ?? 0))")
        PrivateWindowServer.clearWindowParent(child: CGWindowID(panel.windowNumber))
        panel.orderOut(nil)
        parentedWindowID = nil
    }

    private func ensurePanel() -> EmphasisPanel {
        if let panel { return panel }
        let panel = EmphasisPanel(tint: tintColor.withAlphaComponent(tintOpacity))
        self.panel = panel
        return panel
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
        // .floating sits above every .normal window (other apps' windows, the
        // active window itself). The cutout in our mask lets the active window
        // show through, and ignoresMouseEvents=true lets clicks pass through
        // the rest. Parenting still handles motion tracking during drags.
        level = .floating
        isReleasedWhenClosed = false
        contentView = emphasisView
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        // Bypass AppKit's keep-on-screen clamp so large screen-plus-margin
        // rects aren't silently snapped down.
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
