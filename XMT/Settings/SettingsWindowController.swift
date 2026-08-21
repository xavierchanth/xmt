import AppKit

@MainActor
final class SettingsWindowController {
    static let shared = SettingsWindowController()
    static let windowID = "settings"

    private weak var window: NSWindow?

    private init() {}

    func register(window: NSWindow) {
        self.window = window
        window.identifier = NSUserInterfaceItemIdentifier(Self.windowID)
    }

    func show(openWindow: () -> Void) {
        NSApp.activate(ignoringOtherApps: true)

        if let window {
            present(window)
            return
        }

        openWindow()

        DispatchQueue.main.async {
            self.presentRegisteredWindow()
        }
    }

    private func presentRegisteredWindow() {
        if let window {
            present(window)
            return
        }

        guard let window = NSApp.windows.first(where: { $0.identifier?.rawValue == Self.windowID }) else {
            return
        }

        register(window: window)
        present(window)
    }

    private func present(_ window: NSWindow) {
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }

        NSRunningApplication.current.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }
}
