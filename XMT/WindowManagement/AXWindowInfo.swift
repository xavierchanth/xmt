import AppKit
import ApplicationServices

// kAXFullScreenAttribute is an informal attribute not defined as a constant in headers.
private let kAXFullScreen = "AXFullScreen"

/// A wrapper around AXUIElement providing typed access to window attributes.
/// Using a class (reference type) so mutating methods work naturally.
final class AXWindowInfo {
    let element: AXUIElement

    init(element: AXUIElement) {
        self.element = element
    }

    // MARK: - Position

    /// The window's top-left position in AX coordinate space (top-left origin, Y increases downward).
    var position: CGPoint? {
        get {
            var val: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &val) == .success,
                  let axVal = val else { return nil }
            var point = CGPoint.zero
            // swiftlint:disable:next force_cast
            AXValueGetValue(axVal as! AXValue, .cgPoint, &point)
            return point
        }
        set {
            guard var p = newValue,
                  let axVal = AXValueCreate(.cgPoint, &p) else { return }
            AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, axVal)
        }
    }

    // MARK: - Size

    /// The window's size.
    var size: CGSize? {
        get {
            var val: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &val) == .success,
                  let axVal = val else { return nil }
            var size = CGSize.zero
            // swiftlint:disable:next force_cast
            AXValueGetValue(axVal as! AXValue, .cgSize, &size)
            return size
        }
        set {
            guard var s = newValue,
                  let axVal = AXValueCreate(.cgSize, &s) else { return }
            AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, axVal)
        }
    }

    // MARK: - Full Screen

    /// Whether the window is currently in macOS full-screen mode.
    var isFullScreen: Bool {
        get {
            var val: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXFullScreen as CFString, &val) == .success,
                  let boolVal = val else { return false }
            return CFBooleanGetValue((boolVal as! CFBoolean))
        }
        set {
            AXUIElementSetAttributeValue(
                element,
                kAXFullScreen as CFString,
                newValue ? kCFBooleanTrue : kCFBooleanFalse
            )
        }
    }

    // MARK: - Minimized

    /// Whether the window is currently minimized.
    var isMinimized: Bool {
        var val: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXMinimizedAttribute as CFString, &val) == .success,
              let boolVal = val else { return false }
        return CFBooleanGetValue((boolVal as! CFBoolean))
    }

    var role: String? {
        stringAttribute(kAXRoleAttribute)
    }

    var subrole: String? {
        stringAttribute(kAXSubroleAttribute)
    }

    // MARK: - Full Screen Transitions

    /// Exits full-screen mode and waits for the transition to complete (polls kAXFullScreen).
    /// - Returns: `true` if full-screen was successfully exited, `false` if timed out.
    @discardableResult
    func exitFullScreen() async -> Bool {
        guard isFullScreen else { return true }
        isFullScreen = false

        let deadline = Date().addingTimeInterval(3.0)
        while Date() < deadline {
            try? await Task.sleep(for: .milliseconds(100))
            if !isFullScreen { return true }
        }
        return false
    }

    /// Enters full-screen mode and waits for the transition to complete.
    /// - Returns: `true` if full-screen was successfully entered, `false` if timed out.
    @discardableResult
    func enterFullScreen() async -> Bool {
        isFullScreen = true

        let deadline = Date().addingTimeInterval(3.0)
        while Date() < deadline {
            try? await Task.sleep(for: .milliseconds(100))
            if isFullScreen { return true }
        }
        return false
    }

    // MARK: - Factory Methods

    /// Returns the focused window of the frontmost application, or nil if none.
    static func focusedWindow() -> AXWindowInfo? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var val: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &val) == .success,
              let win = val else { return nil }
        // swiftlint:disable:next force_cast
        return AXWindowInfo(element: win as! AXUIElement)
    }

    /// Returns all windows for the given process ID.
    static func allWindows(for pid: pid_t) -> [AXWindowInfo] {
        let axApp = AXUIElementCreateApplication(pid)
        var val: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &val) == .success,
              let windows = val as? [AXUIElement] else { return [] }
        return windows.map { AXWindowInfo(element: $0) }
    }

    private func stringAttribute(_ attribute: String) -> String? {
        var val: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &val) == .success else {
            return nil
        }

        return val as? String
    }
}
