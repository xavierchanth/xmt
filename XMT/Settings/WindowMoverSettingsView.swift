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
                .disabled(module.isEnabledManaged)
            }

            Section("Accessibility") {
                AccessibilityStatusView()
            }

            Section("Shortcut") {
                if module.isEnabled {
                    KeyboardShortcuts.Recorder(
                        "Move window to next screen:",
                        name: .moveToNextScreen,
                        onChange: { ConfigurationCoordinator.shared.userChangedWindowMoverShortcut($0) }
                    )
                    .disabled(module.isShortcutManaged)
                } else {
                    Text("Enable Window Mover to configure or use its shortcut.")
                        .foregroundStyle(.secondary)
                }

                Text("Moves the focused window to the next display and supports native full-screen windows.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}
