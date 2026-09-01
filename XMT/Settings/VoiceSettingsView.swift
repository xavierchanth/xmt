import KeyboardShortcuts
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
                AccessibilityStatusView(consumerDescription: "Voice Transcription uses Accessibility to paste completed text and the latest retained transcript.")
            }
            Section("Output") {
                Toggle("Paste completed transcript", isOn: $module.autoPaste).disabled(module.managedKeys.contains(.autoPaste))
                TextField("Locale", text: $module.localeIdentifier).disabled(module.managedKeys.contains(.locale))
                Button("Copy Last Transcript") { module.copyLastTranscript() }.disabled(module.lastTranscript.isEmpty)
                KeyboardShortcuts.Recorder(
                    "Paste latest transcript:",
                    name: .pasteLatestTranscript
                )
                .disabled(module.managedKeys.contains(.pasteLatestTranscriptShortcut))
            }
            Section("Transcript history") {
                Toggle("Save transcript history", isOn: $module.historyEnabled)
                    .disabled(module.managedKeys.contains(.historyEnabled))
                TextField("Retention (days)", value: $module.historyRetentionDays, format: .number)
                    .disabled(!module.historyEnabled || module.managedKeys.contains(.historyRetentionDays))
                TextField("Maximum entries", value: $module.historyMaxEntries, format: .number)
                    .disabled(!module.historyEnabled || module.managedKeys.contains(.historyMaxEntries))
            }
            Section("Input priority") {
                DevicePriorityListView(module: module,
                                       priorityManaged: module.managedKeys.contains(.inputDevicePriority),
                                       fallbackManaged: module.managedKeys.contains(.fallbackToSystemDefault))
            }
            if module.status == .pending {
                Section("Recovery") { Button("Retry Recording") { module.retryPending() }; Button("Delete Recording", role: .destructive) { module.deletePending() } }
            } else if case .failed(let message) = module.status {
                Section("Voice failure") { Text(message).foregroundStyle(.secondary) }
            }
            Section("Configuration") {
                HStack { Button("Reload Configuration") { module.reloadConfig() }; if let diagnostic = module.configDiagnostic { Text(diagnostic).foregroundStyle(.red) } }
            }
        }
        .formStyle(.grouped)
        .onAppear { module.refreshDevices(); module.refreshAssets() }
    }
}
