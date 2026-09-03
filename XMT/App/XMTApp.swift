import SwiftUI

@main
struct XMTApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // Settings is presented by the retained AppKit controller. This inert scene satisfies
        // SwiftUI's scene requirement without creating a second menu or window lifecycle.
        Settings { EmptyView() }
    }
}
