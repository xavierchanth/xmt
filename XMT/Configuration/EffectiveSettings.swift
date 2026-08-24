import Foundation

enum SettingSource: String, Equatable, Sendable { case builtIn, local, configFile }

struct ResolvedSetting<Value: Equatable & Sendable>: Equatable, Sendable {
    let value: Value
    let source: SettingSource
    var isManaged: Bool { source == .configFile }
}

/// Persisted/UI values are partial by definition.
struct SettingsValues: Equatable, Sendable {
    var windowMoverEnabled: Bool? = nil
    var windowMoverShortcut: ShortcutDTO? = nil
    var voiceEnabled: Bool? = nil
    var voiceShortcut: ShortcutDTO? = nil
    var autoPaste: Bool? = nil
    var keepLastTranscript: Bool? = nil
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
    var autoPaste = true
    var keepLastTranscript = true
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
    let autoPaste: ResolvedSetting<Bool>
    let keepLastTranscript: ResolvedSetting<Bool>
    let locale: ResolvedSetting<String>
    let fnHoldThresholdMs: ResolvedSetting<Int>
    let maxSessionSeconds: ResolvedSetting<Int>
    let inputDevicePriority: ResolvedSetting<[InputDeviceDTO]>
    let fallbackToSystemDefault: ResolvedSetting<Bool>

    enum Key: String, CaseIterable, Sendable {
        case windowMoverEnabled, windowMoverShortcut, voiceEnabled, voiceShortcut, autoPaste
        case keepLastTranscript, locale, fnHoldThresholdMs, maxSessionSeconds
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
            autoPaste: pick(config?.voice.autoPaste, local.autoPaste, builtIn.autoPaste),
            keepLastTranscript: pick(config?.voice.keepLastTranscript, local.keepLastTranscript, builtIn.keepLastTranscript),
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
        if autoPaste != old.autoPaste { result.insert(.autoPaste) }
        if keepLastTranscript != old.keepLastTranscript { result.insert(.keepLastTranscript) }
        if locale != old.locale { result.insert(.locale) }
        if fnHoldThresholdMs != old.fnHoldThresholdMs { result.insert(.fnHoldThresholdMs) }
        if maxSessionSeconds != old.maxSessionSeconds { result.insert(.maxSessionSeconds) }
        if inputDevicePriority != old.inputDevicePriority { result.insert(.inputDevicePriority) }
        if fallbackToSystemDefault != old.fallbackToSystemDefault { result.insert(.fallbackToSystemDefault) }
        return result
    }
}
