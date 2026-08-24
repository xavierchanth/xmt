import SwiftUI

struct VoiceSettingsView: View {
    @ObservedObject private var module = VoiceTranscriptionModule.shared

    var body: some View {
        Form {
            Section {
                Toggle("Enable Voice Transcription", isOn: $module.isEnabled)
                    .disabled(module.managedKeys.contains(.voiceEnabled))
                Text("Hold Fn to talk. Press Fn-Space to latch or stop recording.").font(.footnote).foregroundStyle(.secondary)
            }
            Section("Permissions and speech assets") {
                HStack { Text("Speech assets: \(module.assetStatus)"); Spacer(); Button("Check") { module.refreshAssets() }; Button("Download") { module.downloadAssets() } }
                Button("Request Required Access") { module.requestPermissions() }
                AccessibilityStatusView(consumerDescription: "Voice Transcription uses Accessibility only to paste completed text when Auto-paste is enabled.")
            }
            Section("Output") {
                Toggle("Paste completed transcript", isOn: $module.autoPaste).disabled(module.managedKeys.contains(.autoPaste))
                Toggle("Keep last transcript", isOn: $module.keepLastTranscript).disabled(module.managedKeys.contains(.keepLastTranscript))
                TextField("Locale", text: $module.localeIdentifier).disabled(module.managedKeys.contains(.locale))
                Button("Copy Last Transcript") { module.copyLastTranscript() }.disabled(module.lastTranscript.isEmpty)
            }
            Section("Input priority") {
                DevicePriorityListView(module: module,
                                       priorityManaged: module.managedKeys.contains(.inputDevicePriority),
                                       fallbackManaged: module.managedKeys.contains(.fallbackToSystemDefault))
            }
            if module.status == .pending || { if case .failed = module.status { return true }; return false }() {
                Section("Recovery") { Button("Retry Recording") { module.retryPending() }; Button("Delete Recording", role: .destructive) { module.deletePending() } }
            }
            Section("Configuration") {
                HStack { Button("Reload Configuration") { module.reloadConfig() }; if let diagnostic = module.configDiagnostic { Text(diagnostic).foregroundStyle(.red) } }
            }
        }
        .formStyle(.grouped)
        .onAppear { module.refreshDevices(); module.refreshAssets() }
    }
}
