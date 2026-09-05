import Foundation

/// Pure state machine preventing structural menu updates during AppKit tracking.
struct MenuUpdateDeferralPolicy: Equatable {
    private(set) var isTracking = false
    private(set) var hasDeferredUpdate = false

    mutating func beginTracking() { isTracking = true }

    /// Returns true when the caller may update menu structure immediately.
    mutating func requestUpdate() -> Bool {
        guard !isTracking else { hasDeferredUpdate = true; return false }
        return true
    }

    /// Returns true when one or more requests accumulated while tracking.
    mutating func endTracking() -> Bool {
        isTracking = false
        defer { hasDeferredUpdate = false }
        return hasDeferredUpdate
    }
}

enum VoiceOutputMode: String, Codable, CaseIterable, Equatable, Sendable { case pasteImmediately, clipboardOnly }

enum VoiceBindingAction: String, CaseIterable, Equatable, Hashable, Sendable {
    case holdToTalk, toggleRecording, cancel

    var managedKey: EffectiveSettings.Key {
        switch self {
        case .holdToTalk: .holdToTalkShortcut
        case .toggleRecording: .toggleRecordingShortcut
        case .cancel: .cancelShortcut
        }
    }
}

struct VoiceBindingRestorePolicy {
    static func allows(managedKeys: Set<EffectiveSettings.Key>) -> Bool {
        VoiceBindingAction.allCases.allSatisfy { !managedKeys.contains($0.managedKey) }
    }
}

/// Single-owner lease used to keep live triggers disabled throughout capture and commit.
/// Replacing a lease makes every completion carrying the old token harmless.
struct VoiceBindingCaptureLease: Equatable, Sendable {
    struct Token: Equatable, Hashable, Sendable { fileprivate let id: UUID }
    private(set) var token: Token?
    var isActive: Bool { token != nil }

    mutating func acquire() -> Token {
        let next = Token(id: UUID()); token = next; return next
    }
    @discardableResult mutating func release(_ candidate: Token) -> Bool {
        guard token == candidate else { return false }
        token = nil; return true
    }
    @discardableResult mutating func cancelAll() -> Bool {
        let changed = token != nil; token = nil; return changed
    }
}

/// UI-side transaction paired with the routing lease. A newly inserted placeholder
/// is provisional until commit; cancellation/failure restores the exact prior list.
/// The commit claim is synchronous and one-shot. Its complete row identity prevents a
/// callback retained by an old view from indexing a list that has since been reloaded.
struct VoiceBindingCaptureTransaction: Equatable, Sendable {
    struct Rollback: Equatable, Sendable { let action: VoiceBindingAction; let bindings: [ShortcutDTO] }
    struct Target: Equatable, Sendable {
        let action: VoiceBindingAction
        let index: Int
        let settingsRevision: UInt64
    }
    enum Rejection: Equatable, Sendable {
        case staleCapture
        case bindingNoLongerExists

        var diagnostic: String {
            switch self {
            case .staleCapture:
                return "This capture is stale because Voice settings changed. Record the binding again."
            case .bindingNoLongerExists:
                return "This binding no longer exists. Reload Voice settings and record it again."
            }
        }
    }

    private(set) var token: VoiceBindingCaptureLease.Token?
    private(set) var target: Target?
    private(set) var hasClaimedCommit = false
    private var rollback: Rollback?

    // Retained for non-row callers and the rollback-focused domain tests.
    mutating func begin(token: VoiceBindingCaptureLease.Token, rollback: Rollback? = nil) {
        begin(token: token, target: nil, rollback: rollback)
    }

    mutating func begin(token: VoiceBindingCaptureLease.Token, action: VoiceBindingAction,
                        index: Int, settingsRevision: UInt64, rollback: Rollback? = nil) {
        begin(token: token, target: .init(action: action, index: index,
                                         settingsRevision: settingsRevision), rollback: rollback)
    }

