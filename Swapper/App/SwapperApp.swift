import SwiftUI

@main
struct SwapperApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        MenuBarExtra("Swapper", image: "MenuBarIcon") {
            MenuBarView()
        }

        Window("Settings", id: SettingsWindowController.windowID) {
            SettingsView()
        }
    }
}
