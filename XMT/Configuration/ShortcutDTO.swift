import AppKit
import KeyboardShortcuts

/// The two trigger shapes supported by the configuration format. A modifier hold
/// is deliberately not representable as a keyboard shortcut with optional bits.
enum ShortcutDTO: Equatable, Sendable {
    case unbound
    case key(key: String, modifiers: [String])
    case modifierHold(String)

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
        default: return false
        }
    }

    func validate() throws {
        switch self {
        case .unbound: break
        case .key:
            _ = try keyboardShortcut()
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

extension ShortcutDTO: Codable {
    private enum CodingKeys: String, CodingKey { case type, key, modifiers, modifier }
    private enum Kind: String, Codable { case unbound, key, modifierHold }

    init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try box.decodeIfPresent(Kind.self, forKey: .type)
        if kind == .unbound { self = .unbound }
        else if kind == .modifierHold || (kind == nil && box.contains(.modifier)) {
            self = .modifierHold(try box.decode(String.self, forKey: .modifier))
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
        }
    }
}
