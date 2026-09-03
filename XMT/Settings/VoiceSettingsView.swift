import KeyboardShortcuts
import SwiftUI

struct VoiceSettingsView: View {
    @ObservedObject private var module = VoiceTranscriptionModule.shared
    @State private var bindingRecorder = VoiceBindingRecorderModel()
    @State private var captureToken: VoiceBindingCaptureLease.Token?
    @State private var busyAction: VoiceBindingAction?

    var body: some View {
        Form {
            Section {
                Toggle("Enable Voice Transcription", isOn: $module.isEnabled)
                    .disabled(module.managedKeys.contains(.voiceEnabled))
                Text("Use Hold to Talk, Toggle Recording, or Cancel. Fn remains available for Hold to Talk.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("Voice bindings") {
                bindingRow("Hold to talk", action: .holdToTalk, managed: .holdToTalkShortcut)
                bindingRow("Toggle recording", action: .toggleRecording, managed: .toggleRecordingShortcut)
                bindingRow("Cancel", action: .cancel, managed: .cancelShortcut)
                Text("Escape alone cancels capture; Control–Escape and Fn–Escape are bindable. macOS Keyboard settings for Globe/Fn may intercept some Fn events before XMT.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("Permissions and speech assets") {
                HStack { Text("Speech assets: \(module.assetStatus)"); Spacer(); Button("Check") { module.refreshAssets() }; Button("Download") { module.downloadAssets() } }
                Button("Request Required Access") { module.requestPermissions() }
                AccessibilityStatusView(consumerDescription: "Voice Transcription uses Accessibility to paste completed text when requested.")
            }
            Section("Output") {
                Picker("Completed transcript", selection: $module.outputMode) {
                    Text("Paste immediately").tag(VoiceOutputMode.pasteImmediately)
                    Text("Clipboard only").tag(VoiceOutputMode.clipboardOnly)
                }.disabled(module.managedKeys.contains(.outputMode))
                Picker("Language", selection: $module.localeIdentifier) {
                    Text("System Language").tag("system")
                    ForEach(module.supportedLocaleIdentifiers, id: \.self) { id in Text(Locale.current.localizedString(forIdentifier: id) ?? id).tag(id) }
                }.disabled(module.managedKeys.contains(.locale))
                Button("Copy Last Transcript") { module.copyLastTranscript() }.disabled(module.lastTranscript.isEmpty)
                KeyboardShortcuts.Recorder("Paste latest transcript:", name: .pasteLatestTranscript,
                    onChange: { module.userChangedPasteLatestShortcut($0) })
                    .disabled(module.managedKeys.contains(.pasteLatestTranscriptShortcut))
            }
            Section("Transcript history") {
                Toggle("Save transcript history", isOn: $module.historyEnabled).disabled(module.managedKeys.contains(.historyEnabled))
                TextField("Retention (days)", value: $module.historyRetentionDays, format: .number).disabled(!module.historyEnabled || module.managedKeys.contains(.historyRetentionDays))
                TextField("Maximum entries", value: $module.historyMaxEntries, format: .number).disabled(!module.historyEnabled || module.managedKeys.contains(.historyMaxEntries))
            }
            Section("Input priority") { DevicePriorityListView(module: module, priorityManaged: module.managedKeys.contains(.inputDevicePriority), fallbackManaged: module.managedKeys.contains(.fallbackToSystemDefault)) }
            if module.status == .pending { Section("Recovery") { Button("Retry Recording") { module.retryPending() }; Button("Delete Recording", role: .destructive) { module.deletePending() } } }
            Section("Configuration") { HStack { Button("Reload Configuration") { module.reloadConfig() }; if let diagnostic = module.configDiagnostic { Text(diagnostic).foregroundStyle(.red) } } }
        }.formStyle(.grouped)
            .onAppear { module.refreshDevices(); module.refreshLocalesAndAssets() }
            .onDisappear {
                module.cancelVoiceBindingCapture()
                captureToken = nil; busyAction = nil
                if let action = bindingRecorder.activeAction { bindingRecorder.receive(.cancel(action)) }
            }
    }

    private func bindingRow(_ title: String, action: VoiceBindingAction, managed: EffectiveSettings.Key) -> some View {
        VoiceBindingRecorder(title: title, action: action, value: module.effectiveVoiceBinding(for: action),
            isManaged: module.managedKeys.contains(managed), isRecording: bindingRecorder.activeAction == action,
            isOtherBindingBusy: busyAction != nil && busyAction != action,
            begin: {
                captureToken = module.acquireVoiceBindingCapture(); busyAction = action
                bindingRecorder.receive(.begin(action))
            },
            cancel: {
                bindingRecorder.receive(.cancel(action))
                if let token = captureToken { module.releaseVoiceBindingCapture(token) }
                captureToken = nil; busyAction = nil
            },
            commit: { binding in
                let token = captureToken ?? module.acquireVoiceBindingCapture()
                captureToken = token; busyAction = action
                switch binding {
                case .unbound: bindingRecorder.receive(.clear(action))
                case .modifierHold where action == .holdToTalk: bindingRecorder.receive(.selectFn)
                default: bindingRecorder.receive(.captured(action, binding))
                }
                let diagnostic = await module.commitVoiceBinding(binding, action: action)
                module.releaseVoiceBindingCapture(token)
                if captureToken == token { captureToken = nil; busyAction = nil }
                return diagnostic
            })
    }
}
