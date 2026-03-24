import AppKit
import KeyboardShortcuts

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Request accessibility permission on first launch
        AccessibilityService.requestIfNeeded()

        // Register global hotkey handlers
        KeyboardShortcuts.onKeyUp(for: .moveToNextScreen) {
            WindowActionCoordinator.shared.perform {
                await WindowMover.moveFocusedWindowToNextScreen()
            }
        }

        KeyboardShortcuts.onKeyUp(for: .rotateDesktops) {
            WindowActionCoordinator.shared.perform {
                await WindowRotator.rotateDesktops()
            }
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        Task { @MainActor in
            AccessibilityReminder.refreshPermissionState()
        }
    }
}
