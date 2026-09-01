import ApplicationServices
import Darwin
import CoreGraphics

/// Thin wrappers around a handful of private SkyLight / CoreGraphics Services
/// symbols. These are undocumented and resolved at runtime via `dlsym`, so a
/// future macOS release that renames or removes them will fall back to
/// `nil`/failure values instead of crashing at launch.
enum PrivateWindowServer {
    typealias ConnectionID = Int32
    typealias WindowID = CGWindowID

    private typealias MainConnectionIDFn = @convention(c) () -> ConnectionID
    private typealias SetWindowParentFn = @convention(c) (ConnectionID, WindowID, WindowID) -> Int32
    private typealias OrderWindowFn = @convention(c) (ConnectionID, WindowID, Int32, WindowID) -> Int32
    private typealias AXUIElementGetWindowFn = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError

    enum WindowOrder: Int32 {
        case below = -1
        case out = 0
        case above = 1
    }

    private static let mainConnectionIDFn: MainConnectionIDFn? = {
        resolve("SLSMainConnectionID") ?? resolve("CGSMainConnectionID")
    }()

    private static let setWindowParentFn: SetWindowParentFn? = {
        resolve("SLSSetWindowParent") ?? resolve("CGSSetWindowParent")
    }()

    private static let orderWindowFn: OrderWindowFn? = {
        resolve("SLSOrderWindow") ?? resolve("CGSOrderWindow")
    }()

    private static let axUIElementGetWindowFn: AXUIElementGetWindowFn? = {
        resolve("_AXUIElementGetWindow")
    }()

    static var isAvailable: Bool {
        mainConnectionIDFn != nil && setWindowParentFn != nil
    }

    static func mainConnectionID() -> ConnectionID? {
        mainConnectionIDFn.map { $0() }
    }

    @discardableResult
    static func setWindowParent(child: WindowID, parent: WindowID) -> Bool {
        guard let connection = mainConnectionID(), let call = setWindowParentFn else {
            return false
        }
        let result = call(connection, child, parent)
        return result == 0
    }

    @discardableResult
    static func clearWindowParent(child: WindowID) -> Bool {
        // Passing parent=0 detaches the child from any parent.
        setWindowParent(child: child, parent: 0)
    }

    /// The window ID behind an Accessibility window element, via the private
    /// HIServices symbol `_AXUIElementGetWindow`. nil when the symbol is gone
    /// (fall back to geometry matching) or the element no longer has a window.
    static func windowID(forAXElement element: AXUIElement) -> WindowID? {
        guard let call = axUIElementGetWindowFn else { return nil }
        var windowID: CGWindowID = 0
        guard call(element, &windowID) == .success, windowID != 0 else { return nil }
        return windowID
    }

    @discardableResult
    static func orderWindow(window: WindowID, order: WindowOrder, relativeTo: WindowID) -> Bool {
        guard let connection = mainConnectionID(), let call = orderWindowFn else {
            return false
        }
        let result = call(connection, window, order.rawValue, relativeTo)
        return result == 0
    }

    private static func resolve<T>(_ symbol: String) -> T? {
        guard let pointer = dlsym(UnsafeMutableRawPointer(bitPattern: -2), symbol) else {
            return nil
        }
        return unsafeBitCast(pointer, to: T.self)
    }
}
