import Foundation

/// Physical positions in the USB HID keyboard/keypad usage page (0x07), not macOS key codes.
enum KeyboardMappedPosition: String, Codable, CaseIterable, Sendable {
    case capsLock, a, s, d, f, j, k, l, semicolon

    var usage: UInt16 {
        switch self {
        case .capsLock: 0x39
        case .a: 0x04
        case .s: 0x16
        case .d: 0x07
        case .f: 0x09
        case .j: 0x0D
        case .k: 0x0E
        case .l: 0x0F
        case .semicolon: 0x33
        }
    }

    var modifiers: [KeyboardPolicyDTO.Modifier] {
        switch self {
        case .capsLock: [.control, .shift, .option, .command]
        case .a, .semicolon: [.control]
        case .s, .l: [.shift]
        case .d, .k: [.option]
        case .f, .j: [.command]
        }
    }
}

struct KeyboardKeyTimingDTO: Codable, Equatable, Sendable {
    var holdMs: Int?
    var quickTapMs: Int?
}

struct KeyboardCustomizationDTO: Codable, Equatable, Sendable {
    var hyperEnabled: Bool?
    var homeRowEnabled: Bool?
    var devices: [Device]?

    struct Device: Codable, Equatable, Sendable, Identifiable {
        var id: String
        var identity: KeyboardPolicyDTO.Identity
        var hyperHoldMs: Int?
        var homeRowHoldMs: Int?
        var homeRowQuickTapMs: Int?
        var keyTiming: [String: KeyboardKeyTimingDTO]?
    }

    func validate() throws {
        for device in devices ?? [] {
            for value in [device.hyperHoldMs, device.homeRowHoldMs].compactMap({ $0 }) {
                try Self.validateTiming(value, hold: true)
            }
            if let value = device.homeRowQuickTapMs { try Self.validateTiming(value, hold: false) }
            for (name, timing) in device.keyTiming ?? [:] {
                guard let position = KeyboardMappedPosition(rawValue: name) else {
                    throw ConfigDiagnostic.invalidValue(path: "keyboardCustomization.devices.\(device.id).keyTiming", reason: "unknown physical position: \(name)")
                }
                if let value = timing.holdMs { try Self.validateTiming(value, hold: true) }
                if let value = timing.quickTapMs {
                    guard position != .capsLock else {
                        throw ConfigDiagnostic.invalidValue(path: "keyboardCustomization.devices.\(device.id).keyTiming.capsLock", reason: "Caps quick-tap is fixed at zero")
                    }
                    try Self.validateTiming(value, hold: false)
                }
            }
        }
        // Validate all declared identities even while both capabilities are off.
        let policy = KeyboardPolicyDTO(revision: 1, devices: (devices ?? []).map {
            .init(id: $0.id, identity: $0.identity,
                  timing: .init(holdMilliseconds: 200, quickTapMilliseconds: 0, rollover: .timeoutOnly), keys: [])
        })
        _ = try ValidatedKeyboardOwnerPolicy.validate(policy)
    }

    private static func validateTiming(_ value: Int, hold: Bool) throws {
        guard (hold ? 1 : 0)...KeyboardConfiguration.maximumTimingMilliseconds ~= value else {
            throw ConfigDiagnostic.invalidValue(path: "keyboardCustomization.timing", reason: "timing is outside the supported millisecond range")
        }
    }
}

struct EffectiveKeyboardCustomizationSettings: Equatable, Sendable {
    struct Timing: Equatable, Sendable {
        let holdMs: ResolvedSetting<Int>
        let quickTapMs: ResolvedSetting<Int>
    }

    struct Device: Equatable, Sendable, Identifiable {
        let id: String
        let identity: KeyboardPolicyDTO.Identity
        let hyperHoldMs: ResolvedSetting<Int>
        let homeRowHoldMs: ResolvedSetting<Int>
        let homeRowQuickTapMs: ResolvedSetting<Int>
        let keyTiming: [KeyboardMappedPosition: Timing]
    }

    let hyperEnabled: ResolvedSetting<Bool>
    let homeRowEnabled: ResolvedSetting<Bool>
    let devices: [Device]
    let devicesSource: SettingSource