    /// Atomically consumes the capture before any asynchronous persistence starts.
    /// Every field is checked before the caller is allowed to subscript its binding list.
    mutating func claimCommit(token candidate: VoiceBindingCaptureLease.Token,
                              action: VoiceBindingAction, index: Int,
                              currentSettingsRevision: UInt64, bindingCount: Int) -> Rejection? {
        guard token == candidate,
              target == .init(action: action, index: index, settingsRevision: currentSettingsRevision),
              !hasClaimedCommit else { return .staleCapture }
        guard index >= 0, index < bindingCount else { return .bindingNoLongerExists }
        hasClaimedCommit = true
        return nil
    }

    func acceptsCompletion(token candidate: VoiceBindingCaptureLease.Token,
                           action: VoiceBindingAction, index: Int,
                           currentSettingsRevision: UInt64) -> Bool {
        token == candidate && hasClaimedCommit
            && target == .init(action: action, index: index,
                               settingsRevision: currentSettingsRevision)
    }

    /// A settings publication is a capture boundary even when the row happens to survive it.
    mutating func invalidate(ifSettingsRevisionDiffers revision: UInt64) -> Rollback? {
        guard let target, target.settingsRevision != revision else { return nil }
        return cancelAll()
    }

    mutating func conclude(token candidate: VoiceBindingCaptureLease.Token, committed: Bool) -> Rollback? {
        guard token == candidate else { return nil }
        let result = committed ? nil : rollback
        reset()
        return result
    }

    mutating func cancelAll() -> Rollback? {
        guard token != nil else { return nil }
        let result = rollback
        reset()
        return result
    }

    private mutating func begin(token: VoiceBindingCaptureLease.Token, target: Target?, rollback: Rollback?) {
        self.token = token
        self.target = target
        self.rollback = rollback
        hasClaimedCommit = false
    }

    private mutating func reset() {
        token = nil
        target = nil
        rollback = nil
        hasClaimedCommit = false
    }
}
enum VoiceBindingPolicyError: Error, Equatable, Sendable { case modifierOnlyRequiresHold; case unsafeUnmodifiedKey }
struct VoiceBindingPolicy {
    struct LocatedBinding: Equatable, Sendable {
        let path: String
        let action: VoiceBindingAction
        let binding: ShortcutDTO
    }

    /// Returns the later entry involved in the first overlap. Keeping this policy
    /// pure makes duplicate-within-action and cross-action behavior deterministic.
    static func firstOverlap(in bindings: [LocatedBinding]) -> (later: String, earlier: String)? {
        for later in bindings.indices {
            for earlier in 0..<later where bindings[later].binding.conflicts(with: bindings[earlier].binding) {
                return (bindings[later].path, bindings[earlier].path)
            }
        }
        return nil
    }

    static func validate(_ binding: ShortcutDTO, for action: VoiceBindingAction) -> VoiceBindingPolicyError? {
        switch binding {
        case .unbound: return nil
        case .modifierHold: return action == .holdToTalk ? nil : .modifierOnlyRequiresHold
        case .fnChord: return nil
        case .key(_, let modifiers):
            let safe = Set(modifiers.map { $0.lowercased() }).isDisjoint(with: ["control", "option", "command"]) == false
            return action != .cancel && !safe ? .unsafeUnmodifiedKey : nil
        }
    }
}

struct VoiceBindingPersistence {
    /// A fixed bank keeps KeyboardShortcuts registrations stable across launches.
    static let maximumBindingsPerAction = 8

    /// Canonical storage is an ordered array. During the one-release migration,
    /// scalar canonical data and the former KeyboardShortcuts value remain readable.
    static func localBindings(explicit: Bool, canonicalData: Data?, legacyValue: ShortcutDTO?) -> [ShortcutDTO]? {
        guard explicit else { return nil }
        if let canonicalData {
            if let values = try? JSONDecoder().decode([ShortcutDTO].self, from: canonicalData) { return values }
            if let value = try? JSONDecoder().decode(ShortcutDTO.self, from: canonicalData) { return [value] }
        }
        return legacyValue.map { [$0] } ?? []
    }

    static func localValue(explicit: Bool, canonicalData: Data?, legacyValue: ShortcutDTO?) -> ShortcutDTO? {
        guard let bindings = localBindings(explicit: explicit, canonicalData: canonicalData, legacyValue: legacyValue) else { return nil }
        return bindings.first ?? .unbound
    }

