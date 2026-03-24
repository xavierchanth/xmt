import ApplicationServices

enum AccessibilityService {
    /// Checks if the app has accessibility permission. If not, prompts the user.
    /// This should be called once at launch.
    static func requestIfNeeded() {
        guard !AXIsProcessTrusted() else { return }
        AXIsProcessTrustedWithOptions(promptOptions as CFDictionary)
    }

    /// Returns whether the app currently has accessibility permission.
    static var isGranted: Bool {
        AXIsProcessTrusted()
    }

    /// Re-prompts macOS for Accessibility trust.
    /// This can register the app in the Accessibility list if it is currently missing.
    static func rerequestIfNeeded() {
        guard !AXIsProcessTrusted() else { return }
        AXIsProcessTrustedWithOptions(promptOptions as CFDictionary)
    }

    private static let promptOptions = [
        kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
    ]
}
