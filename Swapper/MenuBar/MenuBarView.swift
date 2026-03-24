import AppKit
import SwiftUI

struct MenuBarView: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button {
            SettingsWindowController.shared.show {
                openWindow(id: SettingsWindowController.windowID)
            }
        } label: {
            Text("Settings...")
        }
        .keyboardShortcut(",", modifiers: .command)

        Divider()

        Button("Quit Swapper") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q", modifiers: .command)
    }
}
