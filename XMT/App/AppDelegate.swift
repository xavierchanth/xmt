import AppKit
import OSLog

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let logger = Logger(subsystem: "com.xavierchanth.xmt", category: "AppShell")
    // The delegate is retained by NSApplication; this is the sole strong process-lifetime owner.
    private var menuBarController: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        logger.notice("XMT finished launching")
        precondition(menuBarController == nil, "A second XMT status item was requested")
        menuBarController = MenuBarController()
        logger.notice("AppKit status item installed")
        // Install callbacks and apply persisted state without prompting for permission.
        VoiceTranscriptionModule.shared.register()
        // A crowded macOS 26 menu bar can clip status items. Always provide a visible
        // recovery surface when the user explicitly launches XMT.
        SettingsWindowController.shared.show()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        Task { @MainActor in
            AccessibilityService.shared.refresh()
            VoiceTranscriptionModule.shared.refreshDevices()
            VoiceTranscriptionModule.shared.reloadConfig()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        SettingsWindowController.shared.show()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        logger.notice("XMT will terminate")
        WindowMoverModule.shared.stop()
        VoiceTranscriptionModule.shared.stop()
    }
}
