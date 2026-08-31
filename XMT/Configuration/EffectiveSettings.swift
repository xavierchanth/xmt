import Foundation

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
    var windowMoverEnabled: Bool? = nil
    var windowMoverShortcut: ShortcutDTO? = nil
    var voiceEnabled: Bool? = nil
    var voiceShortcut: ShortcutDTO? = nil
    var pasteLatestTranscriptShortcut: ShortcutDTO? = nil
    var autoPaste: Bool? = nil
    var historyEnabled: Bool? = nil
    var historyRetentionDays: Int? = nil
    var historyMaxEntries: Int? = nil
    var locale: String? = nil
    var fnHoldThresholdMs: Int? = nil
    var maxSessionSeconds: Int? = nil
    var inputDevicePriority: [InputDeviceDTO]? = nil
    var fallbackToSystemDefault: Bool? = nil
}

/// Compile-time defaults are complete, making resolution total and trap-free.
struct BuiltInSettings: Equatable, Sendable {
    var windowMoverEnabled = true
    var windowMoverShortcut: ShortcutDTO = .key(key: "space", modifiers: ["option"])
    var voiceEnabled = true
    var voiceShortcut: ShortcutDTO = .modifierHold("fn")
    var pasteLatestTranscriptShortcut: ShortcutDTO = .key(key: "v", modifiers: ["control", "command"])
    var autoPaste = true
    var historyEnabled = true
    var historyRetentionDays = 30
    var historyMaxEntries = 500
    var locale = "en-US"
    var fnHoldThresholdMs = 150
    var maxSessionSeconds = 300
    var inputDevicePriority: [InputDeviceDTO] = []
    var fallbackToSystemDefault = true

    static let standard = BuiltInSettings()
}

struct EffectiveSettings: Equatable, Sendable {
    let windowMoverEnabled: ResolvedSetting<Bool>
    let windowMoverShortcut: ResolvedSetting<ShortcutDTO>
    let voiceEnabled: ResolvedSetting<Bool>
    let voiceShortcut: ResolvedSetting<ShortcutDTO>
    let pasteLatestTranscriptShortcut: ResolvedSetting<ShortcutDTO>
    let autoPaste: ResolvedSetting<Bool>
    let historyEnabled: ResolvedSetting<Bool>
    let historyRetentionDays: ResolvedSetting<Int>
    let historyMaxEntries: ResolvedSetting<Int>
    let locale: ResolvedSetting<String>
    let fnHoldThresholdMs: ResolvedSetting<Int>
    let maxSessionSeconds: ResolvedSetting<Int>
    let inputDevicePriority: ResolvedSetting<[InputDeviceDTO]>
    let fallbackToSystemDefault: ResolvedSetting<Bool>

    enum Key: String, CaseIterable, Sendable {
        case windowMoverEnabled, windowMoverShortcut, voiceEnabled, voiceShortcut, pasteLatestTranscriptShortcut, autoPaste
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
            windowMoverEnabled: pick(config?.windowMover.enabled, local.windowMoverEnabled, builtIn.windowMoverEnabled),
            windowMoverShortcut: pick(config?.windowMover.shortcut, local.windowMoverShortcut, builtIn.windowMoverShortcut),
            voiceEnabled: pick(config?.voice.enabled, local.voiceEnabled, builtIn.voiceEnabled),
            voiceShortcut: pick(config?.voice.shortcut, local.voiceShortcut, builtIn.voiceShortcut),
            pasteLatestTranscriptShortcut: pick(config?.voice.pasteLatestTranscriptShortcut, local.pasteLatestTranscriptShortcut, builtIn.pasteLatestTranscriptShortcut),
            autoPaste: pick(config?.voice.autoPaste, local.autoPaste, builtIn.autoPaste),
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
        if windowMoverEnabled != old.windowMoverEnabled { result.insert(.windowMoverEnabled) }
        if windowMoverShortcut != old.windowMoverShortcut { result.insert(.windowMoverShortcut) }
        if voiceEnabled != old.voiceEnabled { result.insert(.voiceEnabled) }
        if voiceShortcut != old.voiceShortcut { result.insert(.voiceShortcut) }
        if pasteLatestTranscriptShortcut != old.pasteLatestTranscriptShortcut { result.insert(.pasteLatestTranscriptShortcut) }
        if autoPaste != old.autoPaste { result.insert(.autoPaste) }
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
