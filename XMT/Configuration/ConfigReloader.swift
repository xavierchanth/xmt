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

    let url: URL
    private var local: SettingsValues
    private let builtIn: BuiltInSettings
    private let read: @Sendable (URL) throws -> Data
    private var applyCallbacks: [Apply] = []
    private var reloadTail: Task<Void, Never>?
    private(set) var effective: EffectiveSettings
    private(set) var lastDiagnostic: ConfigDiagnostic?

    init(url: URL = ConfigFile.defaultURL(), local: SettingsValues = .init(),
         builtIn: BuiltInSettings = .standard,
         read: @escaping @Sendable (URL) throws -> Data = { try Data(contentsOf: $0) }) {
        self.url = url
        self.local = local
        self.builtIn = builtIn
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
            return try await self.performReload(using: self.local, commitLocal: false, requiringUnmanaged: nil)
        }
        reloadTail = Task { _ = try? await operation.value }
        return try await operation.value
    }

    /// Validates a proposed local snapshot against the current file and publishes both only on success.
    /// Failed staging leaves the prior local baseline, effective snapshot, callbacks, and live handlers untouched.
    func stageAndReload(local staged: SettingsValues, requiringUnmanaged action: VoiceBindingAction? = nil) async throws -> ConfigLoadResult {
        let previous = reloadTail
        let operation = Task { [weak self] () throws -> ConfigLoadResult in
            await previous?.value
            guard let self else { throw CancellationError() }
            return try await self.performReload(using: staged, commitLocal: true, requiringUnmanaged: action)
        }
        reloadTail = Task { _ = try? await operation.value }
        return try await operation.value
    }

    private func performReload(using localCandidate: SettingsValues, commitLocal: Bool, requiringUnmanaged action: VoiceBindingAction?) async throws -> ConfigLoadResult {
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
        if let action {
            let resolved: ResolvedSetting<ShortcutDTO>
            switch action { case .holdToTalk: resolved = next.holdToTalkShortcut; case .toggleRecording: resolved = next.toggleRecordingShortcut; case .cancel: resolved = next.cancelShortcut }
            if resolved.isManaged {
                let path = action == .holdToTalk ? "voice.holdToTalkShortcut" : action == .toggleRecording ? "voice.toggleRecordingShortcut" : "voice.cancelShortcut"
                let diagnostic = ConfigDiagnostic.invalidValue(path: path, reason: "is managed by configuration")
                lastDiagnostic = diagnostic; throw diagnostic
            }
        }
        let voiceBindings: [(String, ShortcutDTO, VoiceBindingAction)] = [
            ("voice.holdToTalkShortcut", next.holdToTalkShortcut.value, .holdToTalk),
            ("voice.toggleRecordingShortcut", next.toggleRecordingShortcut.value, .toggleRecording),
            ("voice.cancelShortcut", next.cancelShortcut.value, .cancel)
        ]
        for (path, binding, action) in voiceBindings {
            if let issue = VoiceBindingPolicy.validate(binding, for: action) {
                let reason = issue == .modifierOnlyRequiresHold ? "Fn modifier-only is supported only for hold-to-talk" : "requires Control, Option, or Command; Shift alone is unsafe"
                let diagnostic = ConfigDiagnostic.invalidValue(path: path, reason: reason)
                lastDiagnostic = diagnostic; throw diagnostic
            }
        }
        var bindings: [(String, ShortcutDTO)] = [("windowMover.shortcut", next.windowMoverShortcut.value)]
        func append(_ canonical: [ShortcutDTO]?, effective: ShortcutDTO, path: String) {
            if let canonical {
                bindings += canonical.enumerated().map { ("\(path)[\($0.offset)]", $0.element) }
            } else { bindings.append((path.replacingOccurrences(of: "Bindings", with: "Shortcut"), effective)) }
        }
        append(candidate?.voice.holdToTalkBindings, effective: next.holdToTalkShortcut.value, path: "voice.holdToTalkBindings")
        append(candidate?.voice.toggleRecordingBindings, effective: next.toggleRecordingShortcut.value, path: "voice.toggleRecordingBindings")
        append(candidate?.voice.cancelBindings, effective: next.cancelShortcut.value, path: "voice.cancelBindings")
        bindings.append(("voice.pasteLatestTranscriptShortcut", next.pasteLatestTranscriptShortcut.value))
        for left in bindings.indices {
            for right in bindings.indices where right > left && bindings[left].1.conflicts(with: bindings[right].1) {
                let diagnostic = ConfigDiagnostic.invalidValue(path: bindings[left].0, reason: "conflicts with \(bindings[right].0)")
                lastDiagnostic = diagnostic
                throw diagnostic
            }
        }
        let result = ConfigLoadResult(effective: next, changedKeys: next.changedKeys(from: effective))
        if commitLocal { local = localCandidate }
        effective = next
        lastDiagnostic = nil
        for callback in applyCallbacks { await callback(result) }
        return result
    }
}
