import Foundation

enum ConfigDiagnostic: Error, Equatable, Sendable {
    case unreadable(String)
    case malformedJSON(String)
    case unsupportedVersion(Int)
    case invalidValue(path: String, reason: String)
}

struct InputDeviceDTO: Codable, Equatable, Sendable {
    let name: String
    let uid: String?
}

struct ConfigFile: Codable, Equatable, Sendable {
    static let supportedVersion = 1
    static let maximumSessionSecondsRange = 1...3_600

    let version: Int
    var windowMover: WindowMover = .init()
    var voice: Voice = .init()

    private enum CodingKeys: String, CodingKey { case version, windowMover, voice }

    init(version: Int, windowMover: WindowMover = .init(), voice: Voice = .init()) {
        self.version = version; self.windowMover = windowMover; self.voice = voice
    }

    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        version = try box.decode(Int.self, forKey: .version)
        windowMover = try box.decodeIfPresent(WindowMover.self, forKey: .windowMover) ?? .init()
        voice = try box.decodeIfPresent(Voice.self, forKey: .voice) ?? .init()
    }

    struct WindowMover: Codable, Equatable, Sendable {
        var enabled: Bool?
        var shortcut: ShortcutDTO?
    }
    struct Voice: Codable, Equatable, Sendable {
        var enabled: Bool?
        var shortcut: ShortcutDTO?
        var pasteLatestTranscriptShortcut: ShortcutDTO?
        var autoPaste: Bool?
        var history: History?
        var locale: String?
        var fnHoldThresholdMs: Int?
        var maxSessionSeconds: Int?
        var inputDevicePriority: [InputDeviceDTO]?
        var fallbackToSystemDefault: Bool?

        /// `keepLastTranscript` is a decode-only, one-release alias for
        /// `history.enabled`. Encoding always emits the canonical history object.
        fileprivate var historyEnabledAliasConflict = false

        struct History: Codable, Equatable, Sendable {
            var enabled: Bool?
            var retentionDays: Int?
            var maxEntries: Int?
        }

        private enum CodingKeys: String, CodingKey {
            case enabled, shortcut, pasteLatestTranscriptShortcut, autoPaste, history
            case keepLastTranscript
            case locale, fnHoldThresholdMs, maxSessionSeconds, inputDevicePriority, fallbackToSystemDefault
        }
        private enum HistoryCodingKeys: String, CodingKey { case enabled }

        init(enabled: Bool? = nil, shortcut: ShortcutDTO? = nil,
             pasteLatestTranscriptShortcut: ShortcutDTO? = nil, autoPaste: Bool? = nil,
             history: History? = nil, locale: String? = nil, fnHoldThresholdMs: Int? = nil,
             maxSessionSeconds: Int? = nil, inputDevicePriority: [InputDeviceDTO]? = nil,
             fallbackToSystemDefault: Bool? = nil) {
            self.enabled = enabled
            self.shortcut = shortcut
            self.pasteLatestTranscriptShortcut = pasteLatestTranscriptShortcut
            self.autoPaste = autoPaste
            self.history = history
            self.locale = locale
            self.fnHoldThresholdMs = fnHoldThresholdMs
            self.maxSessionSeconds = maxSessionSeconds
            self.inputDevicePriority = inputDevicePriority
            self.fallbackToSystemDefault = fallbackToSystemDefault
        }

        init(from decoder: Decoder) throws {
            let box = try decoder.container(keyedBy: CodingKeys.self)
            enabled = try box.decodeIfPresent(Bool.self, forKey: .enabled)
            shortcut = try box.decodeIfPresent(ShortcutDTO.self, forKey: .shortcut)
            pasteLatestTranscriptShortcut = try box.decodeIfPresent(ShortcutDTO.self, forKey: .pasteLatestTranscriptShortcut)
            autoPaste = try box.decodeIfPresent(Bool.self, forKey: .autoPaste)
            let canonicalEnabledWasSpecified: Bool
            if box.contains(.history), try !box.decodeNil(forKey: .history) {
                let historyBox = try box.nestedContainer(keyedBy: HistoryCodingKeys.self, forKey: .history)
                canonicalEnabledWasSpecified = historyBox.contains(.enabled)
            } else {
                canonicalEnabledWasSpecified = false
            }
            history = try box.decodeIfPresent(History.self, forKey: .history)
            locale = try box.decodeIfPresent(String.self, forKey: .locale)
            fnHoldThresholdMs = try box.decodeIfPresent(Int.self, forKey: .fnHoldThresholdMs)
            maxSessionSeconds = try box.decodeIfPresent(Int.self, forKey: .maxSessionSeconds)
            inputDevicePriority = try box.decodeIfPresent([InputDeviceDTO].self, forKey: .inputDevicePriority)
            fallbackToSystemDefault = try box.decodeIfPresent(Bool.self, forKey: .fallbackToSystemDefault)

            let aliasWasSpecified = box.contains(.keepLastTranscript)
            let alias = try box.decodeIfPresent(Bool.self, forKey: .keepLastTranscript)
            historyEnabledAliasConflict = aliasWasSpecified && canonicalEnabledWasSpecified
            if !historyEnabledAliasConflict, let alias {
                if history != nil { history?.enabled = alias }
                else { history = History(enabled: alias) }
            }
        }

        func encode(to encoder: Encoder) throws {
            var box = encoder.container(keyedBy: CodingKeys.self)
            try box.encodeIfPresent(enabled, forKey: .enabled)
            try box.encodeIfPresent(shortcut, forKey: .shortcut)
            try box.encodeIfPresent(pasteLatestTranscriptShortcut, forKey: .pasteLatestTranscriptShortcut)
            try box.encodeIfPresent(autoPaste, forKey: .autoPaste)
            try box.encodeIfPresent(history, forKey: .history)
            try box.encodeIfPresent(locale, forKey: .locale)
            try box.encodeIfPresent(fnHoldThresholdMs, forKey: .fnHoldThresholdMs)
            try box.encodeIfPresent(maxSessionSeconds, forKey: .maxSessionSeconds)
            try box.encodeIfPresent(inputDevicePriority, forKey: .inputDevicePriority)
            try box.encodeIfPresent(fallbackToSystemDefault, forKey: .fallbackToSystemDefault)
        }
    }

    static func defaultURL(environment: [String: String] = ProcessInfo.processInfo.environment,
                           homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        let base: URL
        if let xdg = environment["XDG_CONFIG_HOME"], xdg.hasPrefix("/") {
            base = URL(fileURLWithPath: xdg, isDirectory: true)
        } else {
            base = homeDirectory.appendingPathComponent(".config", isDirectory: true)
        }
        return base.appendingPathComponent("xmt/config.json")
    }

    static func decode(_ data: Data) throws -> ConfigFile {
        let candidate: ConfigFile
        do { candidate = try JSONDecoder().decode(ConfigFile.self, from: data) }
        catch let error as DecodingError {
            throw ConfigDiagnostic.malformedJSON(Self.describe(error))
        } catch { throw ConfigDiagnostic.malformedJSON(String(describing: error)) }
        guard candidate.version == supportedVersion else { throw ConfigDiagnostic.unsupportedVersion(candidate.version) }
        do { try candidate.validate() }
        catch let error as ConfigDiagnostic { throw error }
        catch { throw ConfigDiagnostic.invalidValue(path: "$", reason: String(describing: error)) }
        return candidate
    }

    func validate() throws {
        if let shortcut = windowMover.shortcut {
            guard case .key = shortcut else { throw ConfigDiagnostic.invalidValue(path: "windowMover.shortcut", reason: "modifier hold is not valid for Window Mover") }
            do { try shortcut.validate() } catch { throw ConfigDiagnostic.invalidValue(path: "windowMover.shortcut", reason: String(describing: error)) }
        }
        if let shortcut = voice.shortcut {
            guard case let .modifierHold(modifier) = shortcut,
                  ["fn", "function"].contains(modifier.lowercased()) else {
                throw ConfigDiagnostic.invalidValue(path: "voice.shortcut", reason: "Voice Transcription v1 requires an Fn modifier hold")
            }
            do { try shortcut.validate() } catch { throw ConfigDiagnostic.invalidValue(path: "voice.shortcut", reason: String(describing: error)) }
        }
        if let shortcut = voice.pasteLatestTranscriptShortcut {
            guard case .key = shortcut else {
                throw ConfigDiagnostic.invalidValue(path: "voice.pasteLatestTranscriptShortcut", reason: "must be a key shortcut")
            }
            do { try shortcut.validate() }
            catch { throw ConfigDiagnostic.invalidValue(path: "voice.pasteLatestTranscriptShortcut", reason: String(describing: error)) }
        }
        if voice.historyEnabledAliasConflict {
            throw ConfigDiagnostic.invalidValue(path: "voice.keepLastTranscript", reason: "conflicts with voice.history.enabled")
        }
        if let value = voice.history?.retentionDays, value < 1 {
            throw ConfigDiagnostic.invalidValue(path: "voice.history.retentionDays", reason: "must be at least 1")
        }
        if let value = voice.history?.maxEntries, value < 1 {
            throw ConfigDiagnostic.invalidValue(path: "voice.history.maxEntries", reason: "must be at least 1")
        }
        if let locale = voice.locale, locale.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw ConfigDiagnostic.invalidValue(path: "voice.locale", reason: "must not be blank")
        }
        if let value = voice.fnHoldThresholdMs, !(50...500).contains(value) {
            throw ConfigDiagnostic.invalidValue(path: "voice.fnHoldThresholdMs", reason: "must be between 50 and 500")
        }
        if let value = voice.maxSessionSeconds, !Self.maximumSessionSecondsRange.contains(value) {
            throw ConfigDiagnostic.invalidValue(path: "voice.maxSessionSeconds", reason: "must be between 1 and 3600")
        }
        if let devices = voice.inputDevicePriority {
            var identities: [String: Int] = [:]
            for (index, device) in devices.enumerated() {
                if device.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    throw ConfigDiagnostic.invalidValue(path: "voice.inputDevicePriority[\(index)].name", reason: "must not be blank")
                }
                if let uid = device.uid, uid.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    throw ConfigDiagnostic.invalidValue(path: "voice.inputDevicePriority[\(index)].uid", reason: "must not be blank when present")
                }
                let normalize = { (value: String) in value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
                let identity = device.uid.map { "uid:\(normalize($0))" } ?? "name:\(normalize(device.name))"
                if let first = identities[identity] {
                    throw ConfigDiagnostic.invalidValue(path: "voice.inputDevicePriority[\(index)]", reason: "duplicates entry at index \(first)")
                }
                identities[identity] = index
            }
        }
    }

    private static func describe(_ error: DecodingError) -> String {
        let path: [CodingKey]
        let message: String
        switch error {
        case let .typeMismatch(_, context), let .valueNotFound(_, context), let .keyNotFound(_, context), let .dataCorrupted(context):
            path = context.codingPath; message = context.debugDescription
        @unknown default:
            return String(describing: error)
        }
        let rendered = path.map { key in key.intValue.map { "[\($0)]" } ?? key.stringValue }.joined(separator: ".")
        return rendered.isEmpty ? message : "\(rendered): \(message)"
    }
}
