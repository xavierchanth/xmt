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
        InputRoutingCoordinator.shared.setWindowEnabled(isEnabled)
    }

    func stop() {
        WindowActionCoordinator.shared.cancel()
        InputRoutingCoordinator.shared.setWindowEnabled(false)
    }

    private func reconcileHandler() {
        if !isEnabled { WindowActionCoordinator.shared.cancel() }
        InputRoutingCoordinator.shared.setWindowEnabled(isEnabled)
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

    func acceptUnmanagedShortcut(_ shortcut: KeyboardShortcuts.Shortcut?) {
        guard !isShortcutManaged else { return }
        unmanagedShortcut = shortcut
    }

    func restoreUnmanagedShortcut() {
        guard !isShortcutManaged else { return }
        restoreActiveShortcut(unmanagedShortcut)
    }

    func restoreActiveShortcut(_ shortcut: KeyboardShortcuts.Shortcut?) {
        KeyboardShortcuts.setShortcut(shortcut, for: .moveToNextScreen)
        applyShortcutState()
    }

    func restoreEffectiveShortcut(_ shortcut: ResolvedSetting<ShortcutDTO>) {
        let restored = try? shortcut.value.keyboardShortcut()
        KeyboardShortcuts.setShortcut(restored, for: .moveToNextScreen)
        if !shortcut.isManaged { unmanagedShortcut = restored }
        applyShortcutState()
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
        // `setShortcut` can reactivate library storage. Re-apply shell-owned lifecycle state so a
        // disabled module never reserves and swallows its chord.
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
        InputRoutingCoordinator.shared.setWindowEnabled(isEnabled)
    }

    func performRoutedAction() {
        guard isEnabled else { return }
        WindowActionCoordinator.shared.perform {
            await WindowMover.moveFocusedWindowToNextScreen()
        }
    }
}

extension WindowMoverModule: WindowMoverLocalSettingsAdapter {
    func readWindowMoverLocalSettings() -> WindowMoverLocalSettings {
        .init(enabled: persistedEnabled, shortcut: persistedShortcut)
    }

    func acceptUnmanagedWindowMoverShortcut(_ shortcut: KeyboardShortcuts.Shortcut?) {
        acceptUnmanagedShortcut(shortcut)
    }

    func restoreUnmanagedWindowMoverShortcut() {
        restoreUnmanagedShortcut()
    }

    func restoreWindowMoverShortcut(_ shortcut: ResolvedSetting<ShortcutDTO>) {
        restoreEffectiveShortcut(shortcut)
    }
}
