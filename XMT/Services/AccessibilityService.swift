import AppKit
import ApplicationServices
import Combine

@MainActor
final class AccessibilityService: ObservableObject {
    static let shared = AccessibilityService()

    @Published private(set) var displayedIsGranted = AXIsProcessTrusted()

    var isGranted: Bool { AXIsProcessTrusted() }

    private init() {}

    func refresh() {
        displayedIsGranted = isGranted
        AccessibilityReminder.refreshPermissionState()
    }

    /// Asks macOS to add XMT to the Accessibility list when access is denied.
    /// This is only called from contextual user actions, never at app launch.
    func requestIfNeeded() {
        guard !AXIsProcessTrusted() else {
            refresh()
            return
        }
        AXIsProcessTrustedWithOptions([
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
        ] as CFDictionary)
        refresh()
    }

    func openSystemSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        ) else { return }
        NSWorkspace.shared.open(url)
    }
}
