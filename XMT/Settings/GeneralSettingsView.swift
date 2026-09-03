import ServiceManagement
import SwiftUI

struct GeneralSettingsView: View {
    @State private var launchAtLoginStatus = SMAppService.mainApp.status
    @State private var registrationError: String?
    @State private var showingRestoreConfirmation = false
    @State private var isRestoringDefaults = false
    @State private var restoreError: String?

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
                AccessibilityStatusView(consumerDescription: "Window Mover uses Accessibility to move windows. Voice Transcription uses it only for optional Auto-paste; Fn gestures use Input Monitoring and recording uses Microphone access.")
            }

            Section("Defaults") {
                Button("Restore All Defaults…", role: .destructive) {
                    showingRestoreConfirmation = true
                }
                .disabled(isRestoringDefaults)

                Text("Restores Window Mover and Voice together. Values managed by configuration remain active, and their saved local values are preserved.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: refreshLaunchAtLogin)
        .onReceive(
            NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
        ) { _ in
            refreshLaunchAtLogin()
        }
        .alert("Restore All Defaults?", isPresented: $showingRestoreConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Restore", role: .destructive) { restoreDefaults() }
        } message: {
            Text("This replaces every unmanaged Window Mover and Voice setting with XMT’s built-in defaults. The complete change is validated before any setting is applied.")
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
        .alert(
            "Couldn’t Restore Defaults",
            isPresented: Binding(
                get: { restoreError != nil },
                set: { if !$0 { restoreError = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(restoreError ?? "No settings were changed.")
        }
    }

    private func restoreDefaults() {
        guard !isRestoringDefaults else { return }
        isRestoringDefaults = true
        Task { @MainActor in
            restoreError = await VoiceTranscriptionModule.shared.restoreDefaults()
            isRestoringDefaults = false
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
