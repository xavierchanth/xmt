import SwiftUI
import KeyboardShortcuts

struct ShortcutsSettingsView: View {
    var body: some View {
        Form {
            KeyboardShortcuts.Recorder(
                "Move window to next screen:",
                name: .moveToNextScreen
            )
            KeyboardShortcuts.Recorder(
                "Rotate desktops:",
                name: .rotateDesktops
            )

            Text("Move window to next screen supports native full-screen windows.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            Text("Rotate desktops skips native full-screen windows and obvious floating/panel windows.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
    }
}
