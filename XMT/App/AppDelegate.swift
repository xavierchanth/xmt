import AppKit

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Registration is inert until a shortcut fires and never prompts for permission.
        WindowMoverModule.shared.register()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        Task { @MainActor in
            AccessibilityService.shared.refresh()
        }
    }
}
