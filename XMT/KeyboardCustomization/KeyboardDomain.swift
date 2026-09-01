import Foundation

/// Pure domain for Keyboard Customization key resolution.
///
/// Nothing in this file talks to hardware. There are no IOKit, HID, AppKit, or
/// Core Graphics types here, no clock reads, and no key-code constants borrowed
/// from a physical layout: a `KeyCode` is an opaque token supplied by whatever
/// input source the module is given, and time is supplied with every event.

/// Monotonic engine time in whole milliseconds. The resolver never reads a
/// clock; the caller passes the timestamp that arrived with the physical event.
struct KeyboardInstant: Comparable, Hashable, Sendable {
    let milliseconds: Int

    init(milliseconds: Int) { self.milliseconds = milliseconds }

    static func < (lhs: KeyboardInstant, rhs: KeyboardInstant) -> Bool { lhs.milliseconds < rhs.milliseconds }
    func advanced(by delta: Int) -> KeyboardInstant {
        let (value, overflow) = milliseconds.addingReportingOverflow(delta)
        return .init(milliseconds: overflow ? (delta >= 0 ? Int.max : Int.min) : value)
    }
    func elapsed(since earlier: KeyboardInstant) -> Int {
        let (value, overflow) = milliseconds.subtractingReportingOverflow(earlier.milliseconds)
        return overflow ? (milliseconds >= earlier.milliseconds ? Int.max : Int.min) : value
    }
}

/// Stable device identity. Scope is explicit: a device the configuration does
/// not name is never transformed.
struct KeyboardDeviceID: Hashable, Comparable, Sendable {
    let rawValue: String
    init(_ rawValue: String) { self.rawValue = rawValue }
    static func < (lhs: KeyboardDeviceID, rhs: KeyboardDeviceID) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Opaque physical/logical key token. The engine only compares and orders them.
struct KeyCode: Hashable, Comparable, Sendable {
    let rawValue: UInt16
    init(_ rawValue: UInt16) { self.rawValue = rawValue }
    static func < (lhs: KeyCode, rhs: KeyCode) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// The four modifiers a hold can form. Canonical order is the emission order.
enum KeyModifier: Int, CaseIterable, Comparable, Sendable {
    case control, shift, option, command
    static func < (lhs: KeyModifier, rhs: KeyModifier) -> Bool { lhs.rawValue < rhs.rawValue }
}

struct ModifierSet: OptionSet, Hashable, Sendable {
    let rawValue: Int
    init(rawValue: Int) { self.rawValue = rawValue }

    static let control = ModifierSet(rawValue: 1 << 0)
    static let shift = ModifierSet(rawValue: 1 << 1)
    static let option = ModifierSet(rawValue: 1 << 2)
    static let command = ModifierSet(rawValue: 1 << 3)
    /// Control-Shift-Option-Command, the hold form of Hyper Caps.
    static let hyper: ModifierSet = [.control, .shift, .option, .command]
    var containsOnlyKnownModifiers: Bool { rawValue & ~Self.hyper.rawValue == 0 }

    /// Members in canonical order. Presses use this order, releases its reverse.
    var ordered: [KeyModifier] {
        KeyModifier.allCases.filter { contains(Self(modifier: $0)) }
    }

    init(modifier: KeyModifier) {
        switch modifier {
        case .control: self = .control
        case .shift: self = .shift
        case .option: self = .option
        case .command: self = .command
        }
    }
}

/// What the resolver decided to send to the virtual keyboard. The module that
/// owns output is the only thing that turns these into real events.
enum KeyboardOutput: Equatable, Sendable {
    case keyDown(KeyCode)
    case keyUp(KeyCode)
    case modifierDown(KeyModifier)
    case modifierUp(KeyModifier)
}

/// Everything the resolver accepts. Physical events carry their device; the
/// lifecycle cases are the ways unresolved state is cancelled without
/// inventing a tap.
enum KeyboardInput: Equatable, Sendable {
    case keyDown(device: KeyboardDeviceID, key: KeyCode, isRepeat: Bool)
    case keyUp(device: KeyboardDeviceID, key: KeyCode)
    /// The caller's timer reached the instant the previous result asked for.
    case deadline
    case deviceRemoved(KeyboardDeviceID)
    case configurationReplaced(KeyboardConfiguration)
    case teardown
}

struct KeyboardResolution: Equatable, Sendable {
    /// Ordered output for the virtual keyboard.
    var outputs: [KeyboardOutput] = []
    /// Absolute instant at which the caller must deliver `.deadline`, or nil
    /// for "no timer" — the engine asks for no idle work.
    var deadline: KeyboardInstant?
    /// False only when a physical event came from a device outside configured
    /// scope: the caller forwards that event untouched and the engine kept no
    /// state for it.
    var isInScope: Bool = true
}
