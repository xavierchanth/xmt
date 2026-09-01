import SwiftUI

@main
struct XMTApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        MenuBarExtra("XMT", image: "MenuBarIcon") {
            MenuBarView()
        }
    }
}
