import KeyboardShortcuts
import SwiftUI

struct WindowMoverSettingsView: View {
    @ObservedObject private var module = WindowMoverModule.shared

    var body: some View {
        Form {
            Section {
                Toggle(
                    "Enable Window Mover",
                    isOn: Binding(
                        get: { module.isEnabled },
                        set: { module.setEnabled($0) }
                    )
                )
            }

            Section("Accessibility") {
                AccessibilityStatusView()
            }

            Section("Shortcut") {
                KeyboardShortcuts.Recorder(
                    "Move window to next screen:",
                    name: .moveToNextScreen
                )
                .disabled(!module.isEnabled)

                Text("Moves the focused window to the next display and supports native full-screen windows.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
