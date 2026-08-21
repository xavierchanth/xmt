import AppKit

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Install the callback and apply the persisted enabled state without prompting for permission.
        WindowMoverModule.shared.register()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        Task { @MainActor in
            AccessibilityService.shared.refresh()
        }
    }
}
