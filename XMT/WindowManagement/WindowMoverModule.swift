import Combine
import Foundation
import KeyboardShortcuts

/// Lifecycle seam for the compiled-in Window Mover module.
@MainActor
final class WindowMoverModule: ObservableObject {
    static let shared = WindowMoverModule()
    static let enabledDefaultsKey = "windowMoverEnabled"
    static let defaultEnabled = true
    private static let shortcutBackupActiveKey = "windowMoverShortcutBackupActive"
    private static let shortcutBackupDataKey = "windowMoverShortcutBackupData"

    @Published private(set) var isEnabled: Bool
    @Published private(set) var isEnabledManaged = false
    @Published private(set) var isShortcutManaged = false
    var persistedEnabled: Bool { UserDefaults.standard.bool(forKey: Self.enabledDefaultsKey) }
    var persistedShortcut: ShortcutDTO? {
        let shortcut = isShortcutManaged ? unmanagedShortcut : KeyboardShortcuts.getShortcut(for: .moveToNextScreen)
        return shortcut.flatMap(ShortcutDTO.fromKeyboardShortcut)
    }
    private var isHandlerInstalled = false
    private var unmanagedShortcut: KeyboardShortcuts.Shortcut?

    private init() {
        UserDefaults.standard.register(defaults: [
            Self.enabledDefaultsKey: Self.defaultEnabled
        ])
        isEnabled = UserDefaults.standard.bool(forKey: Self.enabledDefaultsKey)
        if UserDefaults.standard.bool(forKey: Self.shortcutBackupActiveKey) {
            unmanagedShortcut = Self.loadShortcutBackup()
        } else {
            unmanagedShortcut = KeyboardShortcuts.getShortcut(for: .moveToNextScreen)
        }
    }

    func register() {
        reconcileHandler()
    }

    private func installHandler() {
        guard !isHandlerInstalled else { return }
        isHandlerInstalled = true
        KeyboardShortcuts.onKeyUp(for: .moveToNextScreen) { [weak self] in
            Task { @MainActor in
                guard let self, self.isEnabled else { return }
                WindowActionCoordinator.shared.perform {
                    await WindowMover.moveFocusedWindowToNextScreen()
                }
            }
        }
        applyShortcutState()
    }

    func stop() {
        WindowActionCoordinator.shared.cancel()
        KeyboardShortcuts.disable(.moveToNextScreen)
        if isHandlerInstalled {
            KeyboardShortcuts.removeHandler(for: .moveToNextScreen)
            isHandlerInstalled = false
        }
    }

    private func reconcileHandler() {
        if isEnabled { installHandler() }
        else { stop() }
    }

    func setEnabled(_ enabled: Bool) {
        guard !isEnabledManaged, enabled != isEnabled else { return }
        isEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Self.enabledDefaultsKey)
        reconcileHandler()

        if enabled {
            AccessibilityService.shared.refresh()
        }
    }

    func applyManaged(enabled: ResolvedSetting<Bool>, shortcut: ResolvedSetting<ShortcutDTO>) {
        isEnabledManaged = enabled.isManaged
        if isEnabled != enabled.value {
            isEnabled = enabled.value
            if !enabled.isManaged { UserDefaults.standard.set(enabled.value, forKey: Self.enabledDefaultsKey) }
            applyShortcutState()
        }

        let defaults = UserDefaults.standard
        let hasBackup = defaults.bool(forKey: Self.shortcutBackupActiveKey)
        isShortcutManaged = shortcut.isManaged
        if shortcut.isManaged {
            if !hasBackup {
                unmanagedShortcut = KeyboardShortcuts.getShortcut(for: .moveToNextScreen)
                Self.saveShortcutBackup(unmanagedShortcut)
            }
            if let converted = try? shortcut.value.keyboardShortcut() {
                KeyboardShortcuts.setShortcut(converted, for: .moveToNextScreen)
            }
        } else if hasBackup {
            KeyboardShortcuts.setShortcut(unmanagedShortcut, for: .moveToNextScreen)
            defaults.removeObject(forKey: Self.shortcutBackupDataKey)
            defaults.set(false, forKey: Self.shortcutBackupActiveKey)
        } else {
            unmanagedShortcut = KeyboardShortcuts.getShortcut(for: .moveToNextScreen)
        }
        // `setShortcut` registers immediately inside KeyboardShortcuts. Re-apply lifecycle state so
        // a disabled module never reserves and swallows its chord.
        reconcileHandler()
    }

    private static func saveShortcutBackup(_ shortcut: KeyboardShortcuts.Shortcut?) {
        let defaults = UserDefaults.standard
        defaults.set(true, forKey: shortcutBackupActiveKey)
        if let shortcut, let data = try? JSONEncoder().encode(shortcut) {
            defaults.set(data, forKey: shortcutBackupDataKey)
        } else {
            defaults.removeObject(forKey: shortcutBackupDataKey)
        }
    }

    private static func loadShortcutBackup() -> KeyboardShortcuts.Shortcut? {
        guard let data = UserDefaults.standard.data(forKey: shortcutBackupDataKey) else { return nil }
        return try? JSONDecoder().decode(KeyboardShortcuts.Shortcut.self, from: data)
    }

    private func applyShortcutState() {
        if isEnabled {
            KeyboardShortcuts.enable(.moveToNextScreen)
        } else {
            KeyboardShortcuts.disable(.moveToNextScreen)
        }
    }
}
