import SwiftUI
import ServiceManagement

struct GeneralSettingsView: View {
    @State private var launchAtLogin: Bool = (SMAppService.mainApp.status == .enabled)
    @State private var axGranted: Bool = AccessibilityService.isGranted

    var body: some View {
        Form {
            Section("Startup") {
                Toggle("Launch at Login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in
                        do {
                            if newValue {
                                try SMAppService.mainApp.register()
                            } else {
                                try SMAppService.mainApp.unregister()
                            }
                        } catch {
                            // Revert the toggle if registration failed
                            launchAtLogin = !newValue
                        }
                    }
            }

            Section("Permissions") {
                HStack {
                    Image(systemName: axGranted ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(axGranted ? Color.green : Color.red)
                    Text(axGranted
                         ? "Accessibility access granted"
                         : "Accessibility access required")
                    Spacer()
                    if !axGranted {
                        Button("Re-request Permissions") {
                            rerequestAccessibilityPermissions()
                        }
                    }
                }

                Text("Shortcut reminders appear once and stay suppressed until the Accessibility permission state changes.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        // Re-check accessibility status each time the settings window becomes active
        .onReceive(
            NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
        ) { _ in
            axGranted = AccessibilityService.isGranted
            launchAtLogin = (SMAppService.mainApp.status == .enabled)
            AccessibilityReminder.refreshPermissionState()
        }
    }

    private func rerequestAccessibilityPermissions() {
        AccessibilityService.rerequestIfNeeded()
    }
}