    /// The single migration boundary for managed-value backups. Both the former
    /// scalar encoding and the canonical array encoding are accepted on restore.
    static func saveManagedBackup(_ bindings: [ShortcutDTO]?, in defaults: UserDefaults, key: String) {
        let activeKey = "\(key).backupActive", dataKey = "\(key).backup"
        defaults.set(true, forKey: activeKey)
        defaults.removeObject(forKey: dataKey) // never retain an older backup for nil
        if let bindings, let data = try? JSONEncoder().encode(bindings) { defaults.set(data, forKey: dataKey) }
    }

    static func restoreManagedBackup(in defaults: UserDefaults, key: String) -> [ShortcutDTO]? {
        let activeKey = "\(key).backupActive", dataKey = "\(key).backup"
        guard defaults.bool(forKey: activeKey) else {
            defaults.removeObject(forKey: dataKey) // clean up stale, inactive migration data
            return nil
        }
        let data = defaults.data(forKey: dataKey)
        let restored = data.flatMap { localBindings(explicit: true, canonicalData: $0, legacyValue: nil) }
        defaults.removeObject(forKey: dataKey)
        defaults.removeObject(forKey: activeKey)
        return restored
    }
}

struct VoiceBindingRecorderModel: Equatable, Sendable {
    enum Input: Equatable, Sendable {
        case begin(VoiceBindingAction), captured(VoiceBindingAction, ShortcutDTO)
        case cancel(VoiceBindingAction), clear(VoiceBindingAction), selectFn
    }
    private(set) var activeAction: VoiceBindingAction?
    private(set) var pendingCommit: (action: VoiceBindingAction, binding: ShortcutDTO)?
    static func == (left: Self, right: Self) -> Bool {
        left.activeAction == right.activeAction && left.pendingCommit?.action == right.pendingCommit?.action && left.pendingCommit?.binding == right.pendingCommit?.binding
    }
    mutating func receive(_ input: Input) {
        pendingCommit = nil
        switch input {
        case .begin(let action): activeAction = action // replaces/cancels any other row
        case .captured(let action, let value) where activeAction == action:
            pendingCommit = (action, value); activeAction = nil
        case .cancel(let action) where activeAction == action: activeAction = nil
        case .clear(let action): activeAction = nil; pendingCommit = (action, .unbound)
        case .selectFn: activeAction = nil; pendingCommit = (.holdToTalk, .modifierHold("fn"))
        default: break
        }
    }
}

enum VoiceInteractionPhase: Equatable, Sendable { case unavailable, idle, arming, recording, finalizing }

struct VoiceShortcutActivationPolicy: Equatable, Sendable {
    let holdEnabled: Bool
    let toggleEnabled: Bool
    let cancelEnabled: Bool

    static func decide(moduleEnabled: Bool, phase: VoiceInteractionPhase) -> Self {
        guard moduleEnabled else { return .init(holdEnabled: false, toggleEnabled: false, cancelEnabled: false) }
        let recordingTriggerEnabled = phase == .idle || phase == .arming || phase == .recording
        return .init(holdEnabled: recordingTriggerEnabled, toggleEnabled: recordingTriggerEnabled,
                     cancelEnabled: phase == .arming || phase == .recording)
    }
}

struct VoicePartialUpdatePolicy {
    static func allows(capturedLifecycle: UInt64, currentLifecycle: UInt64,
                       expectedSession: UUID, currentRecordingSession: UUID?) -> Bool {
        capturedLifecycle == currentLifecycle && expectedSession == currentRecordingSession
    }
}

enum VoiceTeardownReason: Equatable, Sendable { case lifecycleStop, privacyCancellation }
struct VoiceTeardownPolicy {
    static func shouldPromoteRecovery(for reason: VoiceTeardownReason) -> Bool { reason == .lifecycleStop }
}

struct VoiceOverlayPolicy: Equatable, Sendable {
    enum Presentation: Equatable, Sendable { case hidden, arming, recording, finalizing }
    static func presentation(for phase: VoiceInteractionPhase) -> Presentation {
        switch phase { case .unavailable, .idle: return .hidden; case .arming: return .arming; case .recording: return .recording; case .finalizing: return .finalizing }
    }
    static func controls(for phase: VoiceInteractionPhase) -> (stop: Bool, cancel: Bool) {
        (phase == .recording, phase == .arming || phase == .recording)
    }
}

