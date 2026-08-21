import Foundation
import KeyboardShortcuts

/// Lifecycle seam for the compiled-in Window Mover module.
///
/// KeyboardShortcuts 2.x does not expose callback removal. The callback is therefore
/// installed once, and this manager enforces the lifecycle boundary before any module
/// operation starts. Disabled modules acquire no other resources or perform any work.
@MainActor
final class WindowMoverModule {
    static let shared = WindowMoverModule()
    static let enabledDefaultsKey = "windowMoverEnabled"

    private var isHandlerInstalled = false

    private init() {
        UserDefaults.standard.register(defaults: [Self.enabledDefaultsKey: true])
    }

    var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: Self.enabledDefaultsKey)
    }

    func register() {
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
    }

    func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Self.enabledDefaultsKey)
        guard enabled else { return }
        AccessibilityService.shared.refresh()
    }
}
