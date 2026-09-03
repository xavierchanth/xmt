import AppKit
import KeyboardShortcuts

/// Canonical shortcut source of truth. Fn chords are kept distinct because
/// KeyboardShortcuts intentionally cannot represent the Fn/Globe modifier.
enum ShortcutDTO: Equatable, Sendable {
    case unbound
    case key(key: String, modifiers: [String])
    case modifierHold(String)
    case fnChord(key: String)

    enum ConversionError: Error, Equatable, Sendable {
        case unknownKey(String)
        case unknownModifier(String)
        case duplicateModifier(String)
        case modifierHoldRequiresModifier(String)
        case modifierHoldCannotConvertToKeyboardShortcut
    }

    func keyboardShortcut() throws -> KeyboardShortcuts.Shortcut {
        guard case let .key(keyName, modifierNames) = self else {
            throw ConversionError.modifierHoldCannotConvertToKeyboardShortcut
        }
        guard let key = Self.keys[keyName.lowercased()] else { throw ConversionError.unknownKey(keyName) }
        var flags: NSEvent.ModifierFlags = []
        var seen = Set<String>()
        for original in modifierNames {
            let name = original.lowercased()
            guard seen.insert(name).inserted else { throw ConversionError.duplicateModifier(original) }
            guard let flag = Self.modifiers[name] else { throw ConversionError.unknownModifier(original) }
            flags.insert(flag)
        }
        return KeyboardShortcuts.Shortcut(key, modifiers: flags)
    }

    static func fromKeyboardShortcut(_ shortcut: KeyboardShortcuts.Shortcut) -> ShortcutDTO? {
        guard let key = shortcut.key,
              let keyName = keys.first(where: { $0.value == key })?.key else { return nil }
        let known: [(String, NSEvent.ModifierFlags)] = [
            ("command", .command), ("control", .control), ("option", .option), ("shift", .shift)
        ]
        let supported: NSEvent.ModifierFlags = [.command, .control, .option, .shift]
        guard shortcut.modifiers.subtracting(supported).isEmpty else { return nil }
        return .key(key: keyName, modifiers: known.compactMap { shortcut.modifiers.contains($0.1) ? $0.0 : nil })
    }

    func conflicts(with other: ShortcutDTO) -> Bool {
        switch (self, other) {
        case (.unbound, _), (_, .unbound): return false
        case let (.modifierHold(left), .modifierHold(right)):
            return left.lowercased() == right.lowercased()
        case (.key, .key):
            guard let left = try? keyboardShortcut(), let right = try? other.keyboardShortcut() else { return false }
            return left == right
        case let (.fnChord(left), .fnChord(right)): return left.lowercased() == right.lowercased()
        // Bare Fn and an Fn-key chord are an intentional, routable family.
        default: return false
        }
    }

    func validate() throws {
        switch self {
        case .unbound: break
        case .key:
            _ = try keyboardShortcut()
        case let .fnChord(key):
            guard Self.keyCodes[key.lowercased()] != nil else { throw ConversionError.unknownKey(key) }
        case let .modifierHold(name):
            guard Self.holdModifiers.contains(name.lowercased()) else {
                throw ConversionError.modifierHoldRequiresModifier(name)
            }
        }
    }

    private static let modifiers: [String: NSEvent.ModifierFlags] = [
        "command": .command, "control": .control, "option": .option, "shift": .shift
    ]
    private static let holdModifiers: Set<String> = ["command", "control", "option", "shift", "fn", "function"]
    static let keyCodes: [String: Int64] = [
        "a":0,"s":1,"d":2,"f":3,"h":4,"g":5,"z":6,"x":7,"c":8,"v":9,"b":11,"q":12,"w":13,"e":14,"r":15,"y":16,"t":17,
        "1":18,"2":19,"3":20,"4":21,"6":22,"5":23,"equal":24,"9":25,"7":26,"minus":27,"8":28,"0":29,"rightbracket":30,"o":31,"u":32,"leftbracket":33,"i":34,"p":35,
        "return":36,"l":37,"j":38,"quote":39,"k":40,"semicolon":41,"backslash":42,"comma":43,"slash":44,"n":45,"m":46,"period":47,"tab":48,"space":49,"backtick":50,"delete":51,"escape":53,
        "f17":64,"f18":79,"f19":80,"f20":90,"f5":96,"f6":97,"f7":98,"f3":99,"f8":100,"f9":101,"f11":103,"f13":105,"f16":106,"f14":107,"f10":109,"f12":111,"f15":113,"home":115,"pageup":116,"forwarddelete":117,"f4":118,"end":119,"f2":120,"pagedown":121,"f1":122,"left":123,"right":124,"down":125,"up":126
    ]

    static func keyName(forKeyCode code: UInt16) -> String? { keyCodes.first(where: { $0.value == Int64(code) })?.key }

