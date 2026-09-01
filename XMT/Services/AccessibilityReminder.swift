import AppKit

@MainActor
enum AccessibilityReminder {
    private static var hasShownReminderWhileDenied = false

    static func refreshPermissionState() {
        if AccessibilityService.shared.isGranted {
            hasShownReminderWhileDenied = false
        }
    }

    static func showIfNeeded() {
        if AccessibilityService.shared.isGranted {
            hasShownReminderWhileDenied = false
            return
        }

        guard !hasShownReminderWhileDenied else { return }
        hasShownReminderWhileDenied = true

        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "Accessibility access is required"
        alert.informativeText = "Window Mover needs Accessibility access to move windows. You can grant it in System Settings."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "OK")

        if alert.runModal() == .alertFirstButtonReturn {
            AccessibilityService.shared.openSystemSettings()
        }
    }
}
