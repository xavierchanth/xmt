import KeyboardShortcuts
import SwiftUI

struct VoiceSettingsView: View {
    @ObservedObject private var module = VoiceTranscriptionModule.shared
    @State private var lists: [VoiceBindingAction: [ShortcutDTO]] = [:]
    @State private var active: Row?
    @State private var transaction = VoiceBindingCaptureTransaction()

    private struct Row: Equatable {
        let action: VoiceBindingAction
        let index: Int
        let token: VoiceBindingCaptureLease.Token
    }

    var body: some View {
        Form {
            Section {
                Toggle("Enable Voice Transcription", isOn: $module.isEnabled).disabled(module.managedKeys.contains(.voiceEnabled))
                Text("Each action can have several standard or Fn bindings.").font(.footnote).foregroundStyle(.secondary)
            }
            Section("Voice bindings") {
                ForEach(VoiceBindingAction.all, id: \.self) { action in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(action.title).font(.headline)
                        ForEach(Array((lists[action] ?? []).enumerated()), id: \.offset) { index, binding in
                            HStack {
                                bindingRow(action: action, index: index, binding: binding)
                                Button { move(action, index, -1) } label: { Image(systemName: "chevron.up") }.disabled(index == 0 || active != nil)
                                Button { move(action, index, 1) } label: { Image(systemName: "chevron.down") }.disabled(index + 1 == lists[action]?.count || active != nil)
                                Button(role: .destructive) { remove(action, index) } label: { Image(systemName: "minus.circle") }
                                    .disabled(isManaged(action) || active != nil)
                            }
                        }
                        Button { add(action) } label: { Label("Add \(action.title) binding", systemImage: "plus.circle") }
                            .disabled(isManaged(action) || active != nil || (lists[action]?.count ?? 0) >= KeyboardShortcuts.Name.voiceBindingSlotCount)
                    }
                }
                Text("Escape alone cancels capture; Control–Escape and Fn–Escape are bindable.").font(.footnote).foregroundStyle(.secondary)
            }
            Section("Permissions and speech assets") {
                HStack { Text("Speech assets: \(module.assetStatus)"); Spacer(); Button("Check") { module.refreshAssets() }; Button("Download") { module.downloadAssets() } }
                Button("Request Required Access") { module.requestPermissions() }
                AccessibilityStatusView(consumerDescription: "Voice Transcription uses Accessibility to paste completed text when requested.")
            }
            Section("Output") {
                Picker("Completed transcript", selection: $module.outputMode) { Text("Paste immediately").tag(VoiceOutputMode.pasteImmediately); Text("Clipboard only").tag(VoiceOutputMode.clipboardOnly) }.disabled(module.managedKeys.contains(.outputMode))
                Picker("Language", selection: $module.localeIdentifier) { Text("System Language").tag("system"); ForEach(module.supportedLocaleIdentifiers, id: \.self) { id in Text(Locale.current.localizedString(forIdentifier: id) ?? id).tag(id) } }.disabled(module.managedKeys.contains(.locale))
                Button("Copy Last Transcript") { module.copyLastTranscript() }.disabled(module.lastTranscript.isEmpty)
                KeyboardShortcuts.Recorder("Paste latest transcript:", name: .pasteLatestTranscript, onChange: { module.userChangedPasteLatestShortcut($0) }).disabled(module.managedKeys.contains(.pasteLatestTranscriptShortcut))
            }
            Section("Transcript history") {
                Toggle("Save transcript history", isOn: $module.historyEnabled).disabled(module.managedKeys.contains(.historyEnabled))
                TextField("Retention (days)", value: $module.historyRetentionDays, format: .number).disabled(!module.historyEnabled || module.managedKeys.contains(.historyRetentionDays))
                TextField("Maximum entries", value: $module.historyMaxEntries, format: .number).disabled(!module.historyEnabled || module.managedKeys.contains(.historyMaxEntries))
            }
            Section("Input priority") { DevicePriorityListView(module: module, priorityManaged: module.managedKeys.contains(.inputDevicePriority), fallbackManaged: module.managedKeys.contains(.fallbackToSystemDefault)) }
            Section("Configuration") { Button("Reload Configuration") { module.reloadConfig() }; if let diagnostic = module.configDiagnostic { Text(diagnostic).foregroundStyle(.red) } }
        }.formStyle(.grouped).onAppear { module.refreshDevices(); module.refreshLocalesAndAssets(); reloadLists() }
          .onDisappear {
              apply(transaction.cancelAll())
              module.cancelVoiceBindingCapture()
              active = nil
          }
    }

    private func bindingRow(action: VoiceBindingAction, index: Int, binding: ShortcutDTO) -> some View {
        VoiceBindingRecorder(title: "Binding \(index + 1)", action: action, value: binding, isManaged: isManaged(action),
            isRecording: active?.action == action && active?.index == index,
            isOtherBindingBusy: active != nil && !(active?.action == action && active?.index == index),
            begin: { begin(action, index) }, cancel: {
                if let token = active?.token { finishCapture(token, committed: false) }
            },
            commit: { value in
                guard let token = active?.token else { return "This capture is no longer active." }
                var candidate = lists[action] ?? []; candidate[index] = value
                if value == .unbound { candidate.remove(at: index) }
                let diagnostic = await module.commitVoiceBindings(candidate, action: action)
                if diagnostic == nil { lists[action] = candidate }
                finishCapture(token, committed: diagnostic == nil)
                return diagnostic
            }, didCommit: { _ in })
    }

    private func begin(_ action: VoiceBindingAction, _ index: Int, rollback: VoiceBindingCaptureTransaction.Rollback? = nil) {
        let token = module.acquireVoiceBindingCapture()
        transaction.begin(token: token, rollback: rollback)
        active = Row(action: action, index: index, token: token)
    }
    private func finishCapture(_ token: VoiceBindingCaptureLease.Token, committed: Bool) {
        guard transaction.token == token else { return }
        apply(transaction.conclude(token: token, committed: committed))
        module.releaseVoiceBindingCapture(token)
        active = nil
    }
    private func apply(_ rollback: VoiceBindingCaptureTransaction.Rollback?) {
        if let rollback { lists[rollback.action] = rollback.bindings }
    }
    private func add(_ action: VoiceBindingAction) {
        let previous = lists[action] ?? []
        var values = previous; values.append(.unbound); lists[action] = values
        begin(action, values.count - 1, rollback: .init(action: action, bindings: previous))
    }
    private func remove(_ action: VoiceBindingAction, _ index: Int) { var values = lists[action] ?? []; values.remove(at: index); commit(values, action) }
    private func move(_ action: VoiceBindingAction, _ index: Int, _ delta: Int) { var values = lists[action] ?? []; values.swapAt(index, index + delta); commit(values, action) }
    private func commit(_ values: [ShortcutDTO], _ action: VoiceBindingAction) { Task { if await module.commitVoiceBindings(values, action: action) == nil { lists[action] = values } } }
    private func reloadLists() { for action in VoiceBindingAction.all { lists[action] = module.effectiveVoiceBindings(for: action) } }
    private func isManaged(_ action: VoiceBindingAction) -> Bool { module.managedKeys.contains(action.managedKey) }
}

extension VoiceBindingAction: Hashable {
    static let all: [Self] = [.holdToTalk, .toggleRecording, .cancel]
    var title: String { switch self { case .holdToTalk: "Hold to talk"; case .toggleRecording: "Toggle recording"; case .cancel: "Cancel" } }
    var managedKey: EffectiveSettings.Key { switch self { case .holdToTalk: .holdToTalkShortcut; case .toggleRecording: .toggleRecordingShortcut; case .cancel: .cancelShortcut } }
}
