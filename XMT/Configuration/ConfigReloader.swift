import Foundation

struct ConfigLoadResult: Sendable {
    let effective: EffectiveSettings
    let changedKeys: Set<EffectiveSettings.Key>
}

/// An explicitly driven loader. It owns no timer, watcher, singleton, or global state.
actor ConfigReloader {
    /// Apply callbacks are part of serialized publication and must not recursively
    /// await `reload()`; doing so would wait on their own publication and deadlock.
    typealias Apply = @Sendable (ConfigLoadResult) async -> Void
    typealias BeforePublish = @Sendable (ConfigLoadResult) async throws -> Void

    let url: URL
    private var local: SettingsValues
    private let builtIn: BuiltInSettings
    private let includesVoiceBindings: Bool
    private let read: @Sendable (URL) throws -> Data
    private var applyCallbacks: [Apply] = []
    private var reloadTail: Task<Void, Never>?
    private(set) var effective: EffectiveSettings
    private(set) var lastDiagnostic: ConfigDiagnostic?

    init(url: URL = ConfigFile.defaultURL(), local: SettingsValues = .init(),
         builtIn: BuiltInSettings = .standard,
         includesVoiceBindings: Bool = true,
         read: @escaping @Sendable (URL) throws -> Data = { try Data(contentsOf: $0) }) {
        self.url = url
        self.local = local
        self.builtIn = builtIn
        self.includesVoiceBindings = includesVoiceBindings
        self.read = read
        self.effective = EffectiveSettings.resolve(config: nil, local: local, builtIn: builtIn)
    }

    func addApplyCallback(_ callback: @escaping Apply) { applyCallbacks.append(callback) }

    /// Replaces the persisted/UI baseline used by subsequent reloads.
    func updateLocal(_ values: SettingsValues) { local = values }

    /// Calls are serialized through publication, including asynchronous callbacks. Thus
    /// actor reentrancy cannot publish B while callbacks for A are still running.
    @discardableResult
    func reload() async throws -> ConfigLoadResult {
        let previous = reloadTail
        let operation = Task { [weak self] () throws -> ConfigLoadResult in
            await previous?.value
            guard let self else { throw CancellationError() }
            return try await self.performReload(using: self.local, commitLocal: false,
                                                requiringUnmanaged: [], beforePublish: nil)
        }
        reloadTail = Task { _ = try? await operation.value }
        return try await operation.value
    }

    /// Validates a proposed local snapshot against the current file and publishes both only on success.
    /// Failed staging leaves the prior local baseline, effective snapshot, callbacks, and live handlers untouched.
    func stageAndReload(local staged: SettingsValues,
                        requiringUnmanaged actions: [VoiceBindingAction] = [],
                        beforePublish: BeforePublish? = nil) async throws -> ConfigLoadResult {
        let previous = reloadTail
        let operation = Task { [weak self] () throws -> ConfigLoadResult in
            await previous?.value
            guard let self else { throw CancellationError() }
            return try await self.performReload(using: staged, commitLocal: true,
                                                requiringUnmanaged: actions, beforePublish: beforePublish)
        }
        reloadTail = Task { _ = try? await operation.value }
        return try await operation.value
    }

    private func performReload(using localCandidate: SettingsValues, commitLocal: Bool,
                               requiringUnmanaged actions: [VoiceBindingAction],
                               beforePublish: BeforePublish?) async throws -> ConfigLoadResult {
        let candidate: ConfigFile?
        do {
            candidate = try ConfigFile.decode(read(url))
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            candidate = nil
        } catch let error as ConfigDiagnostic {
            lastDiagnostic = error
            throw error
        } catch {
            let diagnostic = ConfigDiagnostic.unreadable(String(describing: error))
            lastDiagnostic = diagnostic
            throw diagnostic
        }

        let next = EffectiveSettings.resolve(config: candidate, local: localCandidate, builtIn: builtIn)
        try localCandidate.keyboardCustomization?.validate()
        _ = try KeyboardProductPolicyCompiler.compile(next.keyboardCustomization, revision: KeyboardPolicyRevision(1)!)
        for action in actions {
            let resolved: ResolvedSetting<ShortcutDTO>
            switch action { case .holdToTalk: resolved = next.holdToTalkShortcut; case .toggleRecording: resolved = next.toggleRecordingShortcut; case .cancel: resolved = next.cancelShortcut }
            if resolved.isManaged {
                let path = action == .holdToTalk ? "voice.holdToTalkShortcut" : action == .toggleRecording ? "voice.toggleRecordingShortcut" : "voice.cancelShortcut"
                let diagnostic = ConfigDiagnostic.invalidValue(path: path, reason: "is managed by configuration")
                lastDiagnostic = diagnostic; throw diagnostic
            }
        }
        // Validate the complete resolved snapshot, not merely the first binding or
        // arrays physically present in the config file. Local and built-in secondary
        // bindings participate in the same safety and overlap rules.
        let groups: [(String, ResolvedSetting<[ShortcutDTO]>, VoiceBindingAction, Bool)] = [
            ("voice.holdToTalkBindings", next.holdToTalkBindings, .holdToTalk, candidate?.voice.holdToTalkBindings != nil || localCandidate.holdToTalkBindings != nil),
            ("voice.toggleRecordingBindings", next.toggleRecordingBindings, .toggleRecording, candidate?.voice.toggleRecordingBindings != nil || localCandidate.toggleRecordingBindings != nil),
            ("voice.cancelBindings", next.cancelBindings, .cancel, candidate?.voice.cancelBindings != nil || localCandidate.cancelBindings != nil)
        ]
        var located: [VoiceBindingPolicy.LocatedBinding] = []
        for (base, resolved, action, usesArrayPath) in groups {
            if resolved.value.count > VoiceBindingPersistence.maximumBindingsPerAction {
                let diagnostic = ConfigDiagnostic.invalidValue(path: base, reason: "supports at most \(VoiceBindingPersistence.maximumBindingsPerAction) bindings")
                lastDiagnostic = diagnostic; throw diagnostic
            }
            for (index, binding) in resolved.value.enumerated() {
                let path = usesArrayPath ? "\(base)[\(index)]" : base.replacingOccurrences(of: "Bindings", with: "Shortcut")
                if let issue = VoiceBindingPolicy.validate(binding, for: action) {
                    let reason = issue == .modifierOnlyRequiresHold ? "Fn modifier-only is supported only for hold-to-talk" : "requires Control, Option, or Command; Shift alone is unsafe"
                    let diagnostic = ConfigDiagnostic.invalidValue(path: path, reason: reason)
                    lastDiagnostic = diagnostic; throw diagnostic
                }
                do { try binding.validate() } catch {
                    let diagnostic = ConfigDiagnostic.invalidValue(path: path, reason: String(describing: error))
                    lastDiagnostic = diagnostic; throw diagnostic
                }
                located.append(.init(path: path, action: action, binding: binding))
            }
        }
        var allBindings: [(String, ShortcutDTO)] = [("windowMover.shortcut", next.windowMoverShortcut.value)]
        if includesVoiceBindings {
            allBindings += located.map { ($0.path, $0.binding) }
            allBindings.append(("voice.pasteLatestTranscriptShortcut", next.pasteLatestTranscriptShortcut.value))
        }
        for later in allBindings.indices {
            for earlier in 0..<later where allBindings[later].1.conflicts(with: allBindings[earlier].1) {
                let diagnostic = ConfigDiagnostic.invalidValue(path: allBindings[later].0, reason: "conflicts with \(allBindings[earlier].0)")
                lastDiagnostic = diagnostic; throw diagnostic
            }
        }
        let result = ConfigLoadResult(effective: next, changedKeys: next.changedKeys(from: effective))
        if let beforePublish { try await beforePublish(result) }
        if commitLocal { local = localCandidate }
        effective = next
        lastDiagnostic = nil
        for callback in applyCallbacks { await callback(result) }
        return result
    }
}
