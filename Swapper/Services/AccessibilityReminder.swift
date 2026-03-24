import AppKit

@MainActor
enum AccessibilityReminder {
    private static var hasShownReminderWhileDenied = false

    static func refreshPermissionState() {
        if AccessibilityService.isGranted {
            hasShownReminderWhileDenied = false
        }
    }

    static func showIfNeeded() {
        if AccessibilityService.isGranted {
            hasShownReminderWhileDenied = false
            return
        }

        guard !hasShownReminderWhileDenied else { return }
        hasShownReminderWhileDenied = true

        let alert = NSAlert()
        alert.messageText = "Accessibility access is required"
        alert.informativeText = "Swapper needs Accessibility access to move windows. You can grant it in System Settings."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "OK")

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            AccessibilityService.rerequestIfNeeded()

            guard let url = URL(
                string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
            ) else { return }

            NSWorkspace.shared.open(url)
        }
    }
}
