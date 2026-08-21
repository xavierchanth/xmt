import Combine
import Foundation
import KeyboardShortcuts

/// Lifecycle seam for the compiled-in Window Mover module.
@MainActor
final class WindowMoverModule: ObservableObject {
    static let shared = WindowMoverModule()
    static let enabledDefaultsKey = "windowMoverEnabled"
    static let defaultEnabled = true

    @Published private(set) var isEnabled: Bool
    private var isHandlerInstalled = false

    private init() {
        UserDefaults.standard.register(defaults: [
            Self.enabledDefaultsKey: Self.defaultEnabled
        ])
        isEnabled = UserDefaults.standard.bool(forKey: Self.enabledDefaultsKey)
    }

    func register() {
        guard !isHandlerInstalled else { return }
        isHandlerInstalled = true

        KeyboardShortcuts.onKeyUp(for: .moveToNextScreen) { [weak self] in
            Task { @MainActor in
                // Defence in depth if a queued or library callback arrives after disable.
                guard let self, self.isEnabled else { return }
                WindowActionCoordinator.shared.perform {
                    await WindowMover.moveFocusedWindowToNextScreen()
                }
            }
        }
        applyShortcutState()
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.enabledDefaultsKey)
        applyShortcutState()

        if enabled {
            AccessibilityService.shared.refresh()
        }
    }

    private func applyShortcutState() {
        if isEnabled {
            KeyboardShortcuts.enable(.moveToNextScreen)
        } else {
            KeyboardShortcuts.disable(.moveToNextScreen)
        }
    }
}
