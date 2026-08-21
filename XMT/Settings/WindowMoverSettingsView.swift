import KeyboardShortcuts
import SwiftUI

struct WindowMoverSettingsView: View {
    @AppStorage(WindowMoverModule.enabledDefaultsKey) private var isEnabled = true

    var body: some View {
        Form {
            Section {
                Toggle("Enable Window Mover", isOn: $isEnabled)
                    .onChange(of: isEnabled) { _, enabled in
                        WindowMoverModule.shared.setEnabled(enabled)
                    }
            }

            Section("Accessibility") {
                AccessibilityStatusView()
            }

            Section("Shortcut") {
                KeyboardShortcuts.Recorder(
                    "Move window to next screen:",
                    name: .moveToNextScreen
                )
                .disabled(!isEnabled)

                Text("Moves the focused window to the next display and supports native full-screen windows.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
