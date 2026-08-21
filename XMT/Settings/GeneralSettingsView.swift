import ServiceManagement
import SwiftUI

struct GeneralSettingsView: View {
    @State private var launchAtLogin = false

    var body: some View {
        Form {
            Section("Startup") {
                Toggle(
                    "Launch at Login",
                    isOn: Binding(
                        get: { launchAtLogin },
                        set: { setLaunchAtLogin($0) }
                    )
                )
            }

            Section("Permissions") {
                AccessibilityStatusView()
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: refreshLaunchAtLogin)
        .onReceive(
            NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
        ) { _ in
            refreshLaunchAtLogin()
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            // Status below remains authoritative after either success or failure.
        }
        refreshLaunchAtLogin()
    }

    private func refreshLaunchAtLogin() {
        launchAtLogin = (SMAppService.mainApp.status == .enabled)
    }
}