enum SettingSource: String, Equatable, Sendable { case builtIn, local, configFile }

struct ResolvedSetting<Value: Equatable & Sendable>: Equatable, Sendable {
    let value: Value
    let source: SettingSource
    var isManaged: Bool { source == .configFile }
}

/// Canonical local preference keys and the one-release migration from the
/// former one-slot retention preference.
enum VoiceHistoryPreferences {
    static let enabledKey = "voice.history.enabled"
    static let retentionDaysKey = "voice.history.retentionDays"
    static let maxEntriesKey = "voice.history.maxEntries"
    static let legacyKeepLastTranscriptKey = "voice.keepLastTranscript"

    static let registeredDefaults: [String: Any] = [
        enabledKey: true,
        retentionDaysKey: 30,
        maxEntriesKey: 500
    ]

    /// Canonical data always wins if an interrupted/older migration left both
    /// keys behind. Removing the alias makes repeated calls a no-op.
    static func migrate(in defaults: UserDefaults) {
        guard let legacy = defaults.object(forKey: legacyKeepLastTranscriptKey) else { return }
        if defaults.object(forKey: enabledKey) == nil {
            defaults.set((legacy as? NSNumber)?.boolValue ?? true, forKey: enabledKey)
        }
        defaults.removeObject(forKey: legacyKeepLastTranscriptKey)
    }
}

/// Persisted/UI values are partial by definition.
struct SettingsValues: Equatable, Sendable {
    var keyboardCustomization: KeyboardCustomizationDTO? = nil
    var windowMoverEnabled: Bool? = nil
    var windowMoverShortcut: ShortcutDTO? = nil
    var voiceEnabled: Bool? = nil
    var holdToTalkShortcut: ShortcutDTO? = nil
    var toggleRecordingShortcut: ShortcutDTO? = nil
    var cancelShortcut: ShortcutDTO? = nil
    var holdToTalkBindings: [ShortcutDTO]? = nil
    var toggleRecordingBindings: [ShortcutDTO]? = nil
    var cancelBindings: [ShortcutDTO]? = nil
    var pasteLatestTranscriptShortcut: ShortcutDTO? = nil
    var outputMode: VoiceOutputMode? = nil
    var autoPaste: Bool? = nil
    var historyEnabled: Bool? = nil
    var historyRetentionDays: Int? = nil
    var historyMaxEntries: Int? = nil
    var locale: String? = nil
    var fnHoldThresholdMs: Int? = nil
    var maxSessionSeconds: Int? = nil
    var inputDevicePriority: [InputDeviceDTO]? = nil
    var fallbackToSystemDefault: Bool? = nil

    /// Replaces exactly the three canonical Voice binding lists, retaining every
    /// other local value (including read-only migration aliases) byte-for-byte.
    func restoringDefaultVoiceBindings(_ builtIn: BuiltInSettings = .standard) -> Self {
        var candidate = self
        candidate.holdToTalkBindings = builtIn.holdToTalkBindings
        candidate.toggleRecordingBindings = builtIn.toggleRecordingBindings
        candidate.cancelBindings = builtIn.cancelBindings
        return candidate
    }
}

/// Compile-time defaults are complete, making resolution total and trap-free.
struct BuiltInSettings: Equatable, Sendable {
    var windowMoverEnabled = true
    var windowMoverShortcut: ShortcutDTO = .key(key: "space", modifiers: ["option"])
    var voiceEnabled = true
    var holdToTalkBindings: [ShortcutDTO] = [.modifierHold("fn")]
    var toggleRecordingBindings: [ShortcutDTO] = [.fnChord(key: "space")]
    var cancelBindings: [ShortcutDTO] = [.fnChord(key: "escape")]
    var holdToTalkShortcut: ShortcutDTO { get { holdToTalkBindings.first ?? .unbound } set { holdToTalkBindings = [newValue] } }
    var toggleRecordingShortcut: ShortcutDTO { get { toggleRecordingBindings.first ?? .unbound } set { toggleRecordingBindings = [newValue] } }
    var cancelShortcut: ShortcutDTO { get { cancelBindings.first ?? .unbound } set { cancelBindings = [newValue] } }
    var pasteLatestTranscriptShortcut: ShortcutDTO = .key(key: "v", modifiers: ["control", "command"])
    var outputMode: VoiceOutputMode = .pasteImmediately
    var historyEnabled = true
    var historyRetentionDays = 30
    var historyMaxEntries = 500
    var locale = "system"
    var fnHoldThresholdMs = 150
    var maxSessionSeconds = 300
    var inputDevicePriority: [InputDeviceDTO] = []
    var fallbackToSystemDefault = true

