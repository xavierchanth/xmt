import AppKit
import OSLog

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let logger = Logger(subsystem: "com.xavierchanth.xmt", category: "AppShell")

    func applicationDidFinishLaunching(_ notification: Notification) {
        logger.notice("XMT finished launching")
        // Install callbacks and apply persisted state without prompting for permission.
        WindowMoverModule.shared.register()
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
        VoiceTranscriptionModule.shared.stop()
    }
}
