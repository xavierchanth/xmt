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
            return try await self.performReload()
        }
        reloadTail = Task { _ = try? await operation.value }
        return try await operation.value
    }

    private func performReload() async throws -> ConfigLoadResult {
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

        let next = EffectiveSettings.resolve(config: candidate, local: local, builtIn: builtIn)
        let voiceBindings: [(String, ShortcutDTO, VoiceBindingAction)] = [
            ("voice.holdToTalkShortcut", next.holdToTalkShortcut.value, .holdToTalk),
            ("voice.toggleRecordingShortcut", next.toggleRecordingShortcut.value, .toggleRecording),
            ("voice.cancelShortcut", next.cancelShortcut.value, .cancel)
        ]
        for (path, binding, action) in voiceBindings {
            if let issue = VoiceBindingPolicy.validate(binding, for: action) {
                let reason = issue == .modifierOnlyRequiresHold ? "Fn modifier-only is supported only for hold-to-talk" : "an unmodified key is unsafe for this action"
                let diagnostic = ConfigDiagnostic.invalidValue(path: path, reason: reason)
                lastDiagnostic = diagnostic; throw diagnostic
            }
        }
        let bindings: [(String, ShortcutDTO)] = [
            ("windowMover.shortcut", next.windowMoverShortcut.value),
            ("voice.holdToTalkShortcut", next.holdToTalkShortcut.value),
            ("voice.toggleRecordingShortcut", next.toggleRecordingShortcut.value),
            ("voice.cancelShortcut", next.cancelShortcut.value),
            ("voice.pasteLatestTranscriptShortcut", next.pasteLatestTranscriptShortcut.value)
        ]
        for left in bindings.indices {
            for right in bindings.indices where right > left && bindings[left].1.conflicts(with: bindings[right].1) {
                let diagnostic = ConfigDiagnostic.invalidValue(path: bindings[left].0, reason: "conflicts with \(bindings[right].0)")
                lastDiagnostic = diagnostic
                throw diagnostic
            }
        }
        let result = ConfigLoadResult(effective: next, changedKeys: next.changedKeys(from: effective))
        effective = next
        lastDiagnostic = nil
        for callback in applyCallbacks { await callback(result) }
        return result
    }
}
