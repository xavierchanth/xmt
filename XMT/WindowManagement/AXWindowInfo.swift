import AppKit
import ApplicationServices

// kAXFullScreenAttribute is an informal attribute not defined as a constant in headers.
private let kAXFullScreen = "AXFullScreen"

/// Failure-tolerant typed access to one Accessibility window element.
final class AXWindowInfo {
    let element: AXUIElement

    init(element: AXUIElement) { self.element = element }

    var position: CGPoint? {
        guard let value = copiedAXValue(kAXPositionAttribute, type: .cgPoint) else { return nil }
        var result = CGPoint.zero
        return AXValueGetValue(value, .cgPoint, &result) ? result : nil
    }
    var size: CGSize? {
        guard let value = copiedAXValue(kAXSizeAttribute, type: .cgSize) else { return nil }
        var result = CGSize.zero
        return AXValueGetValue(value, .cgSize, &result) ? result : nil
    }
    var isFullScreen: Bool? { booleanAttribute(kAXFullScreen) }
    var isMinimized: Bool? { booleanAttribute(kAXMinimizedAttribute) }
    var role: String? { stringAttribute(kAXRoleAttribute) }
    var subrole: String? { stringAttribute(kAXSubroleAttribute) }

    @discardableResult
    func setPosition(_ point: CGPoint) -> Bool {
        var point = point
        guard let value = AXValueCreate(.cgPoint, &point) else { return false }
        return AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, value) == .success
    }

    @discardableResult
    func setSize(_ size: CGSize) -> Bool {
        var size = size
        guard let value = AXValueCreate(.cgSize, &size) else { return false }
        return AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, value) == .success
    }

    @discardableResult
    func setFullScreen(_ value: Bool) -> Bool {
        AXUIElementSetAttributeValue(
            element, kAXFullScreen as CFString, value ? kCFBooleanTrue : kCFBooleanFalse
        ) == .success
    }

    /// Requests a full-screen transition and waits until the AX attribute confirms it. A timeout is
    /// indeterminate: callers must not claim where the window ultimately landed.
    func exitFullScreen() async throws -> Bool {
        guard let fullScreen = isFullScreen else { return false }
        guard fullScreen else { return true }
        guard setFullScreen(false) else { return false }
        return try await waitForFullScreen(false)
    }

    func enterFullScreen() async throws -> Bool {
        guard setFullScreen(true) else { return false }
        return try await waitForFullScreen(true)
    }

    private func waitForFullScreen(_ expected: Bool) async throws -> Bool {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(100))
            guard let actual = isFullScreen else { return false }
            if actual == expected { return true }
        }
        return false
    }

    static func focusedWindow() -> AXWindowInfo? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return AXWindowInfo(element: unsafeBitCast(value, to: AXUIElement.self))
    }

    static func allWindows(for pid: pid_t) -> [AXWindowInfo] {
        let app = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let values = value as? [CFTypeRef] else { return [] }
        return values.compactMap { value in
            guard CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
            return AXWindowInfo(element: unsafeBitCast(value, to: AXUIElement.self))
        }
    }

    private func booleanAttribute(_ attribute: String) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == CFBooleanGetTypeID() else { return nil }
        return CFBooleanGetValue(unsafeBitCast(value, to: CFBoolean.self))
    }

    private func stringAttribute(_ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == CFStringGetTypeID() else { return nil }
        return value as? String
    }

    private func copiedAXValue(_ attribute: String, type: AXValueType) -> AXValue? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let axValue = unsafeBitCast(value, to: AXValue.self)
        return AXValueGetType(axValue) == type ? axValue : nil
    }
}