    static let standard = BuiltInSettings()
}

struct EffectiveSettings: Equatable, Sendable {
    let keyboardCustomization: EffectiveKeyboardCustomizationSettings
    let windowMoverEnabled: ResolvedSetting<Bool>
    let windowMoverShortcut: ResolvedSetting<ShortcutDTO>
    let voiceEnabled: ResolvedSetting<Bool>
    let holdToTalkBindings: ResolvedSetting<[ShortcutDTO]>
    let toggleRecordingBindings: ResolvedSetting<[ShortcutDTO]>
    let cancelBindings: ResolvedSetting<[ShortcutDTO]>
    var holdToTalkShortcut: ResolvedSetting<ShortcutDTO> { .init(value: holdToTalkBindings.value.first ?? .unbound, source: holdToTalkBindings.source) }
    var toggleRecordingShortcut: ResolvedSetting<ShortcutDTO> { .init(value: toggleRecordingBindings.value.first ?? .unbound, source: toggleRecordingBindings.source) }
    var cancelShortcut: ResolvedSetting<ShortcutDTO> { .init(value: cancelBindings.value.first ?? .unbound, source: cancelBindings.source) }
    let pasteLatestTranscriptShortcut: ResolvedSetting<ShortcutDTO>
    let outputMode: ResolvedSetting<VoiceOutputMode>
    var autoPaste: ResolvedSetting<Bool> { .init(value: outputMode.value == .pasteImmediately, source: outputMode.source) }
    let historyEnabled: ResolvedSetting<Bool>
    let historyRetentionDays: ResolvedSetting<Int>
    let historyMaxEntries: ResolvedSetting<Int>
    let locale: ResolvedSetting<String>
    let fnHoldThresholdMs: ResolvedSetting<Int>
    let maxSessionSeconds: ResolvedSetting<Int>
    let inputDevicePriority: ResolvedSetting<[InputDeviceDTO]>
    let fallbackToSystemDefault: ResolvedSetting<Bool>

    enum Key: String, CaseIterable, Sendable {
        case keyboardCustomization
        case windowMoverEnabled, windowMoverShortcut, voiceEnabled, holdToTalkShortcut, toggleRecordingShortcut, cancelShortcut, pasteLatestTranscriptShortcut, outputMode, autoPaste
        case historyEnabled, historyRetentionDays, historyMaxEntries, locale, fnHoldThresholdMs, maxSessionSeconds
        case inputDevicePriority, fallbackToSystemDefault
    }

