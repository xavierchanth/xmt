import KeyboardShortcuts
import SwiftUI

struct VoiceSettingsView: View {
    @ObservedObject private var module = VoiceTranscriptionModule.shared
    @ObservedObject private var configuration = ConfigurationCoordinator.shared
    @State private var lists: [VoiceBindingAction: [ShortcutDTO]] = [:]
    @State private var active: Row?
    @State private var transaction = VoiceBindingCaptureTransaction()
    @State private var showingDefaultBindingConfirmation = false
    @State private var isRestoringDefaultBindings = false
    @State private var defaultBindingRestoreError: String?

    private struct Row: Equatable {
        let action: VoiceBindingAction
        let index: Int
        let token: VoiceBindingCaptureLease.Token
        let settingsRevision: UInt64
    }

    var body: some View {
        Form {
            Section {
                Toggle("Enable Voice Transcription", isOn: $module.isEnabled).disabled(module.managedKeys.contains(.voiceEnabled))
                Text("Each action can have several standard or Fn bindings.").font(.footnote).foregroundStyle(.secondary)
            }
            Section("Voice bindings") {
                ForEach(VoiceBindingAction.allCases, id: \.self) { action in
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
                Text("Escape, Control–Escape, and Fn–Escape are bindable. Use the on-screen Cancel button to stop capture.").font(.footnote).foregroundStyle(.secondary)
                Button("Restore Default Bindings", role: .destructive) {
                    showingDefaultBindingConfirmation = true
                }
                .disabled(module.hasManagedVoiceBindings || active != nil || isRestoringDefaultBindings)
                Text("Validates and publishes Hold to Talk as Fn, Toggle Recording as Fn–Space, and Cancel as Fn–Escape together. Disabled when any Voice binding list is managed by configuration.")
                    .font(.footnote).foregroundStyle(.secondary)
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
                KeyboardShortcuts.Recorder("Paste latest transcript:", name: .pasteLatestTranscript, onChange: { configuration.userChangedVoicePasteLatestShortcut($0) }).disabled(module.managedKeys.contains(.pasteLatestTranscriptShortcut))
            }
            Section("Transcript history") {
                Toggle("Save transcript history", isOn: $module.historyEnabled).disabled(module.managedKeys.contains(.historyEnabled))
                TextField("Retention (days)", value: $module.historyRetentionDays, format: .number).disabled(!module.historyEnabled || module.managedKeys.contains(.historyRetentionDays))
                TextField("Maximum entries", value: $module.historyMaxEntries, format: .number).disabled(!module.historyEnabled || module.managedKeys.contains(.historyMaxEntries))
            }
            Section("Input priority") { DevicePriorityListView(module: module, priorityManaged: module.managedKeys.contains(.inputDevicePriority), fallbackManaged: module.managedKeys.contains(.fallbackToSystemDefault)) }
            Section("Configuration") { Button("Reload Configuration") { configuration.reload() }; if let diagnostic = configuration.diagnostic { Text(diagnostic).foregroundStyle(.red) } }
        }.formStyle(.grouped).onAppear { module.refreshDevices(); module.refreshLocalesAndAssets(); reloadLists() }
          .onChange(of: module.settingsRevision) { reloadLists(invalidatingCaptureFor: module.settingsRevision) }
          .alert("Restore Default Bindings?", isPresented: $showingDefaultBindingConfirmation) {
              Button("Cancel", role: .cancel) {}
              Button("Restore", role: .destructive) { restoreDefaultBindings() }
                  .disabled(module.hasManagedVoiceBindings)
          } message: {
              Text("After validating the complete replacement, XMT publishes all three Voice binding lists together. No other setting is changed. Preferences storage is not a crash-safe transaction.")
          }
          .alert(
              "Couldn’t Restore Default Bindings",
              isPresented: Binding(
                  get: { defaultBindingRestoreError != nil },
                  set: { if !$0 { defaultBindingRestoreError = nil } }
              )
          ) {
              Button("OK", role: .cancel) {}
          } message: {
              Text(defaultBindingRestoreError ?? "The customized bindings were preserved.")
          }
          .onDisappear {
              apply(transaction.cancelAll())
              module.cancelVoiceBindingCapture()
              active = nil
          }
    }

    private func bindingRow(action: VoiceBindingAction, index: Int, binding: ShortcutDTO) -> some View {
        let isThisRowActive = active?.action == action && active?.index == index
        return VoiceBindingRecorder(title: "Binding \(index + 1)", action: action, value: binding, isManaged: isManaged(action),
            isRecording: isThisRowActive,
            isOtherBindingBusy: active != nil && !isThisRowActive,
            captureToken: isThisRowActive ? active?.token : nil,
            begin: { begin(action, index) }, cancel: {
                guard let row = active, row.action == action, row.index == index else { return }
                finishCapture(row.token, committed: false)
            },
            commit: { value, token in
                await commitCaptured(value, action: action, index: index, token: token)
            }, didCommit: { _ in })
    }

    private func begin(_ action: VoiceBindingAction, _ index: Int,
                       rollback: VoiceBindingCaptureTransaction.Rollback? = nil) -> VoiceBindingCaptureLease.Token {
        let token = module.acquireVoiceBindingCapture()
        let revision = module.settingsRevision
        transaction.begin(token: token, action: action, index: index,
                          settingsRevision: revision, rollback: rollback)
        active = Row(action: action, index: index, token: token, settingsRevision: revision)
        return token
    }

    private func commitCaptured(_ value: ShortcutDTO, action: VoiceBindingAction, index: Int,
                                token: VoiceBindingCaptureLease.Token) async -> String? {
        guard let row = active,
              row.action == action, row.index == index, row.token == token,
              row.settingsRevision == module.settingsRevision else {
            return VoiceBindingCaptureTransaction.Rejection.staleCapture.diagnostic
        }
        let values = lists[action] ?? []
        if let rejection = transaction.claimCommit(
            token: token, action: action, index: index,
            currentSettingsRevision: module.settingsRevision, bindingCount: values.count
        ) {
            return rejection.diagnostic
        }

        // `claimCommit` proves this index belongs to this exact action/token/revision snapshot.
        // Keep the actual mutation conditional too, so this effect boundary remains trap-free.
        guard values.indices.contains(index) else {
            return VoiceBindingCaptureTransaction.Rejection.bindingNoLongerExists.diagnostic
        }
        var candidate = values
        candidate[index] = value
        if value == .unbound { candidate.remove(at: index) }
        let diagnostic = await module.commitVoiceBindings(candidate, action: action)

        guard transaction.acceptsCompletion(
            token: token, action: action, index: index,
            currentSettingsRevision: module.settingsRevision
        ) else {
            // A successful commit publishes a new revision itself; onChange reloads its accepted
            // value. Any other late completion is deliberately unable to mutate current UI state.
            return diagnostic ?? (module.effectiveVoiceBindings(for: action) == candidate
                ? nil : VoiceBindingCaptureTransaction.Rejection.staleCapture.diagnostic)
        }
        if diagnostic == nil { lists[action] = candidate }
        finishCapture(token, committed: diagnostic == nil)
        return diagnostic
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
        _ = begin(action, values.count - 1, rollback: .init(action: action, bindings: previous))
    }
    private func remove(_ action: VoiceBindingAction, _ index: Int) {
        var values = lists[action] ?? []
        guard values.indices.contains(index) else { return }
        values.remove(at: index)
        commit(values, action)
    }
    private func move(_ action: VoiceBindingAction, _ index: Int, _ delta: Int) {
        var values = lists[action] ?? []
        let destination = index + delta
        guard values.indices.contains(index), values.indices.contains(destination) else { return }
        values.swapAt(index, destination)
        commit(values, action)
    }
    private func commit(_ values: [ShortcutDTO], _ action: VoiceBindingAction) { Task { if await module.commitVoiceBindings(values, action: action) == nil { lists[action] = values } } }
    private func restoreDefaultBindings() {
        guard !module.hasManagedVoiceBindings, !isRestoringDefaultBindings else { return }
        isRestoringDefaultBindings = true
        Task { @MainActor in
            defaultBindingRestoreError = await module.restoreDefaultBindings()
            isRestoringDefaultBindings = false
        }
    }
    private func reloadLists(invalidatingCaptureFor revision: UInt64? = nil) {
        if let revision, transaction.target != nil {
            apply(transaction.invalidate(ifSettingsRevisionDiffers: revision))
            module.cancelVoiceBindingCapture()
            active = nil
        }
        for action in VoiceBindingAction.allCases {
            lists[action] = module.effectiveVoiceBindings(for: action)
        }
    }
    private func isManaged(_ action: VoiceBindingAction) -> Bool { module.managedKeys.contains(action.managedKey) }
}

extension VoiceBindingAction {
    var title: String { switch self { case .holdToTalk: "Hold to talk"; case .toggleRecording: "Toggle recording"; case .cancel: "Cancel" } }
}