    private static let keys: [String: KeyboardShortcuts.Key] = {
        var result: [String: KeyboardShortcuts.Key] = [
            "0": .zero, "1": .one, "2": .two, "3": .three, "4": .four,
            "5": .five, "6": .six, "7": .seven, "8": .eight, "9": .nine,
            "return": .return, "space": .space, "tab": .tab, "escape": .escape,
            "delete": .delete, "forwarddelete": .deleteForward, "up": .upArrow,
            "down": .downArrow, "left": .leftArrow, "right": .rightArrow,
            "home": .home, "end": .end, "pageup": .pageUp, "pagedown": .pageDown,
            "comma": .comma, "period": .period, "slash": .slash, "semicolon": .semicolon,
            "quote": .quote, "minus": .minus, "equal": .equal, "backslash": .backslash,
            "backtick": .backtick, "leftbracket": .leftBracket, "rightbracket": .rightBracket
        ]
        let letters: [KeyboardShortcuts.Key] = [.a,.b,.c,.d,.e,.f,.g,.h,.i,.j,.k,.l,.m,.n,.o,.p,.q,.r,.s,.t,.u,.v,.w,.x,.y,.z]
        for (index, key) in letters.enumerated() { result[String(UnicodeScalar(97 + index)!)] = key }
        let functions: [KeyboardShortcuts.Key] = [.f1,.f2,.f3,.f4,.f5,.f6,.f7,.f8,.f9,.f10,.f11,.f12,.f13,.f14,.f15,.f16,.f17,.f18,.f19,.f20]
        for (index, key) in functions.enumerated() { result["f\(index + 1)"] = key }
        return result
    }()
}

/// Pure state machine for the binding recorder's AppKit event boundary.
/// It keeps Fn-key ownership across flags/key events without depending on a live `NSEvent`.
/// A successful capture consumes the decoder synchronously, so two key-down events delivered
/// before SwiftUI redraws the row can still produce only one commit.
struct VoiceBindingCaptureDecoder: Sendable {
    struct Modifiers: OptionSet, Equatable, Sendable {
        let rawValue: UInt8
        static let control = Self(rawValue: 1 << 0)
        static let option = Self(rawValue: 1 << 1)
        static let shift = Self(rawValue: 1 << 2)
        static let command = Self(rawValue: 1 << 3)
        static let function = Self(rawValue: 1 << 4)
        static let standard: Self = [.control, .option, .shift, .command]
    }

    enum Output: Equatable, Sendable {
        case captured(ShortcutDTO)
        case unsupported
        case ignored
    }

    private var fnIsDown = false
    private var bareFnCandidate = false
    private var isConsumed = false

    mutating func flagsChanged(_ modifiers: Modifiers) -> Output {
        guard !isConsumed else { return .ignored }
        if modifiers.contains(.function) {
            if !fnIsDown {
                fnIsDown = true
                bareFnCandidate = modifiers.intersection(.standard).isEmpty
            } else if !modifiers.intersection(.standard).isEmpty {
                bareFnCandidate = false
            }
            return .ignored
        }
        guard fnIsDown else { return .ignored }
        fnIsDown = false
        defer { bareFnCandidate = false }
        guard bareFnCandidate else { return .ignored }
        return consume(.modifierHold("fn"))
    }

    mutating func keyDown(keyCode: UInt16, modifiers: Modifiers, isRepeat: Bool) -> Output {
        guard !isConsumed else { return .ignored }
        if modifiers.contains(.function) { bareFnCandidate = false }
        guard !isRepeat else { return .ignored }
        guard let key = ShortcutDTO.keyName(forKeyCode: keyCode) else { return .unsupported }
        if modifiers.contains(.function) { return consume(.fnChord(key: key)) }
        let names: [(Modifiers, String)] = [
            (.control, "control"), (.option, "option"), (.shift, "shift"), (.command, "command")
        ]
        return consume(.key(key: key, modifiers: names.compactMap { modifiers.contains($0.0) ? $0.1 : nil }))
    }

    private mutating func consume(_ shortcut: ShortcutDTO) -> Output {
        isConsumed = true
        return .captured(shortcut)
    }
}

extension ShortcutDTO: Codable {
    private enum CodingKeys: String, CodingKey { case type, key, modifiers, modifier }
    private enum Kind: String, Codable { case unbound, key, modifierHold, fnChord }

    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try box.decodeIfPresent(Kind.self, forKey: .type)
        if kind == .unbound { self = .unbound }
        else if kind == .modifierHold || (kind == nil && box.contains(.modifier)) {
            self = .modifierHold(try box.decode(String.self, forKey: .modifier))
        } else if kind == .fnChord {
            self = .fnChord(key: try box.decode(String.self, forKey: .key))
        } else {
            self = .key(key: try box.decode(String.self, forKey: .key),
                        modifiers: try box.decodeIfPresent([String].self, forKey: .modifiers) ?? [])
        }
    }

    func encode(to encoder: Encoder) throws {
        var box = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .unbound: try box.encode(Kind.unbound, forKey: .type)
        case let .key(key, modifiers):
            try box.encode(Kind.key, forKey: .type); try box.encode(key, forKey: .key); try box.encode(modifiers, forKey: .modifiers)
        case let .modifierHold(modifier):
            try box.encode(Kind.modifierHold, forKey: .type); try box.encode(modifier, forKey: .modifier)
        case let .fnChord(key):
            try box.encode(Kind.fnChord, forKey: .type); try box.encode(key, forKey: .key)
        }
    }
}