    static func resolve(file: KeyboardCustomizationDTO = .init(), local: KeyboardCustomizationDTO = .init()) -> Self {
        func pick<T>(_ file: T?, _ local: T?, _ fallback: T) -> ResolvedSetting<T> where T: Equatable & Sendable {
            if let file { return .init(value: file, source: .configFile) }
            if let local { return .init(value: local, source: .local) }
            return .init(value: fallback, source: .builtIn)
        }
        let membership = file.devices ?? local.devices ?? []
        let source: SettingSource = file.devices != nil ? .configFile : local.devices != nil ? .local : .builtIn
        let devices: [Device] = membership.map { selected in
            let managed = file.devices?.first { $0.id == selected.id && $0.identity == selected.identity }
            let saved = local.devices?.first { $0.id == selected.id && $0.identity == selected.identity }
            let hyper = pick(managed?.hyperHoldMs, saved?.hyperHoldMs, 200)
            let home = pick(managed?.homeRowHoldMs, saved?.homeRowHoldMs, 200)
            let quick = pick(managed?.homeRowQuickTapMs, saved?.homeRowQuickTapMs, 150)
            var keys: [KeyboardMappedPosition: Timing] = [:]
            for key in KeyboardMappedPosition.allCases {
                let fileKey = managed?.keyTiming?[key.rawValue]
                let localKey = saved?.keyTiming?[key.rawValue]
                let baseHold = key == .capsLock ? hyper : home
                let hold: ResolvedSetting<Int>
                if let value = fileKey?.holdMs { hold = .init(value: value, source: .configFile) }
                else if baseHold.isManaged { hold = baseHold }
                else if let value = localKey?.holdMs { hold = .init(value: value, source: .local) }
                else { hold = baseHold }
                let repeatTiming: ResolvedSetting<Int>
                if key == .capsLock { repeatTiming = .init(value: 0, source: .builtIn) }
                else if let value = fileKey?.quickTapMs { repeatTiming = .init(value: value, source: .configFile) }
                else if quick.isManaged { repeatTiming = quick }
                else if let value = localKey?.quickTapMs { repeatTiming = .init(value: value, source: .local) }
                else { repeatTiming = quick }
                keys[key] = .init(holdMs: hold, quickTapMs: repeatTiming)
            }
            return Device(id: selected.id, identity: selected.identity, hyperHoldMs: hyper,
                          homeRowHoldMs: home, homeRowQuickTapMs: quick, keyTiming: keys)
        }
        return .init(hyperEnabled: pick(file.hyperEnabled, local.hyperEnabled, false),
                     homeRowEnabled: pick(file.homeRowEnabled, local.homeRowEnabled, false),
                     devices: devices, devicesSource: source)
    }

    /// Compare effective managed leaves when accepting a local edit after rereading the file.
    func permitsLocalChange(from old: KeyboardCustomizationDTO, to new: KeyboardCustomizationDTO) -> Bool {
        if hyperEnabled.isManaged && old.hyperEnabled != new.hyperEnabled { return false }
        if homeRowEnabled.isManaged && old.homeRowEnabled != new.homeRowEnabled { return false }
        let before = old.devices ?? []
        let after = new.devices ?? []
        if devicesSource == .configFile {
            for item in after where before.first(where: { $0.id == item.id }) != item {
                guard devices.contains(where: { $0.id == item.id && $0.identity == item.identity }) else { return false }
            }
            // Local timing shadows may be created for existing file-selected identities only.
            for item in after where !before.contains(where: { $0.id == item.id && $0.identity == item.identity }) {
                guard devices.contains(where: { $0.id == item.id && $0.identity == item.identity }) else { return false }
            }
            for item in before where !after.contains(where: { $0.id == item.id && $0.identity == item.identity }) {
                if devices.contains(where: { $0.id == item.id && $0.identity == item.identity }) { return false }
            }
        }
        for effective in devices {
            let lhs = before.first { $0.id == effective.id && $0.identity == effective.identity }
            let rhs = after.first { $0.id == effective.id && $0.identity == effective.identity }
            if effective.hyperHoldMs.isManaged && lhs?.hyperHoldMs != rhs?.hyperHoldMs { return false }
            if effective.homeRowHoldMs.isManaged && lhs?.homeRowHoldMs != rhs?.homeRowHoldMs { return false }
            if effective.homeRowQuickTapMs.isManaged && lhs?.homeRowQuickTapMs != rhs?.homeRowQuickTapMs { return false }
            for key in KeyboardMappedPosition.allCases {
                if effective.keyTiming[key]?.holdMs.isManaged == true && lhs?.keyTiming?[key.rawValue]?.holdMs != rhs?.keyTiming?[key.rawValue]?.holdMs { return false }
                if effective.keyTiming[key]?.quickTapMs.isManaged == true && lhs?.keyTiming?[key.rawValue]?.quickTapMs != rhs?.keyTiming?[key.rawValue]?.quickTapMs { return false }
            }
        }
        return true
    }
}

enum KeyboardProductPolicyCompiler {
    static func compile(_ settings: EffectiveKeyboardCustomizationSettings,
                        revision: KeyboardPolicyRevision) throws -> ValidatedKeyboardOwnerPolicy {
        let active = settings.hyperEnabled.value || settings.homeRowEnabled.value
        let devices: [KeyboardPolicyDTO.Device] = try (active ? settings.devices : []).map { device in
            let positions = KeyboardMappedPosition.allCases.filter {
                $0 == .capsLock ? settings.hyperEnabled.value : settings.homeRowEnabled.value
            }
            let keys: [KeyboardPolicyDTO.Key] = try positions.map { position in
                guard let timing = device.keyTiming[position] else {
                    throw ConfigDiagnostic.invalidValue(path: "keyboardCustomization", reason: "incomplete key timing")
                }
                return .init(physicalCode: position.usage, tapCode: position == .capsLock ? 0x29 : position.usage,
                             holdModifiers: position.modifiers,
                             timing: .init(holdMilliseconds: timing.holdMs.value, quickTapMilliseconds: timing.quickTapMs.value,
                                           rollover: position == .capsLock ? .otherKeyPress : .timeoutOnly))
            }
            return .init(id: device.id, identity: device.identity,
                         timing: .init(holdMilliseconds: device.homeRowHoldMs.value, quickTapMilliseconds: device.homeRowQuickTapMs.value, rollover: .timeoutOnly), keys: keys, productSemantics: true)
        }
        return try ValidatedKeyboardOwnerPolicy.validate(.init(revision: revision.value, devices: devices))
    }
}
