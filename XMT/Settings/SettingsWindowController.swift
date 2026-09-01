import AppKit
import SwiftUI

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    static let shared = SettingsWindowController()
    static let windowID = "settings"

    private var window: NSWindow?

    private override init() { super.init() }

    func show() {
        let window = window ?? makeWindow()
        present(window)
    }

    private func makeWindow() -> NSWindow {
        let content = NSHostingController(rootView: SettingsView())
        let window = NSWindow(contentViewController: content)
        window.identifier = NSUserInterfaceItemIdentifier(Self.windowID)
        window.title = "XMT Settings"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 660, height: 600))
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self
        self.window = window
        return window
    }

    private func present(_ window: NSWindow) {
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }

        NSRunningApplication.current.activate(options: [.activateAllWindows])
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}
