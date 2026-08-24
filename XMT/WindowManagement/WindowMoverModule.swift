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
    @Published private(set) var isEnabledManaged = false
    @Published private(set) var isShortcutManaged = false
    var persistedEnabled: Bool { UserDefaults.standard.bool(forKey: Self.enabledDefaultsKey) }
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
        guard !isEnabledManaged, enabled != isEnabled else { return }
        isEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.enabledDefaultsKey)
        applyShortcutState()

        if enabled {
            AccessibilityService.shared.refresh()
        }
    }

    func applyManaged(enabled: ResolvedSetting<Bool>, shortcut: ResolvedSetting<ShortcutDTO>) {
        isEnabledManaged = enabled.isManaged
        isShortcutManaged = shortcut.isManaged
        if isEnabled != enabled.value {
            isEnabled = enabled.value
            if !enabled.isManaged { UserDefaults.standard.set(enabled.value, forKey: Self.enabledDefaultsKey) }
            applyShortcutState()
        }
        if shortcut.isManaged, let converted = try? shortcut.value.keyboardShortcut() {
            KeyboardShortcuts.setShortcut(converted, for: .moveToNextScreen)
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