    static func resolve(config: ConfigFile?, local: SettingsValues = .init(), builtIn: BuiltInSettings = .standard) -> EffectiveSettings {
        func pick<T>(_ file: T?, _ local: T?, _ fallback: T) -> ResolvedSetting<T> where T: Equatable & Sendable {
            if let file { return .init(value: file, source: .configFile) }
            if let local { return .init(value: local, source: .local) }
            return .init(value: fallback, source: .builtIn)
        }
        return .init(
            keyboardCustomization: .resolve(file: config?.keyboardCustomization ?? .init(), local: local.keyboardCustomization ?? .init()),
            windowMoverEnabled: pick(config?.windowMover.enabled, local.windowMoverEnabled, builtIn.windowMoverEnabled),
            windowMoverShortcut: pick(config?.windowMover.shortcut, local.windowMoverShortcut, builtIn.windowMoverShortcut),
            voiceEnabled: pick(config?.voice.enabled, local.voiceEnabled, builtIn.voiceEnabled),
            holdToTalkBindings: pick(config?.voice.holdToTalkBindings ?? config?.voice.holdToTalkShortcut.map { [$0] } ?? config?.voice.shortcut.map { [$0] }, local.holdToTalkBindings ?? local.holdToTalkShortcut.map { [$0] }, builtIn.holdToTalkBindings),
            toggleRecordingBindings: pick(config?.voice.toggleRecordingBindings ?? config?.voice.toggleRecordingShortcut.map { [$0] }, local.toggleRecordingBindings ?? local.toggleRecordingShortcut.map { [$0] }, builtIn.toggleRecordingBindings),
            cancelBindings: pick(config?.voice.cancelBindings ?? config?.voice.cancelShortcut.map { [$0] }, local.cancelBindings ?? local.cancelShortcut.map { [$0] }, builtIn.cancelBindings),
            pasteLatestTranscriptShortcut: pick(config?.voice.pasteLatestTranscriptShortcut, local.pasteLatestTranscriptShortcut, builtIn.pasteLatestTranscriptShortcut),
            outputMode: pick(config?.voice.outputMode ?? config?.voice.autoPaste.map { $0 ? .pasteImmediately : .clipboardOnly }, local.outputMode ?? local.autoPaste.map { $0 ? .pasteImmediately : .clipboardOnly }, builtIn.outputMode),
            historyEnabled: pick(config?.voice.history?.enabled, local.historyEnabled, builtIn.historyEnabled),
            historyRetentionDays: pick(config?.voice.history?.retentionDays, local.historyRetentionDays, builtIn.historyRetentionDays),
            historyMaxEntries: pick(config?.voice.history?.maxEntries, local.historyMaxEntries, builtIn.historyMaxEntries),
            locale: pick(config?.voice.locale, local.locale, builtIn.locale),
            fnHoldThresholdMs: pick(config?.voice.fnHoldThresholdMs, local.fnHoldThresholdMs, builtIn.fnHoldThresholdMs),
            maxSessionSeconds: pick(config?.voice.maxSessionSeconds, local.maxSessionSeconds, builtIn.maxSessionSeconds),
            inputDevicePriority: pick(config?.voice.inputDevicePriority, local.inputDevicePriority, builtIn.inputDevicePriority),
            fallbackToSystemDefault: pick(config?.voice.fallbackToSystemDefault, local.fallbackToSystemDefault, builtIn.fallbackToSystemDefault))
    }

    /// Equality includes source, so management/source-only transitions are changes.
    func changedKeys(from old: Self) -> Set<Key> {
        var result = Set<Key>()
        if keyboardCustomization != old.keyboardCustomization { result.insert(.keyboardCustomization) }
        if windowMoverEnabled != old.windowMoverEnabled { result.insert(.windowMoverEnabled) }
        if windowMoverShortcut != old.windowMoverShortcut { result.insert(.windowMoverShortcut) }
        if voiceEnabled != old.voiceEnabled { result.insert(.voiceEnabled) }
        if holdToTalkBindings != old.holdToTalkBindings { result.insert(.holdToTalkShortcut) }
        if toggleRecordingBindings != old.toggleRecordingBindings { result.insert(.toggleRecordingShortcut) }
        if cancelBindings != old.cancelBindings { result.insert(.cancelShortcut) }
        if pasteLatestTranscriptShortcut != old.pasteLatestTranscriptShortcut { result.insert(.pasteLatestTranscriptShortcut) }
        if outputMode != old.outputMode { result.insert(.outputMode); result.insert(.autoPaste) }
        if historyEnabled != old.historyEnabled { result.insert(.historyEnabled) }
        if historyRetentionDays != old.historyRetentionDays { result.insert(.historyRetentionDays) }
        if historyMaxEntries != old.historyMaxEntries { result.insert(.historyMaxEntries) }
        if locale != old.locale { result.insert(.locale) }
        if fnHoldThresholdMs != old.fnHoldThresholdMs { result.insert(.fnHoldThresholdMs) }
        if maxSessionSeconds != old.maxSessionSeconds { result.insert(.maxSessionSeconds) }
        if inputDevicePriority != old.inputDevicePriority { result.insert(.inputDevicePriority) }
        if fallbackToSystemDefault != old.fallbackToSystemDefault { result.insert(.fallbackToSystemDefault) }
        return result
    }
}
