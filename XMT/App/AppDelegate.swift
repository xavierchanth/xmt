import AppKit

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Install the callback and apply the persisted enabled state without prompting for permission.
        WindowMoverModule.shared.register()
        VoiceTranscriptionModule.shared.register()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        Task { @MainActor in
            AccessibilityService.shared.refresh()
            VoiceTranscriptionModule.shared.refreshDevices()
            VoiceTranscriptionModule.shared.reloadConfig()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { VoiceTranscriptionModule.shared.stop() }
    }
}
