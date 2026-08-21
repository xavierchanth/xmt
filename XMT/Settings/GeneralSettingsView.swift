import ServiceManagement
import SwiftUI

struct GeneralSettingsView: View {
    @State private var launchAtLoginStatus = SMAppService.mainApp.status
    @State private var registrationError: String?

    var body: some View {
        Form {
            Section("Startup") {
                Toggle(
                    "Launch at Login",
                    isOn: Binding(
                        get: { launchAtLoginStatus == .enabled },
                        set: { setLaunchAtLogin($0) }
                    )
                )

                if launchAtLoginStatus == .requiresApproval {
                    Text("Launch at Login requires approval in System Settings → General → Login Items.")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
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
        .alert(
            "Couldn’t Update Launch at Login",
            isPresented: Binding(
                get: { registrationError != nil },
                set: { if !$0 { registrationError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(registrationError ?? "Please try again.")
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
            registrationError = error.localizedDescription
        }
        refreshLaunchAtLogin()
    }

    private func refreshLaunchAtLogin() {
        launchAtLoginStatus = SMAppService.mainApp.status
    }
}
